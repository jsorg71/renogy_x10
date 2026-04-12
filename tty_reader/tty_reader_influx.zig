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
var g_config_file: [128:0]u8 =
        .{'t', 't', 'y', '_', 'i', 'n', 'f', 'l', 'u', 'x', '0', '.', 't', 'o', 'm', 'l'} ++ .{0} ** 112;

const influx_info_t = struct
{
    influx_hostname: [256]u8 = .{0} ** 256,
    influx_port: c_int = 8086,
    influx_database: [256]u8 = .{0} ** 256,
    influx_org: [256]u8 = .{0} ** 256,
    influx_token: [512]u8 = .{0} ** 512,
    influx_host_tag: [256]u8 = .{0} ** 256,
    connect_socket: [256]u8 = .{0} ** 256,
    log_file: [256]u8 = .{0} ** 256,
};

var g_influx_info: influx_info_t = .{};

const send_t = struct
{
    sent: usize = 0,
    out_data_slice: []u8,
    next: ?*send_t = null,
};

const info_t = struct
{
    buffer_out: [2048]u8 = undefined,
    buffer_con: [64]u8 = undefined,
    buffer_in: [1024]u8 = undefined,
    influx_ip: [64]u8 = undefined,
    isck: i32 = -1,
    csck: i32 = -1,

    code: u16 = 0,
    size: u16 = 0,
    to_read: usize = 4,
    readed: usize = 0,

    send_head: ?*send_t = null,
    send_tail: ?*send_t = null,


    connecting: bool = false,
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
    try writer.print("Usage: {s} [options]\n", .{app_name});
    try writer.print("  -h: print this help\n", .{});
    try writer.print("  -F: run in foreground\n", .{});
    try writer.print("  -D: run in background\n", .{});
    try writer.print("  -c: toml config file\n, defaults to tty_influx0.toml", .{});
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
fn set_influx_defaults(info: *influx_info_t) void
{
    set_str(&info.influx_hostname, "server3.xrdp.org");
    info.influx_port = 8086;
    set_str(&info.influx_database, "solar");
    set_str(&info.influx_org, "org1");
    set_str(&info.influx_token,
            "Wh4XF_BN120-dvfZiI0T6L7DIdG7Ma8JnSMW6GnMTpT5" ++
            "uG4qDlBFsEGS_jwo9eBD2pf2jtra7sgi0ajl5R-oEA==");
    set_str(&info.influx_host_tag, "serverA");
    set_str(&info.connect_socket, "/tmp/tty_reader.socket");
    set_str(&info.log_file, "/tmp/tty_reader_influx.log");
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
fn load_influx_config(file_name: []const u8) !*c.toml_table_t
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
fn setup_influx_info(info: *influx_info_t, config_file: []const u8) !void
{
    try log.logln(log.LogLevel.info, @src(),
            "config file [{s}]", .{config_file});
    c.toml_set_memutil(my_toml_malloc, my_toml_free);
    const table = try load_influx_config(config_file);
    defer c.toml_free(table);
    try log.logln(log.LogLevel.info, @src(),
            "load_influx_config ok for file [{s}]",
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
                if (std.mem.eql(u8, alkey_slice, "influx_hostname"))
                {
                    const val = c.toml_string_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        set_str(&info.influx_hostname,
                                std.mem.sliceTo(val.u.s, 0));
                        std.c.free(val.u.s);
                    }
                }
                else if (std.mem.eql(u8, alkey_slice, "influx_port"))
                {
                    const val = c.toml_int_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        info.influx_port = @intCast(val.u.i);
                    }
                }
                else if (std.mem.eql(u8, alkey_slice, "influx_database"))
                {
                    const val = c.toml_string_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        set_str(&info.influx_database,
                                std.mem.sliceTo(val.u.s, 0));
                        std.c.free(val.u.s);
                    }
                }
                else if (std.mem.eql(u8, alkey_slice, "influx_org"))
                {
                    const val = c.toml_string_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        set_str(&info.influx_org,
                                std.mem.sliceTo(val.u.s, 0));
                        std.c.free(val.u.s);
                    }
                }
                else if (std.mem.eql(u8, alkey_slice, "influx_token"))
                {
                    const val = c.toml_string_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        set_str(&info.influx_token,
                                std.mem.sliceTo(val.u.s, 0));
                        std.c.free(val.u.s);
                    }
                }
                else if (std.mem.eql(u8, alkey_slice, "influx_host_tag"))
                {
                    const val = c.toml_string_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        set_str(&info.influx_host_tag,
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
fn connect_isck(info: *info_t) !void
{
    if (info.isck == -1)
    {
        const hostname = std.mem.sliceTo(&g_influx_info.influx_hostname, 0);
        const port_u16: u16 = @intCast(g_influx_info.influx_port);
        const address_list = try std.net.getAddressList(g_allocator,
                hostname, port_u16);
        defer address_list.deinit();
        if (address_list.addrs.len < 1)
        {
            return error.InvalidParam;
        }
        const address = address_list.addrs[0];
        const tpe: u32 = posix.SOCK.STREAM;
        info.isck = try posix.socket(address.any.family, tpe, 0);
        // set non blocking
        var val1 = try posix.fcntl(info.isck, posix.F.GETFL, 0);
        if ((val1 & posix.SOCK.NONBLOCK) == 0)
        {
            val1 = val1 | posix.SOCK.NONBLOCK;
            _ = try posix.fcntl(info.isck, posix.F.SETFL, val1);
        }
        const address_len = address.getOsSockLen();
        const result = posix.connect(info.isck, &address.any, address_len);
        if (result) |_| { } else |err|
        {
            // WouldBlock is ok
            if (err != error.WouldBlock)
            {
                return err;
            }
        }
        try log.logln(log.LogLevel.info, @src(),
                "connecting to host {s} sck {}",
                .{hostname, info.isck});
        info.connecting = true;
    }
}

//*****************************************************************************
fn process_msg_table(info: *info_t, table_name: []const u8,
        value: f32) !void
{
    const host_tag = std.mem.sliceTo(&g_influx_info.influx_host_tag, 0);
    const database = std.mem.sliceTo(&g_influx_info.influx_database, 0);
    const hostname = std.mem.sliceTo(&g_influx_info.influx_hostname, 0);
    const org = std.mem.sliceTo(&g_influx_info.influx_org, 0);
    const token = std.mem.sliceTo(&g_influx_info.influx_token, 0);
    const str1 = try std.fmt.bufPrint(&info.buffer_con,
            "{s},host={s} value={d:.2}\n", .{table_name, host_tag, value});
    const str2 = try std.fmt.bufPrint(&info.buffer_out,
            "POST /api/v2/write?org={s}&bucket={s} HTTP/1.1\r\n" ++
            "Host: {s}:{}\r\n" ++
            "Authorization: Token {s}\r\n" ++
            "Content-Type: text/plain; charset=utf-8\r\n" ++
            "Accept: application/json\r\n" ++
            "Content-Length: {}\r\n\r\n{s}",
            .{org, database, hostname, g_influx_info.influx_port,
            token, str1.len, str1});
    const send = try g_allocator.create(send_t);
    const out_data_slice = try g_allocator.alloc(u8, str2.len);
    send.* = .{.out_data_slice = out_data_slice};
    std.mem.copyForwards(u8, send.out_data_slice, str2);
    if (info.send_tail) |asend_tail|
    {
        asend_tail.next = send;
        info.send_tail = send;
    }
    else
    {
        info.send_head = send;
        info.send_tail = send;
    }
}

//*****************************************************************************
fn process_msg(info: *info_t, s: *parse.parse_t) !void
{
    var value: f32 = undefined;
    var table_name: []const u8 = undefined;
    try s.check_rem(8);
    const type1 = s.in_u16_le();
    const id = s.in_u16_le();
    const address1 = s.in_u16_le();
    const count = s.in_u16_le();
    if ((type1 == 0) and (id == 9))
    {
        if ((address1 == 256) and (count == 10))
        {
            try s.check_rem(4);
            s.in_u8_skip(2); // percent
            // volts
            const volts = s.in_u16_le();
            value = @floatFromInt(volts);
            value /= 10.0;
            table_name = "renogy_volts";
            try process_msg_table(info, table_name, value);
            // amps
            try s.check_rem(2);
            const amps = s.in_u16_le();
            value = @floatFromInt(amps);
            value /= 100.0;
            table_name = "renogy_amps";
            try process_msg_table(info, table_name, value);
            try s.check_rem(10);
            s.in_u8_skip(8); // temp, load
            // pvvolts
            const pvvolts = s.in_u16_le();
            value = @floatFromInt(pvvolts);
            value /= 10.0;
            table_name = "renogy_pvvolts";
            try process_msg_table(info, table_name, value);
            // pvamps
            try s.check_rem(2);
            const pvamps = s.in_u16_le();
            value = @floatFromInt(pvamps);
            value /= 100.0;
            table_name = "renogy_pvamps";
            try process_msg_table(info, table_name, value);
            // pvwatts
            try s.check_rem(2);
            const pvwatts = s.in_u16_le();
            value = @floatFromInt(pvwatts);
            table_name = "renogy_pvwatts";
            try process_msg_table(info, table_name, value);
        }
    }
    else if ((type1 == 1) and (id == 3))
    {
        if ((address1 == 0) and (count == 8))
        {
            // volts
            try s.check_rem(2);
            const pzem3volts = s.in_u16_le();
            value = @floatFromInt(pzem3volts);
            value /= 100;
            table_name = "pzem3_volts";
            try process_msg_table(info, table_name, value);
            // amps
            try s.check_rem(2);
            const pzem3amps = s.in_u16_le();
            value = @floatFromInt(pzem3amps);
            value /= 100;
            table_name = "pzem3_amps";
            try process_msg_table(info, table_name, value);
            // watts
            try s.check_rem(2);
            const pzem3watts = s.in_u16_le();
            value = @floatFromInt(pzem3watts);
            value /= 10;
            table_name = "pzem3_watts";
            try process_msg_table(info, table_name, value);
        }
    }
    else if ((type1 == 1) and (id == 6))
    {
        if ((address1 == 0) and (count == 8))
        {
            // volts
            try s.check_rem(2);
            const pzem6volts = s.in_u16_le();
            value = @floatFromInt(pzem6volts);
            value /= 100;
            table_name = "pzem6_volts";
            try process_msg_table(info, table_name, value);
            // amps
            try s.check_rem(2);
            const pzem6amps = s.in_u16_le();
            value = @floatFromInt(pzem6amps);
            value /= 100;
            table_name = "pzem6_amps";
            try process_msg_table(info, table_name, value);
            // watts
            try s.check_rem(2);
            const pzem6watts = s.in_u16_le();
            value = @floatFromInt(pzem6watts);
            value /= 10;
            table_name = "pzem6_watts";
            try process_msg_table(info, table_name, value);
        }
    }
    else if ((type1 == 1) and (id == 10))
    {
        if ((address1 == 0) and (count == 8))
        {
            // volts
            try s.check_rem(2);
            const pzem10volts = s.in_u16_le();
            value = @floatFromInt(pzem10volts);
            value /= 100;
            table_name = "pzem10_volts";
            try process_msg_table(info, table_name, value);
            // amps
            try s.check_rem(2);
            const pzem10amps = s.in_u16_le();
            value = @floatFromInt(pzem10amps);
            value /= 100;
            table_name = "pzem10_amps";
            try process_msg_table(info, table_name, value);
            // watts
            try s.check_rem(2);
            const pzem10watts = s.in_u16_le();
            value = @floatFromInt(pzem10watts);
            value /= 10;
            table_name = "pzem10_watts";
            try process_msg_table(info, table_name, value);
        }
    }
    else if ((type1 == 1) and (id == 11))
    {
        if ((address1 == 1) and (count == 2))
        {
            // temp
            try s.check_rem(2);
            const temp11temp = s.in_u16_le();
            value = @floatFromInt(temp11temp);
            value /= 10;
            table_name = "temp11_temp";
            try process_msg_table(info, table_name, value);
            // hum
            try s.check_rem(2);
            const temp11hum = s.in_u16_le();
            value = @floatFromInt(temp11hum);
            value /= 10;
            table_name = "temp11_hum";
            try process_msg_table(info, table_name, value);
        }
    }
    else if ((type1 == 1) and (id == 12))
    {
        if ((address1 == 0) and (count == 10))
        {
            // volts
            try s.check_rem(2);
            value = @floatFromInt(s.in_u16_le());
            value /= 10;
            table_name = "pzem12_volts";
            try process_msg_table(info, table_name, value);
            // amps
            try s.check_rem(4);
            value = @floatFromInt(s.in_u32_le());
            value /= 1000;
            table_name = "pzem12_amps";
            try process_msg_table(info, table_name, value);
            // watts
            try s.check_rem(4);
            value = @floatFromInt(s.in_u32_le());
            value /= 10;
            table_name = "pzem12_watts";
            try process_msg_table(info, table_name, value);
        }
    }
    else if ((type1 == 1) and (id == 13))
    {
        if ((address1 == 0) and (count == 10))
        {
            // volts
            try s.check_rem(2);
            value = @floatFromInt(s.in_u16_le());
            value /= 10;
            table_name = "pzem13_volts";
            try process_msg_table(info, table_name, value);
            // amps
            try s.check_rem(4);
            value = @floatFromInt(s.in_u32_le());
            value /= 1000;
            table_name = "pzem13_amps";
            try process_msg_table(info, table_name, value);
            // watts
            try s.check_rem(4);
            value = @floatFromInt(s.in_u32_le());
            value /= 10;
            table_name = "pzem13_watts";
            try process_msg_table(info, table_name, value);
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
fn process_isck_in(info: *info_t) !void
{
    const read = posix.recv(info.isck, &info.buffer_in, 0);
    if (read) |aread|
    {
        try log.logln_devel(log.LogLevel.info, @src(),
                "posix.recv rv {}", .{aread});
        if (aread > 0)
        {
        }
        else
        {
            return error.InvalidParam;
        }
    }
    else |err|
    {
        // WouldBlock is ok
        if (err != error.WouldBlock)
        {
            return err;
        }
    }
}

//*****************************************************************************
fn process_isck_out(info: *info_t) !void
{
    if (info.send_head) |asend_head|
    {
        const send = asend_head;
        const slice = send.out_data_slice[send.sent..];
        const sent = try posix.send(info.isck, slice, 0);
        if (sent > 0)
        {
            send.sent += sent;
            if (send.sent >= send.out_data_slice.len)
            {
                info.send_head = send.next;
                if (info.send_head == null)
                {
                    // if send_head is null, set send_tail to null
                    info.send_tail = null;
                }
                g_allocator.free(send.out_data_slice);
                g_allocator.destroy(send);
            }
        }
        else
        {
            return error.InvalidParam;
        }
    }
}

//*****************************************************************************
fn clear_out_queue(info: *info_t) void
{

    var send = info.send_head;
    while (send) |asend|
    {
        send = asend.next;
        g_allocator.free(asend.out_data_slice);
        g_allocator.destroy(asend);
    }
    info.send_head = null;
    info.send_tail = null;
}

//*****************************************************************************
fn csck_can_recv(info: *info_t, ins: *parse.parse_t) !void
{
    // try to connect to influx if not connected
    if (connect_isck(info)) |_| { } else |err|
    {
        if (info.isck != -1)
        {
            const sck = info.isck;
            posix.close(info.isck);
            info.isck = -1;
            try log.logln(log.LogLevel.info, @src(),
                    "connect_isck err {}, close for sck {}",
                    .{err, sck});
        }
        else
        {
            try log.logln(log.LogLevel.info, @src(),
                    "connect_isck err {}", .{err});
        }
    }
    try process_csck_in(info, ins);
}

//*****************************************************************************
fn isck_can_recv(info: *info_t, isck_index: *?usize) !void
{
    if (process_isck_in(info)) |_| { } else |err|
    {
        if (info.isck != -1)
        {
            const sck = info.isck;
            posix.close(info.isck);
            info.isck = -1;
            try log.logln(log.LogLevel.info, @src(),
                    "process_isck_in err {}, close for sck {}",
                    .{err, sck});
        }
        else
        {
            try log.logln(log.LogLevel.info, @src(),
                    "process_isck_in err {}", .{err});
        }
        info.connecting = false;
        isck_index.* = null;
    }
}

//*****************************************************************************
fn isck_can_send(info: *info_t) !void
{
    if (info.connecting)
    {
        info.connecting = false;
        try log.logln(log.LogLevel.info, @src(),
                "sck {} got connected", .{info.isck});
    }
    if (process_isck_out(info)) |_| { } else |err|
    {
        if (info.isck != -1)
        {
            const sck = info.isck;
            posix.close(info.isck);
            info.isck = -1;
            try log.logln(log.LogLevel.info, @src(),
                    "process_isck_out err {}, close for sck {}",
                    .{err, sck});
        }
        else
        {
            try log.logln(log.LogLevel.info, @src(),
                    "process_isck_out err {}", .{err});
        }
    }
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
        try log.logln_devel(log.LogLevel.info, @src(),
                "loop", .{});

        timeout = -1;

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

        // set influx fd if exists
        var isck_index: ?usize = null;
        if (info.isck != -1)
        {
            isck_index = poll_count;
            polls[poll_count].fd = info.isck;
            polls[poll_count].events = posix.POLL.IN;
            polls[poll_count].revents = 0;
            if ((info.send_head != null) or info.connecting)
            {
                // we have data to write
                polls[poll_count].events |= posix.POLL.OUT;
            }
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
            if ((active_polls[csck_index].revents & posix.POLL.IN) != 0)
            {
                try csck_can_recv(info, ins);
            }
            if (isck_index) |aisck_index|
            {
                if ((active_polls[aisck_index].revents & posix.POLL.IN) != 0)
                {
                    try isck_can_recv(info, &isck_index);
                }
            }
            if (isck_index) |aisck_index|
            {
                if ((active_polls[aisck_index].revents & posix.POLL.OUT) != 0)
                {
                    try isck_can_send(info);
                }
            }
        }
        if (info.isck == -1)
        {
            clear_out_queue(info);
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
    set_influx_defaults(&g_influx_info);
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
            const log_file = std.mem.sliceTo(&g_influx_info.log_file, 0);
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
    try log.logln(log.LogLevel.info, @src(), "tty_reader_influx", .{});
    try setup_influx_info(&g_influx_info, std.mem.sliceTo(&g_config_file, 0));
    // setup signals
    try setup_signals();
    defer cleanup_signals();
    try log.logln(log.LogLevel.info, @src(), "signals init ok", .{});

    const info = try g_allocator.create(info_t);
    defer g_allocator.destroy(info);
    info.* = .{};

    const connect_socket = std.mem.sliceTo(&g_influx_info.connect_socket, 0);
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

    clear_out_queue(info);
}
