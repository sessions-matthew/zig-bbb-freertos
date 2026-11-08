//! FreeRTOS Critical Section Management
//!
//! Provides interrupt disabling and critical nesting across ARM Cortex-A8.

const std = @import("std");
const builtin = @import("builtin");

const is_arm = (builtin.cpu.arch == .thumb or builtin.cpu.arch == .arm);
const is_riscv = (builtin.cpu.arch == .riscv32);
const is_embedded = !builtin.is_test and (is_arm or is_riscv);

extern fn vPortEnterCritical() callconv(.c) void;
extern fn vPortExitCritical() callconv(.c) void;

pub fn enterCritical() void {
    if (is_embedded) {
        vPortEnterCritical();
    }
}

pub fn exitCritical() void {
    if (is_embedded) {
        vPortExitCritical();
    }
}

pub const CriticalGuard = struct {
    pub fn enter() CriticalGuard {
        enterCritical();
        return .{};
    }

    pub fn exit(_: CriticalGuard) void {
        exitCritical();
    }
};

test "critical guard compilation and mock behavior" {
    const guard = CriticalGuard.enter();
    defer guard.exit();
}
