const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.addModule("actuon_core", .{
        .root_source_file = b.path("src/actuon_core.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = core })).step);

    // libactuon_core: same judge code for the Rust IR server. Always bounds-checked: it reads uploads.
    const core_lib = b.addLibrary(.{
        .name = "actuon_core",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capi_entry.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .link_libc = true,
            .pic = true,
        }),
    });
    core_lib.bundle_compiler_rt = true; // Rust links this archive with no Zig runtime around it
    const core_step = b.step("core", "Build libactuon_core (C ABI)");
    core_step.dependOn(&b.addInstallArtifact(core_lib, .{}).step);
    core_step.dependOn(&b.addInstallHeaderFile(b.path("src/core/actuon_core.h"), "actuon_core.h").step);

    const tools = b.step("tools", "Build developer tools");
    for ([_][]const u8{ "chartdump", "mkreplay", "fuzz_parser" }) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tools/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "actuon_core", .module = core }},
            }),
        });
        tools.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(b.path("third_party"));
    translate.addIncludePath(b.path("src"));

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "actuon_core", .module = core },
            .{ .name = "c", .module = translate.createModule() },
        },
    });
    mod.addCSourceFile(.{ .file = b.path("third_party/impl.c"), .flags = &.{ "-O2", "-fno-sanitize=undefined" } });
    mod.addIncludePath(b.path("third_party"));
    mod.addIncludePath(b.path("src/ui"));
    mod.addAnonymousImport("backdrop", .{ .root_source_file = b.path("assets/backgrounds/rogland_clear_night.jpg") });
    mod.addAnonymousImport("font_medium", .{ .root_source_file = b.path("assets/fonts/SUITE-Medium.ttf") });
    mod.addAnonymousImport("font_heavy", .{ .root_source_file = b.path("assets/fonts/SUITE-ExtraBold.ttf") });
    const os = target.result.os.tag;
    if (os == .macos) {
        mod.addCSourceFile(.{ .file = b.path("src/ui/render_backend.m"), .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" } });
        mod.linkFramework("Metal", .{});
        mod.linkFramework("QuartzCore", .{});
        mod.linkFramework("Foundation", .{});
    } else {
        mod.addCSourceFile(.{ .file = b.path("src/ui/render_backend.c"), .flags = &.{"-fno-sanitize=undefined"} });
    }
    if (os == .windows) {
        mod.addCSourceFile(.{ .file = b.path("src/input/rawinput_win.c"), .flags = &.{} });
        mod.linkSystemLibrary("d3d11", .{});
        mod.linkSystemLibrary("dxgi", .{});
        mod.linkSystemLibrary("dxguid", .{});
    }
    if (os == .linux) mod.linkSystemLibrary("vulkan", .{ .use_pkg_config = .force });
    if (os == .macos) {
        mod.addCSourceFile(.{ .file = b.path("src/input/hid_macos.c"), .flags = &.{} });
        mod.linkFramework("IOKit", .{});
        mod.linkFramework("CoreFoundation", .{});
    }
    const libs = [_][]const u8{ "sdl3", "sdl3-ttf", "portaudio-2.0", "sqlite3", "lua5.4", "libarchive", "libavformat", "libavcodec", "libavutil", "libswscale", "libavfilter" };
    for (libs) |lib| mod.linkSystemLibrary(lib, .{ .use_pkg_config = .force });
    for (libs) |lib| translate.linkSystemLibrary(lib, .{});

    const exe = b.addExecutable(.{ .name = "actuon", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run actuon").dependOn(&run.step);

    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
}
