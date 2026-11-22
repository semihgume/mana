const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    // gtk4-layer-shell must come before anything that pulls in libwayland-client,
    // otherwise its protocol hooks are never used and windows stay plain toplevels.
    c.linkSystemLibrary("gtk4-layer-shell-0", .{});
    c.linkSystemLibrary("gtk4", .{});
    c.linkSystemLibrary("wayland-client", .{});

    // Client glue for the ext-data-control protocol, used to read the selection
    // without a focused window: a header for src/c.h and the interface tables.
    const protocol = b.path("protocol/ext-data-control-v1.xml");
    const scan_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    scan_header.addFileArg(protocol);
    const protocol_header = scan_header.addOutputFileArg("ext-data-control-v1-client-protocol.h");
    const scan_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    scan_code.addFileArg(protocol);
    const protocol_code = scan_code.addOutputFileArg("ext-data-control-v1-protocol.c");
    c.addIncludePath(protocol_header.dirname());

    const c_module = c.createModule();
    c_module.addCSourceFile(.{ .file = protocol_code });

    // build.zig.zon is the single source of the version; `--version` prints it.
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);

    const exe = b.addExecutable(.{
        .name = "mana",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "c", .module = c_module },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
}
