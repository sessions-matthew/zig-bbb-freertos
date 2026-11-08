const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSmall,
    });

    // ------------------------------------------------------------------------
    // Target: BeagleBone Black AM3359 (ARM Cortex-A8 Freestanding)
    // ------------------------------------------------------------------------
    const bbb_target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a8 },
        .os_tag = .freestanding,
        .abi = .eabi,
    });

    const hal_mod = b.createModule(.{
        .root_source_file = b.path("src/hal/root.zig"),
        .target = bbb_target,
        .optimize = optimize,
    });

    const rtos_mod = b.createModule(.{
        .root_source_file = b.path("src/rtos/root.zig"),
        .target = bbb_target,
        .optimize = optimize,
    });

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = bbb_target,
        .optimize = optimize,
        .strip = false,
        .imports = &.{
            .{ .name = "hal", .module = hal_mod },
            .{ .name = "rtos", .module = rtos_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "BeagleBoneZigRTOS.out",
        .root_module = app_mod,
    });

    const c_flags: []const []const u8 = &.{
        "-mcpu=cortex-a8",
        "-mfloat-abi=softfp",
        "-mfpu=neon",
        "-ffunction-sections",
        "-fdata-sections",
        "-Dam3359",
    };

    exe.root_module.addSystemIncludePath(b.path("include/libc_compat"));
    exe.root_module.addIncludePath(b.path("."));
    exe.root_module.addIncludePath(b.path("freertos/include"));
    exe.root_module.addIncludePath(b.path("freertos/portable/GCC/BBB"));
    exe.root_module.addIncludePath(b.path("freertos/portable/GCC/BBB/drivers/include"));
    exe.root_module.addIncludePath(b.path("freertos/portable/GCC/BBB/drivers/include/armv7a"));
    exe.root_module.addIncludePath(b.path("freertos/portable/GCC/BBB/drivers/include/armv7a/am335x"));

    const freertos_c_sources = [_][]const u8{
        "freertos/tasks.c",
        "freertos/queue.c",
        "freertos/list.c",
        "freertos/timers.c",
        "freertos/event_groups.c",
        "freertos/stream_buffer.c",
        "freertos/croutine.c",
        "freertos/portable/MemMang/heap_4.c",
        "freertos/portable/GCC/BBB/port.c",
        "freertos/portable/GCC/BBB/serial.c",
        "freertos/portable/GCC/BBB/abort.c",
        "freertos/portable/GCC/BBB/drivers/intc.c",
    };

    for (freertos_c_sources) |src| {
        exe.root_module.addCSourceFile(.{
            .file = b.path(src),
            .flags = c_flags,
        });
    }

    exe.root_module.addAssemblyFile(b.path("freertos/portable/GCC/BBB/portASM.S"));
    exe.setLinkerScript(b.path("AM335x.lds"));

    const install_art = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_art.step);

    // Generate flat binary (.bin) alongside ELF
    const bin = exe.addObjCopy(.{ .format = .binary });
    const install_bin = b.addInstallFile(bin.getOutput(), "bin/BeagleBoneZigRTOS.bin");
    b.getInstallStep().dependOn(&install_bin.step);

    // Copy .out to Debug/ folder so CCS Theia debugger immediately finds it
    const mkdir_debug = b.addSystemCommand(&.{ "mkdir", "-p", "Debug" });
    const copy_debug = b.addSystemCommand(&.{
        "cp", "-f",
        "zig-out/bin/BeagleBoneZigRTOS.out",
        "Debug/BeagleBoneZigRTOS.out",
    });
    copy_debug.step.dependOn(&install_art.step);
    copy_debug.step.dependOn(&mkdir_debug.step);
    b.default_step.dependOn(&copy_debug.step);

    // ------------------------------------------------------------------------
    // Host Unit Tests (`zig build test --summary all`)
    // ------------------------------------------------------------------------
    const host_target = b.graph.host;

    const host_hal_mod = b.createModule(.{
        .root_source_file = b.path("src/hal/root.zig"),
        .target = host_target,
        .optimize = optimize,
    });

    const host_rtos_mod = b.createModule(.{
        .root_source_file = b.path("src/rtos/root.zig"),
        .target = host_target,
        .optimize = optimize,
    });

    const host_app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = host_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "hal", .module = host_hal_mod },
            .{ .name = "rtos", .module = host_rtos_mod },
        },
    });

    const test_hal = b.addTest(.{ .root_module = host_hal_mod });
    const test_rtos = b.addTest(.{ .root_module = host_rtos_mod });
    const test_main = b.addTest(.{ .root_module = host_app_mod });

    const run_test_hal = b.addRunArtifact(test_hal);
    const run_test_rtos = b.addRunArtifact(test_rtos);
    const run_test_main = b.addRunArtifact(test_main);

    const test_step = b.step("test", "Run unit tests on host platform");
    test_step.dependOn(&run_test_hal.step);
    test_step.dependOn(&run_test_rtos.step);
    test_step.dependOn(&run_test_main.step);

    // ------------------------------------------------------------------------
    // Clean Step (`zig build clean`)
    // ------------------------------------------------------------------------
    const clean_step = b.step("clean", "Remove build output and cache directories");
    const run_clean = b.addSystemCommand(&.{ "rm", "-rf", "zig-out", ".zig-cache", "Debug/*.out", "Debug/*.bin" });
    clean_step.dependOn(&run_clean.step);
}
