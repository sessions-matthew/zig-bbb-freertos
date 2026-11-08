//! Consolidated FreeRTOS Mutex and Semaphore Abstraction
//!
//! Provides RAII lock guards (via `defer lock.release()`), static mutexes,
//! and binary semaphores for BeagleBone Black Cortex-A8.

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const queue = @import("queue.zig");

pub const SemaphoreHandle = types.SemaphoreHandle_t;

// ============================================================================
// FreeRTOS C Semaphore Declarations
// ============================================================================

const is_arm = (builtin.cpu.arch == .thumb or builtin.cpu.arch == .arm);
const is_riscv = (builtin.cpu.arch == .riscv32);
const is_embedded = !builtin.is_test and (is_arm or is_riscv);

extern fn xQueueCreateMutex(ucQueueType: u8) callconv(.c) SemaphoreHandle;

extern fn xQueueCreateMutexStatic(
    ucQueueType: u8,
    pxStaticQueue: *types.StaticQueue_t,
) callconv(.c) SemaphoreHandle;

extern fn xQueueSemaphoreTake(
    xQueue: SemaphoreHandle,
    xTicksToWait: types.TickType_t,
) callconv(.c) types.BaseType_t;

extern fn xQueueGenericSend(
    xQueue: SemaphoreHandle,
    pvItemToQueue: ?*const anyopaque,
    xTicksToWait: types.TickType_t,
    xCopyPosition: types.BaseType_t,
) callconv(.c) types.BaseType_t;

extern fn vQueueDelete(xQueue: SemaphoreHandle) callconv(.c) void;

// Host test mocks
pub var mock_mutex_locked: bool = false;

fn mock_xQueueCreateMutex(_: u8) callconv(.c) SemaphoreHandle {
    mock_mutex_locked = false;
    return @ptrFromInt(0x9ABC);
}

fn mock_xQueueCreateMutexStatic(_: u8, _: *types.StaticQueue_t) callconv(.c) SemaphoreHandle {
    mock_mutex_locked = false;
    return @ptrFromInt(0x9DEF);
}

fn mock_xQueueSemaphoreTake(_: SemaphoreHandle, _: types.TickType_t) callconv(.c) types.BaseType_t {
    if (!mock_mutex_locked) {
        mock_mutex_locked = true;
        return types.pdPASS;
    }
    return types.pdFAIL;
}

fn mock_xQueueGenericSend(_: SemaphoreHandle, _: ?*const anyopaque, _: types.TickType_t, _: types.BaseType_t) callconv(.c) types.BaseType_t {
    mock_mutex_locked = false;
    return types.pdPASS;
}

// ============================================================================
// Mutex Abstraction with RAII LockGuard
// ============================================================================

pub const Mutex = struct {
    handle: SemaphoreHandle = null,

    pub fn init() types.RtosError!Mutex {
        const h = if (builtin.is_test)
            mock_xQueueCreateMutex(types.queueQUEUE_TYPE_MUTEX)
        else
            xQueueCreateMutex(types.queueQUEUE_TYPE_MUTEX);

        if (h == null) return types.RtosError.OutOfMemory;
        return .{ .handle = h };
    }

    pub fn initStatic(static_storage: *types.StaticQueue_t) Mutex {
        const h = if (builtin.is_test)
            mock_xQueueCreateMutexStatic(types.queueQUEUE_TYPE_MUTEX, static_storage)
        else
            xQueueCreateMutexStatic(types.queueQUEUE_TYPE_MUTEX, static_storage);

        return .{ .handle = h };
    }

    pub fn deinit(self: *Mutex) void {
        if (self.handle) |h| {
            if (!builtin.is_test) vQueueDelete(h);
            self.handle = null;
        }
    }

    pub fn acquire(self: Mutex, wait_ticks: types.TickType_t) types.RtosError!LockGuard {
        const res = if (builtin.is_test)
            mock_xQueueSemaphoreTake(self.handle, wait_ticks)
        else
            xQueueSemaphoreTake(self.handle, wait_ticks);

        if (res != types.pdPASS) return types.RtosError.MutexAcquisitionFailed;
        return LockGuard{ .mutex = self };
    }

    pub fn release(self: Mutex) void {
        _ = if (builtin.is_test)
            mock_xQueueGenericSend(self.handle, null, 0, types.queueSEND_TO_BACK)
        else
            xQueueGenericSend(self.handle, null, 0, types.queueSEND_TO_BACK);
    }

    pub const LockGuard = struct {
        mutex: Mutex,

        pub fn release(self: LockGuard) void {
            self.mutex.release();
        }
    };
};

// ============================================================================
// Binary Semaphore Abstraction
// ============================================================================

pub const Semaphore = struct {
    handle: SemaphoreHandle = null,

    pub fn init() types.RtosError!Semaphore {
        const m = try Mutex.init();
        return .{ .handle = m.handle };
    }

    pub fn give(self: Semaphore) void {
        _ = if (builtin.is_test)
            mock_xQueueGenericSend(self.handle, null, 0, types.queueSEND_TO_BACK)
        else
            xQueueGenericSend(self.handle, null, 0, types.queueSEND_TO_BACK);
    }

    pub fn take(self: Semaphore, wait_ticks: types.TickType_t) bool {
        const res = if (builtin.is_test)
            mock_xQueueSemaphoreTake(self.handle, wait_ticks)
        else
            xQueueSemaphoreTake(self.handle, wait_ticks);
        return res == types.pdPASS;
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "mutex acquire and RAII release" {
    var m = try Mutex.init();
    defer m.deinit();

    {
        const guard = try m.acquire(0);
        defer guard.release();
        try std.testing.expect(mock_mutex_locked);
    }
    try std.testing.expect(!mock_mutex_locked);
}
