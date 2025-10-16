const std = @import("std");
const builtin = @import("builtin");

//*****************************************************************************
pub fn build(b: *std.Build) !void
{
    // build options
    const do_strip = b.option(
        bool,
        "strip",
        "Strip the executabes"
    ) orelse false;
    try update_git_zig(b.allocator);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // tty_reader
    const tty_reader = myAddExecutable(b, "tty_reader", target,optimize, do_strip);
    tty_reader.root_module.root_source_file = b.path("tty_reader.zig");
    tty_reader.linkLibC();
    tty_reader.addIncludePath(b.path("."));
    tty_reader.addCSourceFiles(.{.files = libtomlc_files});
    tty_reader.linkSystemLibrary("modbus");
    tty_reader.root_module.addImport("hexdump", b.createModule(.{
        .root_source_file = b.path("common/hexdump.zig"),
    }));
    tty_reader.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("common/log.zig"),
    }));
    tty_reader.root_module.addImport("parse", b.createModule(.{
        .root_source_file = b.path("common/parse.zig"),
    }));
    setExtraLibraryPaths(tty_reader, target);
    b.installArtifact(tty_reader);
    // tty_reader_client
    const tty_reader_client = myAddExecutable(b, "tty_reader_client", target,optimize, do_strip);
    tty_reader_client.root_module.root_source_file = b.path("tty_reader_client.zig");
    tty_reader_client.linkLibC();
    tty_reader_client.root_module.addImport("hexdump", b.createModule(.{
        .root_source_file = b.path("common/hexdump.zig"),
    }));
    tty_reader_client.root_module.addImport("parse", b.createModule(.{
        .root_source_file = b.path("common/parse.zig"),
    }));
    setExtraLibraryPaths(tty_reader_client, target);
    b.installArtifact(tty_reader_client);
    // tty_reader_influx
    const tty_reader_influx = myAddExecutable(b, "tty_reader_influx", target,optimize, do_strip);
    tty_reader_influx.root_module.root_source_file = b.path("tty_reader_influx.zig");
    tty_reader_influx.linkLibC();
    tty_reader_influx.root_module.addImport("hexdump", b.createModule(.{
        .root_source_file = b.path("common/hexdump.zig"),
    }));
    tty_reader_influx.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("common/log.zig"),
    }));
    tty_reader_influx.root_module.addImport("parse", b.createModule(.{
        .root_source_file = b.path("common/parse.zig"),
    }));
    setExtraLibraryPaths(tty_reader_influx, target);
    b.installArtifact(tty_reader_influx);
    // tty_reader_heyu
    const tty_reader_heyu = myAddExecutable(b, "tty_reader_heyu", target,optimize, do_strip);
    tty_reader_heyu.root_module.root_source_file = b.path("tty_reader_heyu.zig");
    tty_reader_heyu.linkLibC();
    tty_reader_heyu.root_module.addImport("hexdump", b.createModule(.{
        .root_source_file = b.path("common/hexdump.zig"),
    }));
    tty_reader_heyu.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("common/log.zig"),
    }));
    tty_reader_heyu.root_module.addImport("parse", b.createModule(.{
        .root_source_file = b.path("common/parse.zig"),
    }));
    setExtraLibraryPaths(tty_reader_heyu, target);
    b.installArtifact(tty_reader_heyu);
}

//*****************************************************************************
fn setExtraLibraryPaths(compile: *std.Build.Step.Compile,
        target: std.Build.ResolvedTarget) void
{
    if (target.result.cpu.arch == std.Target.Cpu.Arch.x86)
    {
        // zig seems to use /usr/lib/x86-linux-gnu instead
        // of /usr/lib/i386-linux-gnu
        compile.addLibraryPath(.{.cwd_relative = "/usr/lib/i386-linux-gnu/"});
    }
}

//*****************************************************************************
fn myAddExecutable(b: *std.Build, name: []const u8,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        do_strip: bool) *std.Build.Step.Compile
{
    if ((builtin.zig_version.major == 0) and (builtin.zig_version.minor < 15))
    {
        return b.addExecutable(.{
            .name = name,
            .target = target,
            .optimize = optimize,
            .strip = do_strip,
        });
    }
    return b.addExecutable(.{
        .name = name,
        .root_module = b.addModule(name, .{
            .target = target,
            .optimize = optimize,
            .strip = do_strip,
        }),
    });
}

//*****************************************************************************
fn update_git_zig(allocator: std.mem.Allocator) !void
{
    const cmdline = [_][]const u8{"git", "describe", "--always"};
    const rv = try std.process.Child.run(
            .{.allocator = allocator, .argv = &cmdline});
    defer allocator.free(rv.stdout);
    defer allocator.free(rv.stderr);
    const file = try std.fs.cwd().createFile("git.zig", .{});

    if ((builtin.zig_version.major == 0) and
        (builtin.zig_version.minor < 15))
    {
        const writer = file.writer();
        var sha1 = rv.stdout;
        while ((sha1.len > 0) and (sha1[sha1.len - 1] < 0x20))
        {
            sha1.len -= 1;
        }
        try writer.print("pub const g_git_sha1 = \"{s}\";\n", .{sha1});
    }
    else
    {
        var buf: [1024]u8 = undefined;
        var file_writer = file.writer(&buf);
        const writer = &file_writer.interface;
        var sha1 = rv.stdout;
        while ((sha1.len > 0) and (sha1[sha1.len - 1] < 0x20))
        {
            sha1.len -= 1;
        }
        try writer.print("pub const g_git_sha1 = \"{s}\";\n", .{sha1});
        try writer.flush();
    }
}

const libtomlc_files = &.{
    "toml.c",
};
