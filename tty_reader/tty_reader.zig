
const std = @import("std");
const builtin = @import("builtin");
const log = @import("log");
const hexdump = @import("hexdump");
const parse = @import("parse");
const toml  = @import("tty_toml.zig");
const net = std.net;
const posix = std.posix;
const c = @cImport(
{
    @cInclude("modbus/modbus.h");
});

pub var g_allocator: std.mem.Allocator = std.heap.c_allocator;
var g_term: [2]i32 = .{-1, -1};
const g_tty_name_max_length = 128;
var g_deamonize: bool = false;

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

const DL = std.DoublyLinkedList(*parse.parse_t);

//*****************************************************************************
inline fn err_if(b: bool, err: TtyError) !void
{
    if (b) return err else return;
}

const tty_peer_info_t = struct // one for each client connected
{
    delme: bool = false,
    sck: i32 = -1,
    out_queue: DL = undefined,
    ins: *parse.parse_t = undefined,

    //*************************************************************************
    fn init(self: *tty_peer_info_t) !void
    {
        self.* = .{};
        self.out_queue = .{};
        self.ins = try parse.create(&g_allocator, 64 * 1024);
    }

    //*************************************************************************
    fn deinit(self: *tty_peer_info_t) void
    {
        while (self.out_queue.popFirst()) |anode|
        {
            anode.data.delete();
            g_allocator.destroy(anode);
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
    tty: [g_tty_name_max_length]u8 = .{0} ** g_tty_name_max_length,
    listen_socket: [g_tty_name_max_length]u8 = .{0} ** g_tty_name_max_length,
    id_list: std.ArrayList(tty_id_info_t) = undefined,
    peer_list: std.ArrayList(tty_peer_info_t) = undefined,
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
        self.id_list = std.ArrayList(tty_id_info_t).init(g_allocator);
        self.peer_list = std.ArrayList(tty_peer_info_t).init(g_allocator);
    }

    //*************************************************************************
    fn deinit(self: *tty_info_t) void
    {
        self.id_list.deinit();
        for (self.peer_list.items) |*aitem|
        {
            aitem.deinit();
        }
        self.peer_list.deinit();
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
        if (self.id_list_sub_index == 0 and item.read_count > 0)
        {
            self.id_list_sub_index += 1;
            return item;
        }
        if (self.id_list_sub_index == 1 and item.read_input_count > 0)
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
fn term_sig(_: c_int) callconv(.C) void
{
    const msg: [4]u8 = .{ 'i', 'n', 't', 0 };
    _ = posix.write(g_term[1], msg[0..4]) catch return;
}

//*****************************************************************************
fn pipe_sig(_: c_int) callconv(.C) void
{
}

//*****************************************************************************
fn setup_signals() !void
{
    g_term = try posix.pipe();
    var sa: posix.Sigaction = undefined;
    sa.mask = posix.empty_sigset;
    sa.flags = 0;
    sa.handler = .{ .handler = term_sig };
    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.TERM, &sa, null);
    sa.handler = .{ .handler = pipe_sig };
    posix.sigaction(posix.SIG.PIPE, &sa, null);
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
            .{info.tty, info.modbus_debug});
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
        try err_if(err != count, TtyError.ModbusReadRegistersFailed);
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
            var s = try parse.create(&g_allocator, msg_size);
            errdefer s.delete();
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
            s.offset = 0;
            const node = try g_allocator.create(DL.Node);
            errdefer g_allocator.destroy(node);
            try log.logln_devel(log.LogLevel.info, @src(),
                    "peer sck {} queue len {}",
                    .{aitem.sck, aitem.out_queue.len});
            node.* = .{.data = s};
            aitem.out_queue.append(node);
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
        try err_if(err != count, TtyError.ModbusReadInputRegistersFailed);
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
            var s = try parse.create(&g_allocator, msg_size);
            errdefer s.delete();
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
            s.offset = 0;
            const node = try g_allocator.create(DL.Node);
            errdefer g_allocator.destroy(node);
            try log.logln_devel(log.LogLevel.info, @src(),
                    "peer sck {} queue len {}",
                    .{aitem.sck, aitem.out_queue.len});
            node.* = .{.data = s};
            aitem.out_queue.append(node);
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
            const sent = try posix.recv(peer.sck, in_slice, 0);
            if (sent < 1)
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
                    "peer sck {} queue len {}",
                    .{peer.sck, peer.out_queue.len});
            if (peer.out_queue.first) |anode|
            {
                const outs = anode.data;
                const out_slice = outs.data[outs.offset..];
                const sent = try posix.send(peer.sck, out_slice, 0);
                try log.logln_devel(log.LogLevel.info, @src(),
                        "posix.send rv {}",
                        .{sent});
                if (sent > 0)
                {
                    outs.offset += sent;
                    if (outs.offset >= outs.data.len)
                    {
                        peer.out_queue.remove(anode);
                        anode.data.delete();
                        g_allocator.destroy(anode);
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
            if (aitem.out_queue.len > 0)
            {
                // we have data to write
                polls[poll_count].events = posix.POLL.OUT;
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
                var peer = try info.peer_list.addOne();
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
    var err = c.modbus_set_error_recovery(info.ctx, er_mode);
    try err_if(err != 0, TtyError.ModbusSetErrorRecoveryFailed);
    err = c.modbus_get_response_timeout(info.ctx,
            &info.response_sec, &info.response_usec);
    try err_if(err != 0, TtyError.ModbusGetResponseTimeoutFailed);
    try log.logln(log.LogLevel.info, @src(),
            "modbus_get_response_timeout: response_sec {} response_usec {}",
            .{info.response_sec, info.response_usec});
    info.min_mstime = (info.response_sec * 1000) + (info.response_usec / 1000);
    err = c.modbus_connect(info.ctx);
    try log.logln(log.LogLevel.info, @src(), "modbus_connect: err {}", .{err});
    try err_if(err != 0, TtyError.ModbusConnectFailed);
    err = c.modbus_set_debug(info.ctx, @intFromBool(info.modbus_debug));
    try err_if(err != 0, TtyError.ModbusSetDebugFailed);
    try tty_main_loop(info);
}

//*****************************************************************************
fn show_command_line_args() !void
{
    const app_name = std.mem.sliceTo(std.os.argv[0], 0);
    const stdout = std.io.getStdOut();
    const writer = stdout.writer();
    const vstr = builtin.zig_version_string;
    try writer.print("{s} - A tty publisher\n", .{app_name});
    try writer.print("built with zig version {s}\n", .{vstr});
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
        {
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
        {
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
    try toml.setup_tty_info(&tty_info);
    try print_tty_info(&tty_info);
    // setup listen socket
    const listen_socket = std.mem.sliceTo(&tty_info.listen_socket, 0);
    posix.unlink(listen_socket) catch |err|
            if (err != error.FileNotFound) return err;
    const tpe: u32 = posix.SOCK.STREAM;
    var address = try net.Address.initUnix(listen_socket);
    tty_info.sck = try posix.socket(address.any.family, tpe, 0);
    const address_len = address.getOsSockLen();
    try posix.bind(tty_info.sck, &address.any, address_len);
    try posix.listen(tty_info.sck, 2);
    defer posix.close(tty_info.sck);
    // setup modbus
    const cptr = std.mem.sliceTo(&tty_info.tty, 0);
    if (c.modbus_new_rtu(cptr.ptr, 9600, 'N', 8, 1)) |actx|
    {
        defer c.modbus_free(actx);
        try log.logln(log.LogLevel.info, @src(),
                "modbus_new_rtu ok for {s}", .{tty_info.tty});
        tty_info.ctx = actx;
        try process_tty_info(&tty_info);
    }
    else
    {
        try log.logln(log.LogLevel.info, @src(),
                "modbus_new_rtu failed for {s}", .{tty_info.tty});
    }
    try log.logln(log.LogLevel.info, @src(), "exit main", .{});
}
