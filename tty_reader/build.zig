const std = @import("std");

pub fn build(b: *std.Build) void
{
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // tty_reader
    const tty_reader = b.addExecutable(.{
        .name = "tty_reader",
        .root_source_file = b.path("tty_reader.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
    });
    tty_reader.linkLibC();
    tty_reader.addIncludePath(b.path("."));
    tty_reader.addCSourceFiles(.{ .files = libtomlc_sources });
    tty_reader.linkSystemLibrary("modbus");
    tty_reader.root_module.addImport("hexdump", b.createModule(.{
        .root_source_file = b.path("common/hexdump.zig"),
    }));
    tty_reader.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("common/log.zig"),
    }));
    setExtraLibraryPaths(tty_reader, target);
    b.installArtifact(tty_reader);
}

fn setExtraLibraryPaths(compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void
{
    if (target.result.cpu.arch == std.Target.Cpu.Arch.x86)
    {
        // zig seems to use /usr/lib/x86-linux-gnu instead
        // of /usr/lib/i386-linux-gnu
        compile.addLibraryPath(.{.cwd_relative = "/usr/lib/i386-linux-gnu/"});
    }
}

const libtomlc_sources = &.{
    "toml.c",
};
