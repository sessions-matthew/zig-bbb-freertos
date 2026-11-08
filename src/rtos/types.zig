//! Consolidated FreeRTOS Types, Constants, and Time Conversions
//!
//! Shared zero-overhead abstraction for:
//! - BeagleBone Black (AM335x): ARM Cortex-A8 32-bit (FreeRTOS)
//! - ESP32-C6 (app_core): RISC-V 32-bit (ESP-IDF FreeRTOS SMP)
//! - STM32L031 (sensor_core): ARM Cortex-M0+ (Standard FreeRTOS Static)
//! - Host Platform: Native macOS testing with mock kernel primitives

const std = @import("std");
const builtin = @import("builtin");

// FreeRTOS Primitive C ABI Types (32-bit architecture)
pub const BaseType_t = c_long;
pub const UBaseType_t = c_ulong;
pub const TickType_t = u32;
pub const StackType_t = u32;
pub const TaskHandle_t = ?*anyopaque;
pub const QueueHandle_t = ?*anyopaque;
pub const SemaphoreHandle_t = ?*anyopaque;

// FreeRTOS Boolean & Return Constants
pub const pdTRUE: BaseType_t = 1;
pub const pdFALSE: BaseType_t = 0;
pub const pdPASS: BaseType_t = pdTRUE;
pub const pdFAIL: BaseType_t = pdFALSE;

pub const portMAX_DELAY: TickType_t = 0xFFFFFFFF;

/// Architecture-aware tick rate:
/// - BeagleBone Black (ARM Cortex-A8): 1000 Hz (1 ms per tick)
/// - STM32 (ARM Cortex-M0+): 1000 Hz (1 ms per tick)
/// - ESP32 (RISC-V 32 / ESP-IDF): 100 Hz (10 ms per tick)
/// - Host platform (macOS unit tests): 1000 Hz
pub const TICK_RATE_HZ: u32 = if (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb) 1000 else if (builtin.cpu.arch == .riscv32) 100 else 1000;
pub const MS_PER_TICK: u32 = 1000 / TICK_RATE_HZ;

/// Minimal stack size in words (32-bit words):
/// - Cortex-A8: 2048 words (8192 bytes)
/// - Cortex-M0+: 96 words (384 bytes)
/// - ESP32-C6: 768 words (3072 bytes)
pub const MINIMAL_STACK_SIZE: u32 = if (builtin.cpu.arch == .arm) 2048 else if (builtin.cpu.arch == .thumb) 96 else 768;

/// Static task control block (128 bytes on 32-bit architecture, 8-byte aligned).
/// Cortex-A8 FreeRTOS 11.1 requires 104 bytes (0x68); 128 bytes provides ample headroom.
pub const StaticTask_t = extern struct {
    dummy: [32]u32 align(8) = @splat(0),
};

/// Static queue control block (96 bytes on 32-bit architecture, 8-byte aligned).
/// Cortex-A8 FreeRTOS 11.1 requires 76 bytes (0x4c); 96 bytes provides ample headroom.
pub const StaticQueue_t = extern struct {
    dummy: [24]u32 align(8) = @splat(0),
};

/// FreeRTOS C Task Function Signature
pub const TaskFunction_t = *const fn (pvParameters: ?*anyopaque) callconv(.c) void;

// Scheduler States
pub const taskSCHEDULER_NOT_STARTED: BaseType_t = 0;
pub const taskSCHEDULER_RUNNING: BaseType_t = 1;
pub const taskSCHEDULER_SUSPENDED: BaseType_t = 2;

// Queue Type Identifiers
pub const queueQUEUE_TYPE_BASE: u8 = 0;
pub const queueQUEUE_TYPE_MUTEX: u8 = 1;

// Queue Send Position Constants
pub const queueSEND_TO_BACK: BaseType_t = 0;
pub const queueSEND_TO_FRONT: BaseType_t = 1;
pub const queueOVERWRITE: BaseType_t = 2;

// Task Notification Actions
pub const eNotifyAction = enum(c_int) {
    eNoAction = 0,
    eSetBits = 1,
    eIncrement = 2,
    eSetValueWithOverwrite = 3,
    eSetValueWithoutOverwrite = 4,
};

/// Convert milliseconds to FreeRTOS ticks (rounded up)
pub inline fn msToTicks(ms: u32) TickType_t {
    if (ms == portMAX_DELAY) return portMAX_DELAY;
    if (TICK_RATE_HZ == 1000) return ms;
    return (ms + MS_PER_TICK - 1) / MS_PER_TICK;
}

/// Convert FreeRTOS ticks to milliseconds
pub inline fn ticksToMs(ticks: TickType_t) u32 {
    if (TICK_RATE_HZ == 1000) return ticks;
    return ticks * MS_PER_TICK;
}

/// Consolidated RTOS Error set
pub const RtosError = error{
    Timeout,
    QueueFull,
    QueueEmpty,
    OutOfMemory,
    TaskCreationFailed,
    MutexAcquisitionFailed,
};

// ============================================================================
// Unit Tests
// ============================================================================

test "tick conversions round trip" {
    if (TICK_RATE_HZ == 1000) {
        try std.testing.expectEqual(@as(TickType_t, 10), msToTicks(10));
        try std.testing.expectEqual(@as(u32, 10), ticksToMs(10));
    } else {
        try std.testing.expectEqual(@as(TickType_t, 1), msToTicks(10));
        try std.testing.expectEqual(@as(u32, 10), ticksToMs(1));
    }
    try std.testing.expectEqual(portMAX_DELAY, msToTicks(portMAX_DELAY));
}
