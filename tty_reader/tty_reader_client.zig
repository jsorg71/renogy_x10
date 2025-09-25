const std = @import("std");
const hexdump = @import("hexdump");
const parse = @import("parse");
const net = std.net;
const posix = std.posix;

pub var g_allocator: std.mem.Allocator = std.heap.c_allocator;

var g_data: [1024]u8 = undefined;

pub fn main() !void
{
    std.debug.print("hello\n", .{});
    const address = try net.Address.initUnix("/tmp/tty_reader.socket");
    const tpe: u32 = posix.SOCK.STREAM;
    const sck = try posix.socket(address.any.family, tpe, 0);
    const address_len = address.getOsSockLen();
    const result = try posix.connect(sck, &address.any, address_len);
    _ = result;
    const recv_slice = &g_data;
    while (true)
    {
        const recv_rv = try posix.recv(sck, recv_slice, 0);
        if (recv_rv < 1)
        {
            break;
        }
        //std.debug.print("recv {}\n", .{recv_rv});
        //try hexdump.printHexDump(0, recv_slice[0..recv_rv]);
        const s = try parse.create_from_slice(&g_allocator, recv_slice[0..recv_rv]);
        defer s.delete();
        try s.check_rem(recv_rv);
        if (s.in_u16_le() == 0)
        {
            if (s.in_i16_le() > 0) // size
            {
                const type1 = s.in_u16_le();
                const id = s.in_u16_le();
                const address1 = s.in_u16_le();
                const count = s.in_u16_le();
                if ((type1 == 0) and (id == 1))
                {
                    if (address1 == 256 and count == 10)
                    {
                        const percent = s.in_u16_le();
                        var voltage: f32 = @floatFromInt(s.in_u16_le());
                        voltage /= 10;
                        var amps: f32 = @floatFromInt(s.in_u16_le());
                        amps /= 100;
                        const val1 = s.in_u16_le(); // temp
                        const val2 = s.in_u16_le(); // load volts
                        const val3 = s.in_u16_le(); // load amps
                        const val4 = s.in_u16_le(); // load watts
                        var pvvoltage: f32 = @floatFromInt(s.in_u16_le());
                        pvvoltage /= 10;
                        var pvamps: f32 = @floatFromInt(s.in_u16_le());
                        pvamps /= 100;
                        const pvwatts = s.in_u16_le(); // pv watts
                        std.debug.print("id {} " ++
                                "percent {} " ++
                                "voltage {d:.1} " ++
                                "amps {d:.2} " ++
                                "temp {} " ++
                                "load volts {} " ++
                                "load amps {} " ++
                                "load watts {} " ++
                                "pv volts {d:.1} " ++
                                "pv amps {d:.2} " ++
                                "pv watts {} percent {d:.1}\n",
                                .{id, percent, voltage, amps,
                                val1, val2, val3, val4,
                                pvvoltage, pvamps, pvwatts,
                                (voltage * amps) / (pvvoltage * pvamps + 1)});
                    }
                }
                else if ((type1 == 1) and (id == 3))
                {
                    if (address1 == 0 and count == 8)
                    {
                        var voltage: f32 = @floatFromInt(s.in_u16_le());
                        voltage /= 100;
                        var current: f32 = @floatFromInt(s.in_u16_le());
                        current /= 100;
                        var watts: f32 = @floatFromInt(s.in_u32_le());
                        watts /= 10;
                        const watthours = s.in_u32_le();
                        const hiallarm = s.in_u16_le();
                        const loallarm = s.in_u16_le();
                        std.debug.print("id {} voltage {d:.2} current {d:.2} watts {d:.1} watthours {} hiallarm 0x{x} loallarm 0x{x}\n",
                                .{id, voltage, current, watts, watthours, hiallarm, loallarm});
                    }
                }
                else if ((type1 == 1) and (id == 6))
                {
                    if (address1 == 0 and count == 8)
                    {
                        var voltage: f32 = @floatFromInt(s.in_u16_le());
                        voltage /= 100;
                        var current: f32 = @floatFromInt(s.in_u16_le());
                        current /= 100;
                        var watts: f32 = @floatFromInt(s.in_u32_le());
                        watts /= 10;
                        const watthours = s.in_u32_le();
                        const hiallarm = s.in_u16_le();
                        const loallarm = s.in_u16_le();
                        std.debug.print("id {} voltage {d:.2} current {d:.2} watts {d:.1} watthours {} hiallarm 0x{x} loallarm 0x{x}\n",
                                .{id, voltage, current, watts, watthours, hiallarm, loallarm});
                    }
                }
                else if ((type1 == 1) and (id == 10))
                {
                    if (address1 == 0 and count == 8)
                    {
                        var voltage: f32 = @floatFromInt(s.in_u16_le());
                        voltage /= 100;
                        var current: f32 = @floatFromInt(s.in_u16_le());
                        current /= 100;
                        var watts: f32 = @floatFromInt(s.in_u32_le());
                        watts /= 10;
                        const watthours = s.in_u32_le();
                        const hiallarm = s.in_u16_le();
                        const loallarm = s.in_u16_le();
                        std.debug.print("id {} voltage {d:.2} current {d:.2} watts {d:.1} watthours {} hiallarm 0x{x} loallarm 0x{x}\n",
                                .{id, voltage, current, watts, watthours, hiallarm, loallarm});
                    }
                }
            }
        }
    }
}
