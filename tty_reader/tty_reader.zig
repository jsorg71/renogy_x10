
const std = @import("std");
const log = @import("log");
const hexdump = @import("hexdump");
const parse = @import("parse");
const net = std.net;
const posix = std.posix;
const c = @cImport(
{
    @cInclude("modbus/modbus.h");
    @cInclude("toml.h");
});

var g_allocator: std.mem.Allocator = std.heap.c_allocator;
var g_term: [2]i32 = .{-1, -1};
const g_tty_name_max_length = 128;
const g_listen_socket = "/tmp/tty_reader.socket";

pub const TtyError = error
{
    TermSet,
    FileSizeChanged,
    TomlParseFailed,
    TomlTableInFailed,
    ModbusSetSlaveFailed,
    ModbusReadRegistersFailed,
    ModbusReadInputRegistersFailed,
    ModbusSetErrorRecoveryFailed,
    ModbusGetResponseTimeoutFailed,
    ModbusConnectFailed,
    ModbusSetDebugFailed,
};

//*****************************************************************************
pub inline fn err_if(b: bool, err: TtyError) !void
{
    if (b) return err else return;
}

const tty_peer_info_t = struct // one for each client connected
{
    delme: bool = false,
    sck: i32 = -1,
    out_queue: std.DoublyLinkedList(*parse.parse_t) = undefined,
    ins: *parse.parse_t = undefined,

    //*************************************************************************
    fn init(self: *tty_peer_info_t) !void
    {
        self.out_queue = std.DoublyLinkedList(*parse.parse_t){};
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
    }

};

const tty_id_info_t = struct // one for each device we are monitoring
{
    id: u8 = 0,
    read_address: u16 = 0,
    read_count: u8 = 0,
    read_input_address: u16 = 0,
    read_input_count: u8 = 0,
};

const tty_info_t = struct // just one of these
{
    sck: i32 = -1, // listener
    debug: bool = false,
    tty: [g_tty_name_max_length]u8 = .{0} ** g_tty_name_max_length,
    id_list: std.ArrayList(tty_id_info_t) = undefined,
    peer_list: std.ArrayList(tty_peer_info_t) = undefined,
    ctx: *c.modbus_t = undefined,

    //*************************************************************************
    fn init(self: *tty_info_t) !void
    {
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
    try posix.sigaction(posix.SIG.INT, &sa, null);
    try posix.sigaction(posix.SIG.TERM, &sa, null);
    sa.handler = .{ .handler = pipe_sig };
    try posix.sigaction(posix.SIG.PIPE, &sa, null);
}

//*****************************************************************************
fn cleanup_signals() void
{
    posix.close(g_term[0]);
    posix.close(g_term[1]);
}

//*****************************************************************************
fn load_tty_config(file_name: []const u8) !*c.toml_table_t
{
    var file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();
    const file_stat = try file.stat();
    const file_size: usize = @intCast(file_stat.size);
    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();
    var buf: []u8 = undefined;
    buf = try g_allocator.alloc(u8, file_size + 1);
    defer g_allocator.free(buf);
    var errbuf: []u8 = undefined;
    errbuf = try g_allocator.alloc(u8, 1024);
    defer g_allocator.free(errbuf);
    const bytes_read = try in_stream.read(buf);
    try log.logln(log.LogLevel.info, @src(),
            "file_size {} bytes read {}", .{file_size, bytes_read});
    try err_if(bytes_read > file_size, TtyError.FileSizeChanged);
    buf[bytes_read] = 0;
    const table = c.toml_parse(buf.ptr, errbuf.ptr, 1024);
    if (table) |atable|
    {
        try log.logln(log.LogLevel.info, @src(), "toml_parse ok", .{});
        return atable;
    }
    try log.logln(log.LogLevel.info, @src(), 
            "toml_parse failed errbuf {s}", .{errbuf});
    return TtyError.TomlParseFailed;
}

//*****************************************************************************
fn setup_tty_info(info: *tty_info_t) !void
{
    const table = try load_tty_config("tty0.toml");
    defer c.toml_free(table);
    var index: c_int = 0;
    while (c.toml_key_in(table, index)) |akey| : (index += 1)
    {
        const akey_slice = std.mem.sliceTo(akey, 0);
        if (std.mem.eql(u8, akey_slice, "main"))
        {
            const ltable = c.toml_table_in(table, akey);
            try err_if(ltable == null, TtyError.TomlTableInFailed);
            var lindex: c_int = 0;
            while (c.toml_key_in(ltable, lindex)) |alkey| : (lindex += 1)
            {
                const alkey_slice = std.mem.sliceTo(alkey, 0);
                if (std.mem.eql(u8, alkey_slice, "tty"))
                {
                    const val = c.toml_string_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        @memset(&info.tty, 0);
                        std.mem.copyForwards(u8, &info.tty,
                                std.mem.sliceTo(val.u.s, 0));
                        std.c.free(val.u.s);
                    }
                }
                else if (std.mem.eql(u8, alkey_slice, "debug"))
                {
                    const val = c.toml_bool_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        info.debug = val.u.b != 0;
                    }
                }
            }
        }
        else if ((akey_slice.len > 1) and (akey_slice[0] == 'i') and
                (akey_slice[1] == 'd'))
        {
            var item: tty_id_info_t = .{};
            item.id = try std.fmt.parseInt(u8, akey_slice[2..], 10);
            const ltable = c.toml_table_in(table, akey);
            try err_if(ltable == null, TtyError.TomlTableInFailed);
            var lindex: c_int = 0;
            while (c.toml_key_in(ltable, lindex)) |alkey| : (lindex += 1)
            {
                const alkey_slice = std.mem.sliceTo(alkey, 0);
                if (std.mem.eql(u8, alkey_slice, "read_address"))
                {
                    const val = c.toml_int_in(ltable, alkey_slice);
                    item.read_address =
                            if (val.ok != 0) @intCast(val.u.i) else 0;
                }
                else if (std.mem.eql(u8, alkey_slice, "read_count"))
                {
                    const val = c.toml_int_in(ltable, alkey_slice);
                    item.read_count =
                            if (val.ok != 0) @intCast(val.u.i) else 0;
                }
                else if (std.mem.eql(u8, alkey_slice, "read_input_address"))
                {
                    const val = c.toml_int_in(ltable, alkey_slice);
                    item.read_input_address =
                            if (val.ok != 0) @intCast(val.u.i) else 0;
                }
                else if (std.mem.eql(u8, alkey_slice, "read_input_count"))
                {
                    const val = c.toml_int_in(ltable, alkey_slice);
                    item.read_input_count =
                            if (val.ok != 0) @intCast(val.u.i) else 0;
                }
            }
            try info.id_list.append(item);
        }
    }
}

//*****************************************************************************
fn print_tty_info(info: *tty_info_t) !void
{
    try log.logln(log.LogLevel.info, @src(),
            "tty info: tty_name [{s}] debug [{}]", .{info.tty, info.debug});
    try log.logln(log.LogLevel.info, @src(),
            "  got [{}] item to monitor", .{info.id_list.items.len});
    for (0..info.id_list.items.len) |index|
    {
        const item: tty_id_info_t = info.id_list.items[index];
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
fn process_tty_info_list(info: *tty_info_t) !void
{
    for (info.id_list.items) |aitem|
    {
        var err = c.modbus_set_slave(info.ctx, aitem.id);
        try log.logln(log.LogLevel.info, @src(),
                "set slave id {} err {}",
                .{aitem.id, err});
        try err_if(err != 0, TtyError.ModbusSetSlaveFailed);
        if (aitem.read_count > 0)
        {
            var regs: []u16 = undefined;
            const count = aitem.read_count;
            regs = try g_allocator.alloc(u16, count);
            defer g_allocator.free(regs);
            err = c.modbus_read_registers(info.ctx,
                    aitem.read_address, count, regs.ptr);
            try log.logln(log.LogLevel.info, @src(),
                    "modbus_read_registers read address {} err {}",
                    .{aitem.read_address, err});
            try err_if(err != count, TtyError.ModbusReadRegistersFailed);
            try hexdump_slice(regs);
            try sleep(1000);
        }
        if (aitem.read_input_count > 0)
        {
            var regs: []u16 = undefined;
            const count = aitem.read_input_count;
            regs = try g_allocator.alloc(u16, count);
            defer g_allocator.free(regs);
            err = c.modbus_read_input_registers(info.ctx,
                    aitem.read_input_address, count, regs.ptr);
            try log.logln(log.LogLevel.info, @src(),
                    "modbus_read_input_registers read address {} err {}",
                    .{aitem.read_input_address, err});
            try err_if(err != count, TtyError.ModbusReadInputRegistersFailed);
            try hexdump_slice(regs);
            try sleep(1000);
        }
    }
}

//*****************************************************************************
fn check_peers(info: *tty_info_t, active_polls: []posix.pollfd,
        peers_index: usize, poll_count: usize) !void
{
    for (peers_index..poll_count) |index|
    {
        if ((active_polls[index].revents & posix.POLL.IN) != 0)
        {
            // data in from peer
            try log.logln(log.LogLevel.info, @src(), "{s}",
                    .{"data from peer"});
        }
        if ((active_polls[index].revents & posix.POLL.OUT) != 0)
        {
            // data out to peer
            try log.logln(log.LogLevel.info, @src(), "{s}",
                    .{"data to peer"});
            const peer = &info.peer_list.items[index];
            if (peer.out_queue.first) |anode|
            {
                const outs = anode.data;
                const out_slice = outs.data[outs.offset..];
                const sent = try posix.send(peer.sck, out_slice, 0);
                if (sent > 0)
                {
                    outs.offset += sent;
                    if (outs.offset >= outs.data.len)
                    {
                        peer.out_queue.remove(anode);
                        g_allocator.destroy(anode);
                    }
                }
                else
                {
                    peer.delme = true;
                }
            }
        }
    }
    // check for delme peers
    var jndex = poll_count - 1;
    while (jndex >= peers_index) : (jndex -= 1)
    {
        const peer = &info.peer_list.items[jndex];
        if (peer.delme)
        {
            peer.deinit();
            _ = info.peer_list.swapRemove(jndex);
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
    var response_sec: u32 = 0;
    var response_usec: u32 = 0;
    err = c.modbus_get_response_timeout(info.ctx,
            &response_sec, &response_usec);
    try err_if(err != 0, TtyError.ModbusGetResponseTimeoutFailed);
    try log.logln(log.LogLevel.info, @src(),
            "response_sec {} response_usec {}",
            .{response_sec, response_usec});
    err = c.modbus_connect(info.ctx);
    try log.logln(log.LogLevel.info, @src(), "connect err {}", .{err});
    try err_if(err != 0, TtyError.ModbusConnectFailed);
    err = c.modbus_set_debug(info.ctx, @intFromBool(info.debug));
    try err_if(err != 0, TtyError.ModbusSetDebugFailed);

    const max_polls = 32;
    var timeout: i32 = undefined;
    var polls: [max_polls]posix.pollfd = undefined;
    var poll_count: usize = undefined;
    while (true)
    {
        timeout = 10; // -1;
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
        try process_tty_info_list(info);
    }
}

//*****************************************************************************
pub fn main() !void
{
    // setup logging
    try log.init(&g_allocator, log.LogLevel.debug);
    defer log.deinit();
    // setup signals
    try setup_signals();
    defer cleanup_signals();
    try log.logln(log.LogLevel.info, @src(), "signals init ok", .{});
    // setup tty_info
    var tty_info: tty_info_t = .{};
    try tty_info.init();
    defer tty_info.deinit();
    try setup_tty_info(&tty_info);
    try print_tty_info(&tty_info);
    // setup listen socket
    posix.unlink(g_listen_socket) catch |err|
            if (err != error.FileNotFound) return err;
    const tpe: u32 = posix.SOCK.STREAM;
    var address = try net.Address.initUnix(g_listen_socket);
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
