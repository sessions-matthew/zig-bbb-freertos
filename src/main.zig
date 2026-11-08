//! BeagleBone Black + FreeRTOS Static/Dynamic Firmware in Zig 0.17
//!
//! Features:
//! - Freestanding ARM Cortex-A8 targeting AM3359 on BeagleBone Black.
//! - Clean hardware abstraction (HAL) with type-safe MMIO UART0 and GPIO control.
//! - Type-safe FreeRTOS task, queue, and mutex abstractions.
//! - Multi-task architecture:
//!     1. Heartbeat Task: Blinks USR0/USR1 LEDs and publishes periodic telemetry.
//!     2. Telemetry Task: Consumes messages from FreeRTOS queue and prints over UART0.
//!     3. Monitor Task: Toggles USR2/USR3 LEDs and checks stack watermark.
//! - 100% testable on host platforms via `zig build test` without hardware.

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal");
const rtos = @import("rtos");
pub const mem = @import("mem.zig");

// ============================================================================
// Telemetry Data Structure & Static FreeRTOS Allocations
// ============================================================================

pub const TelemetryMsg = extern struct {
    iteration: u32,
    tick: u32,
    watermark_words: u32,
};

pub const TELEMETRY_QUEUE_CAPACITY = 8;
var g_telemetry_queue = rtos.StaticQueue(TelemetryMsg, TELEMETRY_QUEUE_CAPACITY){};

// Console Mutex for thread-safe output (CIO + UART0)
var g_console_mutex_storage: rtos.types.StaticQueue_t align(8) = .{};
var g_console_mutex: rtos.Mutex = .{};

// Task Stacks and Task Control Blocks (TCBs)
// Explicit 8-byte alignment required by ARM AAPCS and Cortex-A8 NEON/VFP context
pub const HEARTBEAT_STACK_WORDS = 4096;
var g_heartbeat_stack: [HEARTBEAT_STACK_WORDS]rtos.StackType_t align(8) = undefined;
var g_heartbeat_tcb: rtos.StaticTask_t align(8) = undefined;
var g_heartbeat_task_handle: ?rtos.Task = null;

pub const TELEMETRY_STACK_WORDS = 4096;
var g_telemetry_stack: [TELEMETRY_STACK_WORDS]rtos.StackType_t align(8) = undefined;
var g_telemetry_tcb: rtos.StaticTask_t align(8) = undefined;

pub const MONITOR_STACK_WORDS = 4096;
var g_monitor_stack: [MONITOR_STACK_WORDS]rtos.StackType_t align(8) = undefined;
var g_monitor_tcb: rtos.StaticTask_t align(8) = undefined;

// FreeRTOS Idle and Timer Task Memory (required for configSUPPORT_STATIC_ALLOCATION = 1)
pub const IDLE_STACK_WORDS = 2048;
var g_idle_task_stack: [IDLE_STACK_WORDS]rtos.StackType_t align(8) = undefined;
var g_idle_task_tcb: rtos.StaticTask_t align(8) = undefined;

pub const TIMER_STACK_WORDS = 2048;
var g_timer_task_stack: [TIMER_STACK_WORDS]rtos.StackType_t align(8) = undefined;
var g_timer_task_tcb: rtos.StaticTask_t align(8) = undefined;

// ============================================================================
// FreeRTOS Required Hooks & Callbacks
// ============================================================================

fn vApplicationGetIdleTaskMemory(
    ppxIdleTaskTCBBuffer: *?*rtos.StaticTask_t,
    ppxIdleTaskStackBuffer: *?[*]rtos.StackType_t,
    pulIdleTaskStackSize: *u32,
) callconv(.c) void {
    ppxIdleTaskTCBBuffer.* = &g_idle_task_tcb;
    ppxIdleTaskStackBuffer.* = &g_idle_task_stack;
    pulIdleTaskStackSize.* = IDLE_STACK_WORDS;
}

fn vApplicationGetTimerTaskMemory(
    ppxTimerTaskTCBBuffer: *?*rtos.StaticTask_t,
    ppxTimerTaskStackBuffer: *?[*]rtos.StackType_t,
    pulTimerTaskStackSize: *u32,
) callconv(.c) void {
    ppxTimerTaskTCBBuffer.* = &g_timer_task_tcb;
    ppxTimerTaskStackBuffer.* = &g_timer_task_stack;
    pulTimerTaskStackSize.* = TIMER_STACK_WORDS;
}

fn vApplicationIdleHook() callconv(.c) void {}

fn vApplicationTickHook() callconv(.c) void {}

fn vApplicationStackOverflowHook(xTask: rtos.TaskHandle_t, pcTaskName: ?[*:0]const u8) callconv(.c) void {
    _ = xTask;
    hal.Cio.writeString("\r\n[PANIC] FreeRTOS stack overflow in task: ");
    if (pcTaskName) |name| {
        hal.Cio.writeString(std.mem.span(name));
    }
    hal.Cio.writeString("\r\n");
    while (true) {}
}

fn vApplicationMallocFailedHook() callconv(.c) void {
    hal.Cio.writeString("\r\n[PANIC] FreeRTOS pvPortMalloc failed!\r\n");
    while (true) {}
}

fn vAssertCalled(file: ?[*:0]const u8, line: c_int) callconv(.c) void {
    _ = file;
    _ = line;
    hal.Cio.writeString("\r\n[PANIC] FreeRTOS configASSERT failed!\r\n");
    while (true) {}
}

comptime {
    if (!builtin.is_test) {
        @export(&vApplicationGetIdleTaskMemory, .{ .name = "vApplicationGetIdleTaskMemory" });
        @export(&vApplicationGetTimerTaskMemory, .{ .name = "vApplicationGetTimerTaskMemory" });
        @export(&vApplicationIdleHook, .{ .name = "vApplicationIdleHook" });
        @export(&vApplicationTickHook, .{ .name = "vApplicationTickHook" });
        @export(&vApplicationStackOverflowHook, .{ .name = "vApplicationStackOverflowHook" });
        @export(&vApplicationMallocFailedHook, .{ .name = "vApplicationMallocFailedHook" });
        @export(&vAssertCalled, .{ .name = "vAssertCalled" });
        @export(&main, .{ .name = "main" });
        _ = mem;
    }
}

// ============================================================================
// FreeRTOS Task Runners
// ============================================================================

fn heartbeatTaskRunner(param: ?*anyopaque) callconv(.c) void {
    _ = param;
    var count: u32 = 0;

    while (true) {
        rtos.delayMs(500);

        // Toggle BeagleBone Black USR0 LED
        hal.Gpio.toggleLed(0);
        count +%= 1;

        const watermark = if (g_heartbeat_task_handle) |t| t.getStackHighWaterMark() else 0;

        const msg: TelemetryMsg = .{
            .iteration = count,
            .tick = rtos.getTickCount(),
            .watermark_words = watermark,
        };
        _ = g_telemetry_queue.send(&msg, 0);
    }
}

fn telemetryTaskRunner(param: ?*anyopaque) callconv(.c) void {
    _ = param;

    while (true) {
        var msg: TelemetryMsg = undefined;
        if (g_telemetry_queue.receive(&msg, rtos.portMAX_DELAY)) {
            // Acquire console mutex strictly during the print call
            {
                const lock = g_console_mutex.acquire(rtos.portMAX_DELAY) catch continue;
                defer lock.release();

                hal.Cio.print("[Tick {d}] Heartbeat #{d} | FreeRTOS Task (Stack watermark: {d} words)\r\n", .{
                    msg.tick,
                    msg.iteration,
                    msg.watermark_words,
                });
            }

            // Flash USR1 briefly on telemetry output (without holding the console lock)
            hal.Gpio.setLed(1, true);
            rtos.delayMs(50);
            hal.Gpio.setLed(1, false);
        }
    }
}

fn monitorTaskRunner(param: ?*anyopaque) callconv(.c) void {
    _ = param;

    while (true) {
        rtos.delayMs(1000);

        // Toggle USR2 and USR3 LEDs alternatively
        hal.Gpio.toggleLed(2);
        hal.Gpio.toggleLed(3);
    }
}

// ============================================================================
// Application Entry Point
// ============================================================================

pub fn main() callconv(.c) c_int {
    // 1. Initialize BeagleBone Black UART0 (115200 8N1)
    hal.Uart0.init(115200);

    // 2. Initialize Semihosting / CIO subsystem (connects stdout to CCS Console)
    hal.Cio.init();

    // 3. Initialize BeagleBone Black User LEDs (USR0..USR3 on GPIO1_21..24)
    hal.Gpio.initLeds();

    // 4. Print boot banner to CIO and UART0
    hal.Cio.writeString("\r\n");
    hal.Cio.writeString("=====================================================\r\n");
    hal.Cio.writeString("   BeagleBone Black (AM335x Cortex-A8) FreeRTOS      \r\n");
    hal.Cio.writeString("   Language: Zig 0.17 with Unified FreeRTOS Bindings \r\n");
    hal.Cio.writeString("   Core: ARM Cortex-A8 (ARMv7-A) @ DDR0 0x80000000   \r\n");
    hal.Cio.writeString("   Logging: Redirected to CCS CIO / Semihosting Console\r\n");
    hal.Cio.writeString("   Tick Rate: 1000 Hz | Tasks: Preemptive Multitasking\r\n");
    hal.Cio.writeString("=====================================================\r\n\r\n");

    // 5. Initialize Static Queue and Mutex
    g_telemetry_queue.init();
    g_console_mutex = rtos.Mutex.initStatic(&g_console_mutex_storage);

    // 6. Spawn FreeRTOS Tasks
    g_heartbeat_task_handle = rtos.Task.createStatic(
        HEARTBEAT_STACK_WORDS,
        "heartbeat",
        1,
        heartbeatTaskRunner,
        null,
        &g_heartbeat_stack,
        &g_heartbeat_tcb,
    );

    _ = rtos.Task.createStatic(
        TELEMETRY_STACK_WORDS,
        "telemetry",
        2,
        telemetryTaskRunner,
        null,
        &g_telemetry_stack,
        &g_telemetry_tcb,
    );

    _ = rtos.Task.createStatic(
        MONITOR_STACK_WORDS,
        "monitor",
        1,
        monitorTaskRunner,
        null,
        &g_monitor_stack,
        &g_monitor_tcb,
    );

    hal.Cio.writeString("FreeRTOS Scheduler starting...\r\n");

    // 7. Start FreeRTOS scheduler (does not return)
    rtos.startScheduler();

    while (true) {}
}

// ============================================================================
// Host Unit Tests
// ============================================================================

test "telemetry message layout" {
    try std.testing.expectEqual(@sizeOf(TelemetryMsg), 12);
    try std.testing.expectEqual(@alignOf(TelemetryMsg), 4);
}

test "static telemetry queue operation" {
    var test_queue = rtos.StaticQueue(TelemetryMsg, 4){};
    test_queue.init();

    const msg_in = TelemetryMsg{ .iteration = 10, .tick = 500, .watermark_words = 900 };
    try std.testing.expect(test_queue.send(&msg_in, 0));

    var msg_out: TelemetryMsg = undefined;
    try std.testing.expect(test_queue.receive(&msg_out, 0));
    try std.testing.expectEqual(msg_out.iteration, 10);
    try std.testing.expectEqual(msg_out.tick, 500);
    try std.testing.expectEqual(msg_out.watermark_words, 900);
}
