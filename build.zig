const std = @import("std");

pub fn build(b: *std.Build) void {
    // Baseline, not the build machine's CPU: a release built on CI's AVX2 runner died with SIGILL on older CPUs.
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_model = .baseline } });
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
    mod.addAnonymousImport("logo", .{ .root_source_file = b.path("assets/brand/logo.png") });
    mod.addAnonymousImport("app_icon", .{ .root_source_file = b.path("assets/brand/icon.png") });
    mod.addAnonymousImport("backdrop", .{ .root_source_file = b.path("assets/backgrounds/rogland_clear_night.jpg") });
    mod.addAnonymousImport("font_medium", .{ .root_source_file = b.path("assets/fonts/SUITE-Medium.ttf") });
    mod.addAnonymousImport("font_heavy", .{ .root_source_file = b.path("assets/fonts/SUITE-ExtraBold.ttf") });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    mod.addOptions("build_options", build_options);
    const os = target.result.os.tag;
    // Shaders are WGSL. Vulkan reads naga's SPIR-V; spirv-cross turns that into what the other backends read.
    const shaders = [_][]const u8{ "sprite.vert", "sprite.frag", "upscale.vert", "upscale.frag", "fsrcnnx_unpack.frag", "fsrcnnx_0.frag", "fsrcnnx_1.frag", "fsrcnnx_2.frag", "fsrcnnx_3.frag", "fsrcnnx_4.frag", "fsrcnnx_5.frag", "fsrcnnx_6.frag", "fsrcnnx_7.frag", "fsrcnnx_8.frag", "fsrcnnx_9.frag", "fsrcnnx_10.frag", "fsrcnnx_11.frag", "fsrcnnx_12.frag" };
    for (shaders) |name| {
        const naga = b.addSystemCommand(&.{ "naga", "--keep-coordinate-space" });
        naga.addFileArg(b.path(b.fmt("src/ui/shaders/{s}.wgsl", .{name})));
        var shader = naga.addOutputFileArg(b.fmt("{s}.spv", .{name}));
        if (os == .windows or os == .macos) {
            const cross = b.addSystemCommand(&.{"spirv-cross"});
            cross.addFileArg(shader);
            if (os == .windows) cross.addArgs(&.{ "--hlsl", "--shader-model", "50" }) else cross.addArgs(&.{ "--msl", "--msl-version", "20000", "--msl-decoration-binding" });
            cross.addArg("--output");
            shader = cross.addOutputFileArg(b.fmt("{s}.src", .{name}));
        }
        mod.addAnonymousImport(name, .{ .root_source_file = shader });
    }
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
    if (os == .linux) {
        mod.linkSystemLibrary("vulkan", .{ .use_pkg_config = .force });
        mod.linkSystemLibrary("alsa", .{ .use_pkg_config = .force });
        translate.linkSystemLibrary("alsa", .{});
    }
    if (os == .macos) {
        mod.addCSourceFile(.{ .file = b.path("src/input/hid_macos.c"), .flags = &.{} });
        mod.linkFramework("IOKit", .{});
        mod.linkFramework("CoreFoundation", .{});
    }
    // pkgconf hides MSYS2's own include and lib folders as defaults, but zig does not search them.
    // translate-c gets include paths only: on Windows, -l fails with "coff does not support linking multiple objects".
    if (os == .windows) {
        const prefix = std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=prefix", "sdl3" }), "\r\n");
        const include: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) };
        mod.addIncludePath(include);
        translate.addIncludePath(include);
        translate.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include", "lua5.4" }) });
        // By full path: MSYS2's sdl3.pc lists -mwindows, which zig's pkg-config reader refuses, and -l picks the static libraries.
        for ([_][]const u8{ "portaudio", "SDL3", "SDL3_ttf", "sqlite3", "lua5.4", "archive", "avformat", "avcodec", "avutil", "swscale", "avfilter" }) |lib|
            mod.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib", b.fmt("lib{s}.dll.a", .{lib}) }) });
    }
    // Homebrew's portaudio-2.0.pc lists -framework, which zig's pkg-config reader refuses.
    if (os == .macos) {
        const portaudio = std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=prefix", "portaudio-2.0" }), "\n");
        const include: std.Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ portaudio, "include" }) };
        mod.addIncludePath(include);
        translate.addIncludePath(include);
        mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ portaudio, "lib" }) });
        mod.linkSystemLibrary("portaudio", .{ .use_pkg_config = .no });
    } else if (os != .windows) {
        mod.linkSystemLibrary("portaudio-2.0", .{ .use_pkg_config = .force });
        translate.linkSystemLibrary("portaudio-2.0", .{});
    }
    // sdl3-ttf also brings SDL3; naming both links it twice, which macOS refuses at startup.
    const libs = [_][]const u8{ "sdl3-ttf", "sqlite3", "lua5.4", "libarchive", "libavformat", "libavcodec", "libavutil", "libswscale", "libavfilter" };
    if (os != .windows) {
        for (libs) |lib| mod.linkSystemLibrary(lib, .{ .use_pkg_config = .force });
        for (libs) |lib| translate.linkSystemLibrary(lib, .{});
    }

    const exe = b.addExecutable(.{ .name = "actuon", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run actuon").dependOn(&run.step);

    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
}
