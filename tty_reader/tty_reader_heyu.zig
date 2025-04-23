const std = @import("std");
const builtin = @import("builtin");
const log = @import("log");
const hexdump = @import("hexdump");
const parse = @import("parse");
const net = std.net;
const posix = std.posix;

var g_allocator: std.mem.Allocator = std.heap.c_allocator;
var g_term: [2]i32 = .{-1, -1};

// low voltage when charger is turned on
const g_low_voltage_on: f32 = 26.1;
// time charger is on in milliseconds
const g_millis_on: i32 = 4 * 60 * 60 * 1000;
// charger Home Unit
const g_charger_HU = "A2";

var g_deamonize: bool = false;

const state_t = enum
{
    LookingForLow,
    Charging,
};

const info_t = struct
{
    csck: i32 = -1,

    code: u16 = 0,
    size: u16 = 0,
    to_read: usize = 4,
    readed: usize = 0,

    state: state_t = state_t.LookingForLow,
    charger_on_time: i64 = 0,
    charger_off_time: i64 = 0,

};

//*****************************************************************************
fn term_sig(_: c_int) callconv(.C) void
{
    const msg: [4]u8 = .{'i', 'n', 't', 0};
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
    sa.handler = .{.handler = term_sig};
    if (builtin.zig_version.major == 0 and builtin.zig_version.minor == 13)
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
fn show_command_line_args() !void
{
    const app_name = std.mem.sliceTo(std.os.argv[0], 0);
    const stdout = std.io.getStdOut();
    const writer = stdout.writer();
    const vstr = builtin.zig_version_string;
    try writer.print("{s} - A tty subsriber\n", .{app_name});
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
        return error.ShowCommandLine;
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
fn charger_on() !void
{
    const cmdline = [_][]const u8{"heyu", "on", g_charger_HU};
    const rv = try std.process.Child.run(
            .{.allocator = g_allocator, .argv = &cmdline});
    defer g_allocator.free(rv.stdout);
    defer g_allocator.free(rv.stderr);
    try log.logln(log.LogLevel.info, @src(),
            "rv from [heyu on {s}] {}", .{g_charger_HU, rv.term.Exited});
}

//*****************************************************************************
fn charger_off() !void
{
    const cmdline = [_][]const u8{"heyu", "off", g_charger_HU};
    const rv = try std.process.Child.run(
            .{.allocator = g_allocator, .argv = &cmdline});
    defer g_allocator.free(rv.stdout);
    defer g_allocator.free(rv.stderr);
    try log.logln(log.LogLevel.info, @src(),
            "rv from [heyu off {s}] {}", .{g_charger_HU, rv.term.Exited});
}

//*****************************************************************************
fn process_msg(info: *info_t, s: *parse.parse_t) !void
{
    var value: f32 = undefined;
    try s.check_rem(8);
    const type1 = s.in_u16_le();
    const id = s.in_u16_le();
    const address1 = s.in_u16_le();
    const count = s.in_u16_le();
    if ((type1 == 0) and (id == 1))
    {
        if (address1 == 256 and count == 10)
        {
            try s.check_rem(4);
            s.in_u8_skip(2); // percent
            // volts
            const volts = s.in_u16_le();
            value = @floatFromInt(volts);
            value /= 10.0;
            // heyu here
            if (info.state == state_t.LookingForLow)
            {
                if (value < g_low_voltage_on)
                {
                    try log.logln(log.LogLevel.info, @src(),
                            "turning on charger", .{});
                    info.state = state_t.Charging;
                    const now = std.time.milliTimestamp();
                    info.charger_on_time = now;
                    info.charger_off_time = now + g_millis_on;
                    try charger_on();
                }
            }
        }
    }
}

//*****************************************************************************
fn process_csck_in(info: *info_t, ins: *parse.parse_t) !void
{
    const recv_rv = try posix.recv(info.csck,
            ins.data[info.readed..info.to_read], 0);
    if (recv_rv < 1)
    {
        return error.InvalidParam;
    }
    info.readed += recv_rv;
    if (info.readed == info.to_read)
    {
        if (info.to_read == 4)
        {
            try ins.reset(0);
            try ins.check_rem(4);
            info.code = ins.in_u16_le();
            info.size = ins.in_u16_le();
            if (info.size <= 4)
            {
                return error.InvalidParam;
            }
            info.to_read = info.size;
        }
        else
        {
            if (info.code == 0)
            {
                const s = try parse.create_from_slice(&g_allocator,
                        ins.data[4..info.readed]);
                defer s.delete();
                try process_msg(info, s);
            }
            info.readed = 0;
            info.to_read = 4;
        }
    }
}

//*****************************************************************************
fn csck_can_recv(info: *info_t, ins: *parse.parse_t) !void
{
    try process_csck_in(info, ins);
}

//*****************************************************************************
fn main_loop(info: *info_t, ins: *parse.parse_t) !void
{
    const max_polls = 32;
    var timeout: i32 = undefined;
    var polls: [max_polls]posix.pollfd = undefined;
    var poll_count: usize = undefined;

    while (true)
    {
        try log.logln_devel(log.LogLevel.info, @src(), "", .{});

        timeout = -1;

        if (info.state == state_t.Charging)
        {
            const now = std.time.milliTimestamp();
            timeout = @intCast(info.charger_off_time - now);
            timeout = if (timeout < 0) 0 else timeout;
            try log.logln_devel(log.LogLevel.info, @src(),
                    "timeout {}", .{timeout});
        }

        // setup poll
        poll_count = 0;
        // setup terminate fd
        const term_index = poll_count;
        polls[poll_count].fd = g_term[0];
        polls[poll_count].events = posix.POLL.IN;
        polls[poll_count].revents = 0;
        poll_count += 1;

        // setup connect fd
        const csck_index = poll_count;
        polls[poll_count].fd = info.csck;
        polls[poll_count].events = posix.POLL.IN;
        polls[poll_count].revents = 0;
        poll_count += 1;

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
            if ((active_polls[csck_index].revents & posix.POLL.IN) != 0)
            {
                try csck_can_recv(info, ins);
            }
        }

        if (info.state == state_t.Charging)
        {
            const now = std.time.milliTimestamp();
            if (now >= info.charger_off_time)
            {
                try log.logln(log.LogLevel.info, @src(),
                        "turning off charger", .{});
                info.state = state_t.LookingForLow;
                try charger_off();
            }
        }

    }
}

//*****************************************************************************
pub fn main() !void
{
    var result = process_args();
    if (result) |_| { } else |err|
    {
        if (err == error.ShowCommandLine)
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
                    "/tmp/tty_reader_heyu.log");
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
    try log.logln(log.LogLevel.info, @src(), "tty_reader_heyu", .{});
    // setup signals
    try setup_signals();
    defer cleanup_signals();
    try log.logln(log.LogLevel.info, @src(), "signals init ok", .{});

    const info = try g_allocator.create(info_t);
    defer g_allocator.destroy(info);
    info.* = .{};

    const address = try net.Address.initUnix("/tmp/tty_reader.socket");
    const tpe: u32 = posix.SOCK.STREAM;
    info.csck = try posix.socket(address.any.family, tpe, 0);
    const address_len = address.getOsSockLen();
    result = try posix.connect(info.csck, &address.any, address_len);

    const ins = try parse.create(&g_allocator, 64 * 1024);
    defer ins.delete();

    try main_loop(info, ins);

    if (info.state == state_t.Charging)
    {
        try charger_off();
    }
}
