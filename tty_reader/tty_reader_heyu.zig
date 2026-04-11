const std = @import("std");
const builtin = @import("builtin");
const log = @import("log");
const hexdump = @import("hexdump");
const parse = @import("parse");
const git = @import("git.zig");
const net = std.net;
const posix = std.posix;
const c = @cImport(
{
    @cInclude("toml.h");
});

var g_allocator: std.mem.Allocator = std.heap.c_allocator;
var g_term: [2]i32 = .{-1, -1};
var g_deamonize: bool = false;
var g_config_file: []const u8 = "";

const heyu_info_t = struct
{
    low_voltage_on: f32 = 26.1,
    millis_on: i32 = 4 * 60 * 60 * 1000,
    charger_exe: [256]u8 = .{0} ** 256,
    charger_HU: [256]u8 = .{0} ** 256,
    connect_socket: [256]u8 = .{0} ** 256,
    log_file: [256]u8 = .{0} ** 256,
};

var g_heyu_info: heyu_info_t = .{};

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
    try writer.print("{s} - A tty subsriber\n", .{app_name});
    try writer.print("built with zig version {s}\n", .{vstr});
    try writer.print("git sha1 {s}\n", .{git.g_git_sha1});
    try writer.print("Usage: {s} [options] [config_file]\n", .{app_name});
    try writer.print("  -h: print this help\n", .{});
    try writer.print("  -F: run in foreground\n", .{});
    try writer.print("  -D: run in background\n", .{});
    try writer.print("  config_file: toml config file\n", .{});
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
        else if (slice_arg[0] != '-')
        {
            g_config_file = slice_arg;
        }
        else
        {
            return error.ShowCommandLine;
        }
    }
}

//*****************************************************************************
fn set_str(dest: []u8, src: []const u8) void
{
    @memset(dest, 0);
    const copy_len = @min(src.len, dest.len - 1);
    std.mem.copyForwards(u8, dest, src[0..copy_len]);
}

//*****************************************************************************
fn set_heyu_defaults(info: *heyu_info_t) void
{
    info.low_voltage_on = 26.1;
    info.millis_on = 4 * 60 * 60 * 1000;
    set_str(&info.charger_exe, "/usr/local/bin/heyu");
    set_str(&info.charger_HU, "A2");
    set_str(&info.connect_socket, "/tmp/tty_reader.socket");
    set_str(&info.log_file, "/tmp/tty_reader_heyu.log");
}

//*****************************************************************************
const TomlError = error
{
    FileSizeChanged,
    TomlParseFailed,
    TomlTableInFailed,
};

//*****************************************************************************
inline fn err_if(b: bool, err: TomlError) !void
{
    if (b) return err else return;
}

//*****************************************************************************
fn load_heyu_config(file_name: []const u8) !*c.toml_table_t
{
    var file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();
    const file_stat = try file.stat();
    const file_size: usize = @intCast(file_stat.size);

    var buf = try g_allocator.alloc(u8, file_size + 1);
    defer g_allocator.free(buf);
    const buf1 = try g_allocator.alloc(u8, file_size + 1);
    defer g_allocator.free(buf1);

    var bytes_read: usize = 0;
    if ((builtin.zig_version.major == 0) and
            (builtin.zig_version.minor < 15))
    {
        var file_reader = std.io.bufferedReader(file.reader());
        var reader = file_reader.reader();
        bytes_read = try reader.read(buf);
    }
    else
    {
        var file_reader = file.reader(buf1);
        const reader = &file_reader.interface;
        bytes_read = try reader.readSliceShort(buf);
    }

    const errbuf_size: usize = 1024;
    var errbuf: []u8 = undefined;
    errbuf = try g_allocator.alloc(u8, errbuf_size);
    defer g_allocator.free(errbuf);

    try log.logln(log.LogLevel.info, @src(),
            "file_size {} bytes read {}", .{file_size, bytes_read});
    try err_if(bytes_read > file_size, TomlError.FileSizeChanged);
    buf[bytes_read] = 0;
    const table = c.toml_parse(buf.ptr, errbuf.ptr, errbuf_size);
    if (table) |atable|
    {
        return atable;
    }
    try log.logln(log.LogLevel.info, @src(),
            "toml_parse failed errbuf {s}", .{errbuf});
    return TomlError.TomlParseFailed;
}

//*****************************************************************************
export fn my_toml_malloc(size: usize) ?*anyopaque
{
    return std.c.malloc(size);
}

//*****************************************************************************
export fn my_toml_free(ptr: ?*anyopaque) void
{
    std.c.free(ptr);
}

//*****************************************************************************
fn setup_heyu_info(info: *heyu_info_t, config_file: []const u8) !void
{
    try log.logln(log.LogLevel.info, @src(),
            "config file [{s}]", .{config_file});
    c.toml_set_memutil(my_toml_malloc, my_toml_free);
    const table = try load_heyu_config(config_file);
    defer c.toml_free(table);
    try log.logln(log.LogLevel.info, @src(),
            "load_heyu_config ok for file [{s}]",
            .{config_file});
    var index: c_int = 0;
    while (c.toml_key_in(table, index)) |akey| : (index += 1)
    {
        const akey_slice = std.mem.sliceTo(akey, 0);
        if (std.mem.eql(u8, akey_slice, "main"))
        {
            const ltable = c.toml_table_in(table, akey);
            try err_if(ltable == null, TomlError.TomlTableInFailed);
            var lindex: c_int = 0;
            while (c.toml_key_in(ltable, lindex)) |alkey| : (lindex += 1)
            {
                const alkey_slice = std.mem.sliceTo(alkey, 0);
                if (std.mem.eql(u8, alkey_slice, "low_voltage_on"))
                {
                    const val = c.toml_double_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        info.low_voltage_on = @floatCast(val.u.d);
                    }
                }
                else if (std.mem.eql(u8, alkey_slice, "millis_on"))
                {
                    const val = c.toml_int_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        info.millis_on = @intCast(val.u.i);
                    }
                }
                else if (std.mem.eql(u8, alkey_slice, "charger_exe"))
                {
                    const val = c.toml_string_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        set_str(&info.charger_exe,
                                std.mem.sliceTo(val.u.s, 0));
                        std.c.free(val.u.s);
                    }
                }
                else if (std.mem.eql(u8, alkey_slice, "charger_HU"))
                {
                    const val = c.toml_string_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        set_str(&info.charger_HU,
                                std.mem.sliceTo(val.u.s, 0));
                        std.c.free(val.u.s);
                    }
                }
                else if (std.mem.eql(u8, alkey_slice, "connect_socket"))
                {
                    const val = c.toml_string_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        set_str(&info.connect_socket,
                                std.mem.sliceTo(val.u.s, 0));
                        std.c.free(val.u.s);
                    }
                }
                else if (std.mem.eql(u8, alkey_slice, "log_file"))
                {
                    const val = c.toml_string_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        set_str(&info.log_file,
                                std.mem.sliceTo(val.u.s, 0));
                        std.c.free(val.u.s);
                    }
                }
            }
        }
    }
}

//*****************************************************************************
fn charger_on() !void
{
    const exe = std.mem.sliceTo(&g_heyu_info.charger_exe, 0);
    const hu = std.mem.sliceTo(&g_heyu_info.charger_HU, 0);
    const cmdline = [_][]const u8{exe, "on", hu};
    const rv = try std.process.Child.run(
            .{.allocator = g_allocator, .argv = &cmdline});
    defer g_allocator.free(rv.stdout);
    defer g_allocator.free(rv.stderr);
    try log.logln(log.LogLevel.info, @src(),
            "rv from [{s} on {s}] {} stdout {s} stderr {s}",
            .{exe, hu, rv.term.Exited,
            rv.stdout, rv.stderr});
}

//*****************************************************************************
fn charger_off() !void
{
    const exe = std.mem.sliceTo(&g_heyu_info.charger_exe, 0);
    const hu = std.mem.sliceTo(&g_heyu_info.charger_HU, 0);
    const cmdline = [_][]const u8{exe, "off", hu};
    const rv = try std.process.Child.run(
            .{.allocator = g_allocator, .argv = &cmdline});
    defer g_allocator.free(rv.stdout);
    defer g_allocator.free(rv.stderr);
    try log.logln(log.LogLevel.info, @src(),
            "rv from [{s} off {s}] {} stdout {s} stderr {s}",
            .{exe, hu, rv.term.Exited,
            rv.stdout, rv.stderr});
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
    if ((type1 == 0) and (id == 9))
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
                if (value < g_heyu_info.low_voltage_on)
                {
                    try log.logln(log.LogLevel.info, @src(),
                            "turning on charger", .{});
                    info.state = state_t.Charging;
                    const now = std.time.milliTimestamp();
                    info.charger_on_time = now;
                    info.charger_off_time = now + g_heyu_info.millis_on;
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
                const s = try parse.parse_t.create_from_slice(&g_allocator,
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
    const process_args_rv = process_args();
    if (process_args_rv) |_| { } else |err|
    {
        if (err == error.ShowCommandLine)
        {
            try show_command_line_args();
        }
        return err;
    }
    set_heyu_defaults(&g_heyu_info);
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
            const log_file = std.mem.sliceTo(&g_heyu_info.log_file, 0);
            try log.initWithFile(&g_allocator, log.LogLevel.debug,
                    log_file);
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
    if (g_config_file.len > 0)
    {
        try setup_heyu_info(&g_heyu_info, g_config_file);
    }
    // setup signals
    try setup_signals();
    defer cleanup_signals();
    try log.logln(log.LogLevel.info, @src(), "signals init ok", .{});

    const info = try g_allocator.create(info_t);
    defer g_allocator.destroy(info);
    info.* = .{};

    const connect_socket = std.mem.sliceTo(&g_heyu_info.connect_socket, 0);
    const address = try net.Address.initUnix(connect_socket);
    const tpe: u32 = posix.SOCK.STREAM;
    info.csck = try posix.socket(address.any.family, tpe, 0);
    defer posix.close(info.csck);
    const address_len = address.getOsSockLen();
    try posix.connect(info.csck, &address.any, address_len);

    const ins = try parse.parse_t.create(&g_allocator, 64 * 1024);
    defer ins.delete();

    const main_loop_rv = main_loop(info, ins);
    if (main_loop_rv) |_| { } else |err|
    {
        try log.logln(log.LogLevel.info, @src(),
                "main_loop error {}", .{err});
    }

    if (info.state == state_t.Charging)
    {
        try charger_off();
    }
}
