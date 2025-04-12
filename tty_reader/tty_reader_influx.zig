const std = @import("std");
const hexdump = @import("hexdump");
const parse = @import("parse");
const net = std.net;
const posix = std.posix;

var g_allocator: std.mem.Allocator = std.heap.c_allocator;

const g_influx_database = "solar";
const g_influx_token =
    "Wh4XF_BN120-dvfZiI0T6L7DIdG7Ma8JnSMW6GnMTpT5" ++
    "uG4qDlBFsEGS_jwo9eBD2pf2jtra7sgi0ajl5R-oEA==";
const g_influx_hostname = "server3.xrdp.org";
const g_influx_port: c_int = 8086;
const g_secs: c_int = 60;

const info_t = struct
{
    buffer_out: [2048]u8 = undefined,
    buffer_con: [64]u8 = undefined,
    buffer_in: [1024]u8 = undefined,
    influx_ip: [64]u8 = undefined,
    sck: i32 = -1,
};

//*****************************************************************************
fn process_msg_table(info: *info_t, table_name: []const u8,
        voltage: f32) !void
{
    const str1 = try std.fmt.bufPrint(&info.buffer_con,
            "{s},host=serverA value={d:.2}\n", .{table_name, voltage});
    const str2 = try std.fmt.bufPrint(&info.buffer_out,
            "POST /api/v2/write?org=org1&bucket={s} HTTP/1.1\r\n" ++
            "Host: {s}:{}\r\n" ++
            "Authorization: Token {s}\r\n" ++
            "Content-Type: text/plain; charset=utf-8\r\n" ++
            "Accept: application/json\r\n" ++
            "Content-Length: {}\r\n\r\n{s}",
            .{g_influx_database, g_influx_hostname, g_influx_port,
            g_influx_token, str1.len, str1});
    if (info.sck == -1)
    {
        const port_u16: u16 = 8086;
        const address_list = try std.net.getAddressList(g_allocator,
                g_influx_hostname, port_u16);
        defer address_list.deinit();
        if (address_list.addrs.len < 1)
        {
            return error.InvalidParam;
        }
        const address = address_list.addrs[0];
        const tpe: u32 = posix.SOCK.STREAM;
        info.sck = try posix.socket(address.any.family, tpe, 0);
        const address_len = address.getOsSockLen();
        try posix.connect(info.sck, &address.any, address_len);
        std.debug.print("connected host {s} sck {}\n",
                .{g_influx_hostname, info.sck});
    }
    const sent = try posix.send(info.sck, str2, 0);
    if (sent == str2.len)
    {
        const read = try posix.recv(info.sck, &info.buffer_in, 0);
        if (read > 0)
        {
            const read_text = info.buffer_in[0..read];
            const found = std.mem.containsAtLeast(u8, read_text, 1,
                    "204 No Content");
            if (found)
            {
                return;
            }
        }
    }
    return error.InvalidParam;
}

//*****************************************************************************
fn process_msg_table_bool(info: *info_t, table_name: []const u8,
        value: f32) bool
{
    const result = process_msg_table(info, table_name, value);
    if (result) |_| { } else |err|
    {
        std.debug.print("process_msg_table {s} err {}\n", .{table_name, err});
        if (info.sck != -1)
        {
            std.debug.print("closing sck {}\n", .{info.sck});
            posix.close(info.sck);
            info.sck = -1;
        }
        return false;
    }
    return true;
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
            table_name = "renogy_volts";
            if (!process_msg_table_bool(info, table_name, value))
            {
                return;
            }
            // amps
            try s.check_rem(2);
            const amps = s.in_u16_le();
            value = @floatFromInt(amps);
            value /= 100.0;
            table_name = "renogy_amps";
            if (!process_msg_table_bool(info, table_name, value))
            {
                return;
            }
            try s.check_rem(10);
            s.in_u8_skip(8); // temp, load
            // pvvolts
            const pvvolts = s.in_u16_le();
            value = @floatFromInt(pvvolts);
            value /= 10.0;
            table_name = "renogy_pvvolts";
            if (!process_msg_table_bool(info, table_name, value))
            {
                return;
            }
            // pvamps
            try s.check_rem(2);
            const pvamps = s.in_u16_le();
            value = @floatFromInt(pvamps);
            value /= 100.0;
            table_name = "renogy_pvamps";
            if (!process_msg_table_bool(info, table_name, value))
            {
                return;
            }
            // pvwatts
            try s.check_rem(2);
            const pvwatts = s.in_u16_le();
            value = @floatFromInt(pvwatts);
            table_name = "renogy_pvwatts";
            if (!process_msg_table_bool(info, table_name, value))
            {
                return;
            }
        }
    }
    else if ((type1 == 1) and (id == 3))
    {
        if (address1 == 0 and count == 8)
        {
            // volts
            try s.check_rem(2);
            const pzem3volts = s.in_u16_le();
            value = @floatFromInt(pzem3volts);
            value /= 100;
            table_name = "pzem3_volts";
            if (!process_msg_table_bool(info, table_name, value))
            {
                return;
            }
            // amps
            try s.check_rem(2);
            const pzem3amps = s.in_u16_le();
            value = @floatFromInt(pzem3amps);
            value /= 100;
            table_name = "pzem3_amps";
            if (!process_msg_table_bool(info, table_name, value))
            {
                return;
            }
            // watts
            try s.check_rem(2);
            const pzem3watts = s.in_u16_le();
            value = @floatFromInt(pzem3watts);
            value /= 10;
            table_name = "pzem3_watts";
            if (!process_msg_table_bool(info, table_name, value))
            {
                return;
            }
        }
    }
    else if ((type1 == 1) and (id == 6))
    {
        if (address1 == 0 and count == 8)
        {
            // volts
            try s.check_rem(2);
            const pzem6volts = s.in_u16_le();
            value = @floatFromInt(pzem6volts);
            value /= 100;
            table_name = "pzem6_volts";
            if (!process_msg_table_bool(info, table_name, value))
            {
                return;
            }
            // amps
            try s.check_rem(2);
            const pzem6amps = s.in_u16_le();
            value = @floatFromInt(pzem6amps);
            value /= 100;
            table_name = "pzem6_amps";
            if (!process_msg_table_bool(info, table_name, value))
            {
                return;
            }
            // watts
            try s.check_rem(2);
            const pzem6watts = s.in_u16_le();
            value = @floatFromInt(pzem6watts);
            value /= 10;
            table_name = "pzem6_watts";
            if (!process_msg_table_bool(info, table_name, value))
            {
                return;
            }
        }
    }
}

//*****************************************************************************
pub fn main() !void
{
    std.debug.print("tty_reader_influx\n", .{});
    const address = try net.Address.initUnix("/tmp/tty_reader.socket");
    const tpe: u32 = posix.SOCK.STREAM;
    const sck = try posix.socket(address.any.family, tpe, 0);
    const address_len = address.getOsSockLen();
    const result = try posix.connect(sck, &address.any, address_len);
    _ = result;
    const ins = try parse.create(&g_allocator, 64 * 1024);
    defer ins.delete();
    const recv_slice = ins.data;
    const info = try g_allocator.create(info_t);
    defer g_allocator.destroy(info);
    info.* = .{};
    var code: u16 = 0;
    var size: u16 = 0;
    var to_read: usize = 4;
    var readed: usize = 0;
    while (true)
    {
        const recv_rv = try posix.recv(sck, recv_slice[readed..to_read], 0);
        if (recv_rv < 1)
        {
            break;
        }
        readed += recv_rv;
        if (readed == to_read)
        {
            if (to_read == 4)
            {
                try ins.reset(0);
                try ins.check_rem(4);
                code = ins.in_u16_le();
                size = ins.in_u16_le();
                if (size <= 4)
                {
                    return error.InvalidParam;
                }
                to_read = size;
            }
            else
            {
                if (code == 0)
                {
                    const s = try parse.create_from_slice(&g_allocator,
                            recv_slice[4..readed]);
                    defer s.delete();
                    try process_msg(info, s);
                }
                readed = 0;
                to_read = 4;
            }
        }
    }
}
