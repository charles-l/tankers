const std = @import("std");

fn makeOdinTargetString(allocator: std.mem.Allocator, target: std.zig.CrossTarget) !?[]const u8 {
    if (target.cpu_arch == null) {
        return null;
    }
    if (target.cpu_arch.? == .wasm32) {
        return "freestanding_wasm32";
    }

    const arch_string = switch (target.cpu_arch.?) {
        .x86_64 => "amd64",
        .x86 => "i386",
        .arm => "arm32",
        .aarch64 => "arm64",
        else => @panic("unhandled cpu arch"),
    };

    return switch (target.os_tag.?) {
        .windows => try std.fmt.allocPrint(allocator, "windows_{s}", .{arch_string}),
        .linux => try std.fmt.allocPrint(allocator, "linux_{s}", .{arch_string}),
        .macos => try std.fmt.allocPrint(allocator, "darwin_{s}", .{arch_string}),
        else => std.debug.panic("can't build for {}", .{target}),
    };
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const is_web_target = target.cpu_arch != null and target.cpu_arch.? == .wasm32;

    const libraylib = b.addStaticLibrary(.{
        .name = "raylib",
        .target = target,
        .optimize = optimize,
    });

    const flags: []const []const u8 = if (is_web_target)
        &.{ "-fno-sanitize=undefined", "-DPLATFORM_WEB=1", "-DGRAPHICS_API_OPENGL_ES2=1", "-D__EMSCRIPTEN__", "-fno-strict-aliasing" }
    else
        &.{"-fno-sanitize=undefined"};

    libraylib.addCSourceFile("raylib/src/rcore.c", flags);
    libraylib.addCSourceFile("raylib/src/rshapes.c", flags);
    libraylib.addCSourceFile("raylib/src/rtextures.c", flags);
    libraylib.addCSourceFile("raylib/src/rtext.c", flags);
    libraylib.addCSourceFile("raylib/src/rmodels.c", flags);
    libraylib.addCSourceFile("raylib/src/utils.c", flags);
    libraylib.addCSourceFile("raylib/src/raudio.c", flags);

    libraylib.linkLibC();
    libraylib.addIncludePath("raylib/src");
    libraylib.addIncludePath("raylib/src/external/glfw/include/");

    var command: []const []const u8 = &.{ "odin", "build", "src", "-no-entry-point", "-build-mode:obj", "-out:zig-out/odinsrc.o", "-debug" };
    if (try makeOdinTargetString(b.allocator, target)) |odin_target_string| {
        const target_flag = try std.mem.concat(b.allocator, u8, &.{ "-target:", odin_target_string });
        command = try std.mem.concat(b.allocator, []const u8, &.{ command, &.{target_flag} });
    }
    const odin_compile = b.addSystemCommand(command);

    if (is_web_target) {
        if (b.sysroot == null) {
            @panic("need an emscripten --sysroot (e.g. --sysroot emsdk/upstream/emscripten) when building for web");
        }

        const emcc_path = try std.fs.path.join(b.allocator, &.{ b.sysroot.?, "emcc" });
        defer b.allocator.free(emcc_path);

        const em_include_path = try std.fs.path.join(b.allocator, &.{ b.sysroot.?, "cache/sysroot/include" });
        defer b.allocator.free(em_include_path);

        libraylib.defineCMacro("PLATFORM_WEB", "1");
        libraylib.addIncludePath(em_include_path);
        libraylib.defineCMacro("GRAPHICS_API_OPENGL_ES2", "1");
        libraylib.stack_protector = false;
        b.installArtifact(libraylib);

        const libgame = b.addStaticLibrary(.{
            .name = "game",
            .target = target,
            .optimize = optimize,
        });
        libgame.addIncludePath("raylib/src");
        b.installArtifact(libgame);

        { // odin source
            libgame.addObjectFile("zig-out/odinsrc.wasm.o");
            libgame.step.dependOn(&odin_compile.step);
        }

        { // entrypoint/link
            // `source ~/src/emsdk/emsdk_env.sh` first
            const emcc = b.addSystemCommand(&.{
                emcc_path,
                "entry.c",
                "zig-out/odinsrc.wasm.o",
                "-g",
                "-ogame.html",
                "-Lzig-out/lib/",
                "-lraylib",
                "-DPLATFORM_WEB",
                "--shell-file",
                "raylib/src/minshell.html",
                "-sASSERTIONS=1",
                "-sUSE_GLFW=3",
                "-sTOTAL_MEMORY=67108864",
                //"-sSTANDALONE_WASM",
                "--preload-file",
                "resources/@resources",
                "-sEXPORTED_FUNCTIONS=['_ma_malloc_emscripten','_main','_malloc','_free','_ma_device_process_pcm_frames_playback__webaudio']",
                //"-sEXPORTED_FUNCTIONS=['_malloc','_free','_main', '_ma_malloc_emscripten']",
            });

            emcc.step.dependOn(&libraylib.step);
            emcc.step.dependOn(&libgame.step);
            b.getInstallStep().dependOn(&emcc.step);
        }
    } else {
        libraylib.defineCMacro("PLATFORM_DESKTOP", "1");
        libraylib.addCSourceFile("raylib/src/rglfw.c", &.{ "-fno-sanitize=undefined", "-D_GNU_SOURCE" });

        if (target.isWindows()) {
            libraylib.linkSystemLibrary("opengl32");
            libraylib.linkSystemLibrary("gdi32");
            libraylib.linkSystemLibrary("winmm");
        } else if (target.isLinux()) {
            libraylib.linkSystemLibrary("pthread");
        }

        b.installArtifact(libraylib);

        const exe = b.addExecutable(.{
            .name = "game",
            .root_source_file = .{ .path = "src/main.zig" },
            .target = target,
            .optimize = optimize,
        });

        { // odin source
            if (target.isWindows()) {
                exe.addObjectFile("zig-out/odinsrc.obj");
            } else {
                exe.addObjectFile("zig-out/odinsrc.o");
            }
            exe.step.dependOn(&odin_compile.step);
        }

        exe.addIncludePath("raylib/src");

        exe.linkLibrary(libraylib);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);

        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }
}
