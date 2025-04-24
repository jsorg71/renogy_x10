const std = @import("std");
const builtin = @import("builtin");
const log = @import("log");
const tty = @import("tty_reader.zig");
const c = @cImport(
{
    @cInclude("toml.h");
});

pub const TomlError = error
{
    FileSizeChanged,
    TomlParseFailed,
    TomlTableInFailed,
};

var g_allocator: *const std.mem.Allocator = undefined;
const g_error_buf_size: usize = 1024;

//*****************************************************************************
inline fn err_if(b: bool, err: TomlError) !void
{
    if (b) return err else return;
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
    errbuf = try g_allocator.alloc(u8, g_error_buf_size);
    defer g_allocator.free(errbuf);
    const bytes_read = try in_stream.read(buf);
    try log.logln(log.LogLevel.info, @src(),
            "file_size {} bytes read {}", .{file_size, bytes_read});
    try err_if(bytes_read > file_size, TomlError.FileSizeChanged);
    buf[bytes_read] = 0;
    const table = c.toml_parse(buf.ptr, errbuf.ptr, g_error_buf_size);
    if (table) |atable|
    {
        return atable;
    }
    try log.logln(log.LogLevel.info, @src(), 
            "toml_parse failed errbuf {s}", .{errbuf});
    return TomlError.TomlParseFailed;
}

//*****************************************************************************
fn toml_malloc(size: usize) callconv(.C) ?*anyopaque
{
    // if (builtin.mode == .ReleaseSafe)
    // {
    //     // for valgrind warnings
    //     return std.c.calloc(1, size + 16);
    // }
    // else
    {
        return std.c.malloc(size);
    }
}

//*****************************************************************************
fn toml_free(ptr: ?*anyopaque) callconv(.C) void
{
    std.c.free(ptr);
}

//*****************************************************************************
pub fn setup_tty_info(allocator: *const std.mem.Allocator,
        info: *tty.tty_info_t, config_file: []const u8) !void
{
    try log.logln(log.LogLevel.info, @src(),
            "config file [{s}]", .{config_file});
    g_allocator = allocator;
    c.toml_set_memutil(toml_malloc, toml_free);
    const table = try load_tty_config(config_file);
    defer c.toml_free(table);
    try log.logln(log.LogLevel.info, @src(),
            "load_tty_config ok for file [{s}]",
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
                else if (std.mem.eql(u8, alkey_slice, "modbus_debug"))
                {
                    const val = c.toml_bool_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        info.modbus_debug = val.u.b != 0;
                    }
                }
                else if (std.mem.eql(u8, alkey_slice, "item_mstime"))
                {
                    const val = c.toml_int_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        info.item_mstime = val.u.i;
                    }
                }
                else if (std.mem.eql(u8, alkey_slice, "list_mstime"))
                {
                    const val = c.toml_int_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        info.list_mstime = val.u.i;
                    }
                }
                else if (std.mem.eql(u8, alkey_slice, "listen_socket"))
                {
                    const val = c.toml_string_in(ltable, alkey_slice);
                    if (val.ok != 0)
                    {
                        @memset(&info.listen_socket, 0);
                        std.mem.copyForwards(u8, &info.listen_socket,
                                std.mem.sliceTo(val.u.s, 0));
                        std.c.free(val.u.s);
                    }
                }
            }
        }
        else if ((akey_slice.len > 1) and (akey_slice[0] == 'i') and
                (akey_slice[1] == 'd'))
        {
            var item: tty.tty_id_info_t = .{};
            item.id = try std.fmt.parseInt(u8, akey_slice[2..], 10);
            const ltable = c.toml_table_in(table, akey);
            try err_if(ltable == null, TomlError.TomlTableInFailed);
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
