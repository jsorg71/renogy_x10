
const std = @import("std");
const builtin = @import("builtin");
const log = @import("log");
const hexdump = @import("hexdump");
const parse = @import("parse");
const git = @import("git.zig");
const toml  = @import("tty_toml.zig");
const net = std.net;
const posix = std.posix;
const c = @cImport(
{
    @cInclude("modbus/modbus.h");
});

var g_allocator: std.mem.Allocator = std.heap.c_allocator;
var g_term: [2]i32 = .{-1, -1};
const g_tty_name_max_length = 128;
var g_deamonize: bool = false;
var g_config_file: [128:0]u8 =
        .{'t', 't', 'y', '0', '.', 't', 'o', 'm', 'l'} ++ .{0} ** 119;

pub const TtyError = error
{
    TermSet,
    ModbusSetSlaveFailed,
    ModbusReadRegistersFailed,
    ModbusReadInputRegistersFailed,
    ModbusSetErrorRecoveryFailed,
    ModbusGetResponseTimeoutFailed,
    ModbusConnectFailed,
    ModbusSetDebugFailed,
    PeerNotFound,
    ShowCommandLine,
};

const send_t = struct
{
    sent: usize = 0,
    out_data_slice: []u8,
    next: ?*send_t = null,
};

//*****************************************************************************
inline fn err_if(b: bool, err: TtyError) !void
{
    if (b) return err else return;
}

const tty_peer_info_t = struct // one for each client connected
{
    delme: bool = false,
    sck: i32 = -1,
    send_head: ?*send_t = null,
    send_tail: ?*send_t = null,
    ins: *parse.parse_t = undefined,

    //*************************************************************************
    fn init(self: *tty_peer_info_t) !void
    {
        self.* = .{};
        self.ins = try parse.parse_t.create(&g_allocator, 64 * 1024);
    }

    //*************************************************************************
    fn deinit(self: *tty_peer_info_t) void
    {
        var send = self.send_head;
        while (send) |asend|
        {
            send = asend.next;
            g_allocator.free(asend.out_data_slice);
            g_allocator.destroy(asend);
        }
        posix.close(self.sck);
        self.ins.delete();
    }

};

pub const tty_id_info_t = struct // one for each modbus device we are monitoring
{
    id: u8 = 0,
    read_address: u16 = 0,
    read_count: u8 = 0,
    read_input_address: u16 = 0,
    read_input_count: u8 = 0,
};

pub const tty_info_t = struct // just one of these
{
    sck: i32 = -1, // listener
    modbus_debug: bool = false,
    item_mstime: i64 = 0,
    list_mstime: i64 = 0,
    tty: [g_tty_name_max_length:0]u8 = .{0} ** g_tty_name_max_length,
    listen_socket: [g_tty_name_max_length:0]u8 = .{0} ** g_tty_name_max_length,
    id_list: std.ArrayListUnmanaged(tty_id_info_t) = undefined,
    peer_list: std.ArrayListUnmanaged(tty_peer_info_t) = undefined,
    ctx: *c.modbus_t = undefined,
    id_list_index: usize = 0,
    id_list_sub_index: usize = 0,
    response_sec: u32 = 0,
    response_usec: u32 = 0,
    min_mstime: u32 = 0,
    last_modbus_time: ?i64 = null,
    next_modbus_time: ?i64 = null,
    first_modbus_time: ?i64 = null,

    //*************************************************************************
    fn init(self: *tty_info_t) !void
    {
        self.* = .{};
        self.id_list = try std.ArrayListUnmanaged(tty_id_info_t).
                initCapacity(g_allocator, 32);
        self.peer_list = try std.ArrayListUnmanaged(tty_peer_info_t).
                initCapacity(g_allocator, 32);
    }

    //*************************************************************************
    fn deinit(self: *tty_info_t) void
    {
        self.id_list.deinit(g_allocator);
        for (self.peer_list.items) |*aitem|
        {
            aitem.deinit();
        }
        self.peer_list.deinit(g_allocator);
    }

    //*************************************************************************
    fn get_next_id_info(self: *tty_info_t) ?*tty_id_info_t
    {
        if (self.id_list_sub_index > 1)
        {
            self.id_list_index += 1;
            self.id_list_sub_index = 0;
        }
        if (self.id_list_index >= self.id_list.items.len)
        {
            self.id_list_index = 0;
            self.id_list_sub_index = 0;
            return null;
        }
        const item = &self.id_list.items[self.id_list_index];
        if ((self.id_list_sub_index == 0) and (item.read_count > 0))
        {
            self.id_list_sub_index += 1;
            return item;
        }
        if ((self.id_list_sub_index == 1) and (item.read_input_count > 0))
        {
            self.id_list_sub_index += 1;
            return item;
        }
        self.id_list_sub_index += 1;
        return get_next_id_info(self);
    }
};

//*****************************************************************************
fn sleep(mstime: i32) !void
{
    var polls: [1]posix.pollfd = undefined;
    polls[0].fd = g_term[0];
    polls[0].events = posix.POLL.IN;
    polls[0].revents = 0;
    const active_polls = polls[0..1];
    const poll_rv = try posix.poll(active_polls, mstime);
    if (poll_rv > 0)
    {
        try err_if((active_polls[0].revents & posix.POLL.IN) != 0,
                TtyError.TermSet);
    }
}

//*****************************************************************************
export fn term_sig(_: c_int) void
{
    const msg: [4]u8 = .{'i', 'n', 't', 0};
    _ = posix.write(g_term[1], msg[0..4]) catch return;
}

//*****************************************************************************
export fn pipe_sig(_: c_int) void
{
}

//*****************************************************************************
fn setup_signals() !void
{
    g_term = try posix.pipe();
    var sa: posix.Sigaction = undefined;
    sa.mask =
    if ((builtin.zig_version.major == 0) and (builtin.zig_version.minor < 15))
            posix.empty_sigset else posix.sigemptyset();
    sa.flags = 0;
    sa.handler = .{.handler = term_sig};
    if ((builtin.zig_version.major == 0) and (builtin.zig_version.minor == 13))
    {
        try posix.sigaction(posix.SIG.INT, &sa, null);
        try posix.sigaction(posix.SIG.TERM, &sa, null);
        sa.handler = .{.handler = pipe_sig};
        try posix.sigaction(posix.SIG.PIPE, &sa, null);
    }
    else
    {
        posix.sigaction(posix.SIG.INT, &sa, null);
        posix.sigaction(posix.SIG.TERM, &sa, null);
        sa.handler = .{.handler = pipe_sig};
        posix.sigaction(posix.SIG.PIPE, &sa, null);
    }
}

//*****************************************************************************
fn cleanup_signals() void
{
    posix.close(g_term[0]);
    posix.close(g_term[1]);
}

//*****************************************************************************
fn print_tty_info(info: *tty_info_t) !void
{
    try log.logln(log.LogLevel.info, @src(),
            "tty info: tty_name [{s}] modbus_debug [{}]",
            .{std.mem.sliceTo(&info.tty, 0), info.modbus_debug});
    try log.logln(log.LogLevel.info, @src(),
            "  item_mstime [{}] list_mstime [{}]",
            .{info.item_mstime, info.list_mstime});
    try log.logln(log.LogLevel.info, @src(),
            "  got [{}] item to monitor", .{info.id_list.items.len});
    for (0..info.id_list.items.len) |index|
    {
        const item = &info.id_list.items[index];
        try log.logln(log.LogLevel.info, @src(),
                "    index {} item id {} address {} count {} " ++
                "input address {} input count {}",
                .{index, item.id, item.read_address, item.read_count,
                item.read_input_address, item.read_input_count});
    }
}

//*****************************************************************************
fn hexdump_slice(slice: []u16) !void
{
    var u8_slice: []u8 = undefined;
    u8_slice.ptr = @ptrCast(slice.ptr);
    u8_slice.len = slice.len * 2;
    try hexdump.printHexDump(0, u8_slice);
}

//*****************************************************************************
fn process_tty_id_info(info: *tty_info_t, id_info: *tty_id_info_t) !void
{
    var err = c.modbus_set_slave(info.ctx, id_info.id);
    try log.logln_devel(log.LogLevel.info, @src(),
            "set slave id {} err {}",
            .{id_info.id, err});
    try err_if(err != 0, TtyError.ModbusSetSlaveFailed);
    if (info.id_list_sub_index == 1)
    {
        var regs: []u16 = undefined;
        const count = id_info.read_count;
        regs = try g_allocator.alloc(u16, count);
        defer g_allocator.free(regs);
        err = c.modbus_read_registers(info.ctx,
                id_info.read_address, count, regs.ptr);
        try log.logln_devel(log.LogLevel.info, @src(),
                "modbus_read_registers read address {} err {}",
                .{id_info.read_address, err});
        if (err != count)
        {
            try log.logln(log.LogLevel.info, @src(),
                    "modbus_read_registers err != count {} != {}",
                    .{err, count});
            return TtyError.ModbusReadRegistersFailed;
        }
        if (info.modbus_debug)
        {
            try hexdump_slice(regs);
        }
        // add data to each peer
        try log.logln_devel(log.LogLevel.info, @src(), "peer len {}",
                .{info.peer_list.items.len});
        for (info.peer_list.items) |*aitem|
        {
            const msg_size = 2 + 2 + 2 + 2 + 2 + 2 + count * 2;
            var s = try parse.parse_t.create(&g_allocator, msg_size);
            defer s.delete();
            try s.check_rem(msg_size);
            s.out_u16_le(0); // msg id
            s.out_u16_le(msg_size); // size
            s.out_u16_le(0); // type
            s.out_u16_le(id_info.id);
            s.out_u16_le(id_info.read_address);
            s.out_u16_le(id_info.read_count);
            for (regs) |areg|
            {
                s.out_u16_le(areg);
            }
            const s_slice = s.get_out_slice();
            const send = try g_allocator.create(send_t);
            const out_data_slice = try g_allocator.alloc(u8, s_slice.len);
            send.* = .{.out_data_slice = out_data_slice};
            std.mem.copyForwards(u8, send.out_data_slice, s_slice);
            if (aitem.send_tail) |asend_tail|
            {
                asend_tail.next = send;
                aitem.send_tail = send;
            }
            else
            {
                aitem.send_head = send;
                aitem.send_tail = send;
            }
        }
    }
    else if (info.id_list_sub_index == 2)
    {
        var regs: []u16 = undefined;
        const count = id_info.read_input_count;
        regs = try g_allocator.alloc(u16, count);
        defer g_allocator.free(regs);
        err = c.modbus_read_input_registers(info.ctx,
                id_info.read_input_address, count, regs.ptr);
        try log.logln_devel(log.LogLevel.info, @src(),
                "modbus_read_input_registers read address {} err {}",
                .{id_info.read_input_address, err});
        if (err != count)
        {
            try log.logln(log.LogLevel.info, @src(),
                    "modbus_read_input_registers err != count {} != {}",
                    .{err, count});
            return TtyError.ModbusReadRegistersFailed;
        }
        if (info.modbus_debug)
        {
            try hexdump_slice(regs);
        }
        // add data to each peer
        try log.logln_devel(log.LogLevel.info, @src(), "peer len {}",
                .{info.peer_list.items.len});
        for (info.peer_list.items) |*aitem|
        {
            const msg_size = 2 + 2 + 2 + 2 + 2 + 2 + count * 2;
            var s = try parse.parse_t.create(&g_allocator, msg_size);
            defer s.delete();
            try s.check_rem(msg_size);
            s.out_u16_le(0); // msg id
            s.out_u16_le(msg_size); // size
            s.out_u16_le(1); // type
            s.out_u16_le(id_info.id);
            s.out_u16_le(id_info.read_input_address);
            s.out_u16_le(id_info.read_input_count);
            for (regs) |areg|
            {
                s.out_u16_le(areg);
            }
            const s_slice = s.get_out_slice();
            const send = try g_allocator.create(send_t);
            const out_data_slice = try g_allocator.alloc(u8, s_slice.len);
            send.* = .{.out_data_slice = out_data_slice};
            std.mem.copyForwards(u8, send.out_data_slice, s_slice);
            if (aitem.send_tail) |asend_tail|
            {
                asend_tail.next = send;
                aitem.send_tail = send;
            }
            else
            {
                aitem.send_head = send;
                aitem.send_tail = send;
            }
        }
    }
}

//*****************************************************************************
fn check_modbus(info: *tty_info_t, timeout: *i32) !void
{
    var now = std.time.milliTimestamp();
    var nmt = info.next_modbus_time orelse now;
    const fmt = info.first_modbus_time orelse now;
    const lmt = info.last_modbus_time orelse 0;
    if ((now >= nmt) and (now - lmt < info.min_mstime))
    {
        // safety check, can not let 2 process_tty_id_info calls
        // too close together
        try log.logln_devel(log.LogLevel.info, @src(),
                "adjusting next_modbus_time " ++
                "now {} " ++
                "last_modbus_time {} " ++
                "diff {}",
                .{now, lmt, now - lmt});
        nmt = lmt + info.min_mstime;
        info.next_modbus_time = nmt;
        info.first_modbus_time = nmt;
    }
    else if (now >= nmt)
    {
        const id_info = info.get_next_id_info();
        if (id_info) |aid_info|
        {
            info.next_modbus_time = now + info.item_mstime;
            try process_tty_id_info(info, aid_info);
            now = std.time.milliTimestamp();
            info.last_modbus_time = now;
        }
        else
        {
            nmt = fmt + info.list_mstime;
            info.next_modbus_time = nmt;
            info.first_modbus_time = nmt;
        }
    }
    // calculate timeout
    timeout.* = @intCast(nmt - now);
    timeout.* = @max(timeout.*, 0);
}

//*****************************************************************************
fn get_peer_by_sck(info: *tty_info_t, sck: i32) !*tty_peer_info_t
{
    for (info.peer_list.items) |*peer|
    {
        if (peer.sck == sck)
        {
            return peer;
        }
    }
    return TtyError.PeerNotFound;
}

//*****************************************************************************
fn check_peers(info: *tty_info_t, active_polls: []posix.pollfd,
        peers_index: usize, poll_count: usize) !void
{
    for (peers_index..poll_count) |index|
    {
        const fd = active_polls[index].fd;
        if ((active_polls[index].revents & posix.POLL.IN) != 0)
        {
            // data in from peer
            try log.logln(log.LogLevel.info, @src(),
                    "POLL.IN set for sck {}", .{fd});
            const peer = try get_peer_by_sck(info, fd);
            const in_slice = peer.ins.data[peer.ins.offset..];
            const read = try posix.recv(peer.sck, in_slice, 0);
            if (read < 1)
            {
                try log.logln(log.LogLevel.info, @src(),
                        "delme set for sck {}", .{fd});
                peer.delme = true;
            }

        }
        if ((active_polls[index].revents & posix.POLL.OUT) != 0)
        {
            // data out to peer
            try log.logln_devel(log.LogLevel.info, @src(),
                    "POLL.OUT set for sck {}", .{fd});
            const peer = try get_peer_by_sck(info, fd);
            try log.logln_devel(log.LogLevel.info, @src(),
                    "peer sck {}",
                    .{peer.sck});
            if (peer.send_head) |asend|
            {
                const out_slice = asend.out_data_slice[asend.sent..];
                const sent = try posix.send(peer.sck, out_slice, 0);
                try log.logln_devel(log.LogLevel.info, @src(),
                        "posix.send rv {}",
                        .{sent});
                if (sent > 0)
                {
                    asend.sent += sent;
                    if (asend.sent >= asend.out_data_slice.len)
                    {

                        peer.send_head = asend.next;
                        if (peer.send_head == null)
                        {
                            // if send_head is null, set send_tail to null
                            peer.send_tail = null;
                        }
                        g_allocator.free(asend.out_data_slice);
                        g_allocator.destroy(asend);
                    }
                }
                else
                {
                    try log.logln(log.LogLevel.info, @src(),
                            "delme set for sck {}", .{fd});
                    peer.delme = true;
                }
            }
            else
            {
                try log.logln(log.LogLevel.info, @src(),
                        "no data for src {}", .{fd});
            }
        }
    }
    // check for delme peers
    var jndex = info.peer_list.items.len;
    while (jndex > 0)
    {
        jndex -= 1;
        const peer = &info.peer_list.items[jndex];
        if (peer.delme)
        {
            peer.deinit();
            _ = info.peer_list.swapRemove(jndex);
        }
    }
}

//*****************************************************************************
fn tty_main_loop(info: *tty_info_t) !void
{
    const max_polls = 32;
    var timeout: i32 = undefined;
    var polls: [max_polls]posix.pollfd = undefined;
    var poll_count: usize = undefined;
    while (true)
    {
        timeout = -1;
        if (info.peer_list.items.len == 0)
        {
            info.next_modbus_time = null;
            info.first_modbus_time = null;
            info.last_modbus_time = null;
            info.id_list_index = 0;
            info.id_list_sub_index = 0;
        }
        else
        {
            try check_modbus(info, &timeout);
        }
        try log.logln_devel(log.LogLevel.info, @src(),
                "timeout {}", .{timeout});
        // setup poll
        poll_count = 0;
        // setup terminate fd
        const term_index = poll_count;
        polls[poll_count].fd = g_term[0];
        polls[poll_count].events = posix.POLL.IN;
        polls[poll_count].revents = 0;
        poll_count += 1;
        // setup listen fd
        const lsck_index = poll_count;
        polls[poll_count].fd = info.sck;
        polls[poll_count].events = posix.POLL.IN;
        polls[poll_count].revents = 0;
        poll_count += 1;
        // add the peers
        const peers_index = poll_count;
        for (info.peer_list.items) |*aitem|
        {
            polls[poll_count].fd = aitem.sck;
            polls[poll_count].events = posix.POLL.IN;
            if (aitem.send_tail != null)
            {
                // we have data to write
                polls[poll_count].events |= posix.POLL.OUT;
            }
            polls[poll_count].revents = 0;
            poll_count += 1;
        }
        const active_polls = polls[0..poll_count];
        const poll_rv = try posix.poll(active_polls, timeout);
        if (poll_rv > 0)
        {
            if ((active_polls[term_index].revents & posix.POLL.IN) != 0)
            {
                try log.logln(log.LogLevel.info, @src(), "{s}",
                        .{"term set shutting down"});
                break;
            }
            if ((active_polls[lsck_index].revents & posix.POLL.IN) != 0)
            {
                // new connection in
                try log.logln(log.LogLevel.info, @src(), "{s}",
                        .{"new connection in"});
                const sck = try posix.accept(info.sck, null, null, 0);
                var peer = try info.peer_list.addOne(g_allocator);
                try peer.init();
                peer.sck = sck;
            }
            if (peers_index < poll_count)
            {
                try check_peers(info, active_polls, peers_index, poll_count);
            }
        }
    }
}

//*****************************************************************************
fn process_tty_info(info: *tty_info_t) !void
{
    try log.logln(log.LogLevel.info, @src(), "", .{});
    const er_mode: c.modbus_error_recovery_mode =
            c.MODBUS_ERROR_RECOVERY_LINK | c.MODBUS_ERROR_RECOVERY_PROTOCOL;
    var modbus_err = c.modbus_set_error_recovery(info.ctx, er_mode);
    try err_if(modbus_err != 0, TtyError.ModbusSetErrorRecoveryFailed);
    modbus_err = c.modbus_get_response_timeout(info.ctx,
            &info.response_sec, &info.response_usec);
    try err_if(modbus_err != 0, TtyError.ModbusGetResponseTimeoutFailed);
    try log.logln(log.LogLevel.info, @src(),
            "modbus_get_response_timeout: response_sec {} response_usec {}",
            .{info.response_sec, info.response_usec});
    info.min_mstime = (info.response_sec * 1000) + (info.response_usec / 1000);
    modbus_err = c.modbus_connect(info.ctx);
    try log.logln(log.LogLevel.info, @src(), "modbus_connect: err {}",
            .{modbus_err});
    try err_if(modbus_err != 0, TtyError.ModbusConnectFailed);
    modbus_err = c.modbus_set_debug(info.ctx, @intFromBool(info.modbus_debug));
    try err_if(modbus_err != 0, TtyError.ModbusSetDebugFailed);
    try tty_main_loop(info);
}

//*****************************************************************************
fn show_command_line_args() !void
{
    if ((builtin.zig_version.major == 0) and
        (builtin.zig_version.minor < 15))
    {
        const stdout = std.io.getStdOut();
        const writer = stdout.writer();
        try show_command_line_args1(writer);
    }
    else
    {
        var buf: [1024]u8 = undefined;
        const stdout = std.fs.File.stdout();
        var stdout_writer = stdout.writer(&buf);
        const writer = &stdout_writer.interface;
        try show_command_line_args1(writer);
        try writer.flush();
    }
}

//*****************************************************************************
fn show_command_line_args1(writer: anytype) !void
{
    const app_name = std.mem.sliceTo(std.os.argv[0], 0);
    const vstr = builtin.zig_version_string;
    try writer.print("{s} - A tty publisher\n", .{app_name});
    try writer.print("built with zig version {s}\n", .{vstr});
    try writer.print("git sha1 {s}\n", .{git.g_git_sha1});
    try writer.print("Usage: {s} [options]\n", .{app_name});
    try writer.print("  -h: print this help\n", .{});
    try writer.print("  -F: run in foreground\n", .{});
    try writer.print("  -D: run in background\n", .{});
}

//*****************************************************************************
fn process_args() !void
{
    var slice_arg: []u8 = undefined;
    var index: usize = 1;
    const count = std.os.argv.len;
    if (count < 2)
    {
        return TtyError.ShowCommandLine;
    }
    while (index < count) : (index += 1)
    {
        slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
        if (std.mem.eql(u8, slice_arg, "-h"))
        {
            return error.ShowCommandLine;
        }
        else if (std.mem.eql(u8, slice_arg, "-D"))
        {
            g_deamonize = true;
        }
        else if (std.mem.eql(u8, slice_arg, "-F"))
        {
            g_deamonize = false;
        }
        else if (std.mem.eql(u8, slice_arg, "-c"))
        {
            index += 1;
            if (index < count)
            {
                const slice_arg1 = std.mem.sliceTo(std.os.argv[index], 0);
                if (slice_arg1.len < g_config_file.len)
                {
                    @memset(&g_config_file, 0);
                    std.mem.copyForwards(u8, &g_config_file, slice_arg1);
                    continue;
                }
            }
            return error.ShowCommandLine;
        }
        else
        {
            return error.ShowCommandLine;
        }
    }
}

//*****************************************************************************
pub fn main() !void
{
    const result = process_args();
    if (result) |_| { } else |err|
    {
        if (err == TtyError.ShowCommandLine)
        {
            try show_command_line_args();
        }
        return err;
    }
    if (g_deamonize)
    {
        const rv = try posix.fork();
        if (rv == 0)
        { // child
            posix.close(0);
            posix.close(1);
            posix.close(2);
            _ = try posix.open("/dev/null", .{.ACCMODE = .RDONLY}, 0);
            _ = try posix.open("/dev/null", .{.ACCMODE = .WRONLY}, 0);
            _ = try posix.open("/dev/null", .{.ACCMODE = .WRONLY}, 0);
            try log.initWithFile(&g_allocator, log.LogLevel.debug,
                    "/tmp/tty_reader.log");
        }
        else if (rv > 0)
        { // parent
            std.debug.print("started with pid {}\n", .{rv});
            return;
        }
    }
    else
    {
        try log.init(&g_allocator, log.LogLevel.debug);
    }
    defer log.deinit();
    // setup signals
    try setup_signals();
    defer cleanup_signals();
    try log.logln(log.LogLevel.info, @src(), "signals init ok", .{});
    // setup tty_info
    var tty_info: tty_info_t = undefined;
    try tty_info.init();
    defer tty_info.deinit();
    const config_file = std.mem.sliceTo(&g_config_file, 0);
    try toml.setup_tty_info(&g_allocator, &tty_info, config_file);
    try print_tty_info(&tty_info);
    // setup listen socket
    const listen_socket = std.mem.sliceTo(&tty_info.listen_socket, 0);
    posix.unlink(listen_socket) catch |err|
            if (err != error.FileNotFound) return err;
    const tpe: u32 = posix.SOCK.STREAM;
    var address = try net.Address.initUnix(listen_socket);
    tty_info.sck = try posix.socket(address.any.family, tpe, 0);
    defer posix.close(tty_info.sck);
    const address_len = address.getOsSockLen();
    try posix.bind(tty_info.sck, &address.any, address_len);
    try posix.listen(tty_info.sck, 2);
    // setup modbus
    while (c.modbus_new_rtu(&tty_info.tty, 9600, 'N', 8, 1)) |actx|
    {
        defer c.modbus_free(actx);
        try log.logln(log.LogLevel.info, @src(),
                "modbus_new_rtu ok for {s}",
                .{std.mem.sliceTo(&tty_info.tty, 0)});
        tty_info.ctx = actx;
        const process_tty_info_rv = process_tty_info(&tty_info);
        if (process_tty_info_rv) |_|
        {
            break;
        }
        else |err|
        {
            try log.logln(log.LogLevel.info, @src(),
                    "process_tty_info error {}", .{err});
            try sleep(60000);
        }
    }
    try log.logln(log.LogLevel.info, @src(), "exit main", .{});
}
