//! BeagleBone Black (AM335x) PRCM (Power, Reset, and Clock Management)
//!
//! Provides clock control for peripherals:
//! - GPIO modules (GPIO0..GPIO3)
//! - UART modules (UART0..UART5)

const std = @import("std");
const builtin = @import("builtin");

// Base addresses for PRCM registers
pub const CM_PER_BASE: usize = 0x44E00000;
pub const CM_WKUP_BASE: usize = 0x44E00400;

// Register offsets within CM_PER
pub const CM_PER_GPIO1_CLKCTRL: usize = CM_PER_BASE + 0xAC;
pub const CM_PER_GPIO2_CLKCTRL: usize = CM_PER_BASE + 0xB0;
pub const CM_PER_GPIO3_CLKCTRL: usize = CM_PER_BASE + 0xB4;

// Register offsets within CM_WKUP
pub const CM_WKUP_GPIO0_CLKCTRL: usize = CM_WKUP_BASE + 0x8;
pub const CM_WKUP_UART0_CLKCTRL: usize = CM_WKUP_BASE + 0xB4;

// Clock control bits
pub const MODULEMODE_ENABLE: u32 = 0x2;
pub const IDLEST_MASK: u32 = 0x3 << 16;
pub const IDLEST_FUNC: u32 = 0x0 << 16;

const is_embedded = !builtin.is_test and (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb);

inline fn writeReg(addr: usize, val: u32) void {
    if (is_embedded) {
        const ptr: *volatile u32 = @ptrFromInt(addr);
        ptr.* = val;
    }
}

inline fn readReg(addr: usize) u32 {
    if (is_embedded) {
        const ptr: *volatile u32 = @ptrFromInt(addr);
        return ptr.*;
    }
    return 0;
}

/// Enable clock for UART0 module
pub fn enableUart0() void {
    writeReg(CM_WKUP_UART0_CLKCTRL, MODULEMODE_ENABLE);
    if (is_embedded) {
        var timeout: u32 = 100_000;
        while ((readReg(CM_WKUP_UART0_CLKCTRL) & 0x3) != MODULEMODE_ENABLE and timeout > 0) : (timeout -= 1) {}
    }
}

/// Enable clock for GPIO module (0, 1, 2, or 3)
pub fn enableGpio(module: u2) void {
    const reg = switch (module) {
        0 => CM_WKUP_GPIO0_CLKCTRL,
        1 => CM_PER_GPIO1_CLKCTRL,
        2 => CM_PER_GPIO2_CLKCTRL,
        3 => CM_PER_GPIO3_CLKCTRL,
    };
    writeReg(reg, MODULEMODE_ENABLE);
    if (is_embedded) {
        var timeout: u32 = 100_000;
        while ((readReg(reg) & 0x3) != MODULEMODE_ENABLE and timeout > 0) : (timeout -= 1) {}
    }
}

test "clock register address calculations" {
    try std.testing.expectEqual(@as(usize, 0x44E000AC), CM_PER_GPIO1_CLKCTRL);
    try std.testing.expectEqual(@as(usize, 0x44E004B4), CM_WKUP_UART0_CLKCTRL);
}
