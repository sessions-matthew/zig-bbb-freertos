//! BeagleBone Black (AM335x) GPIO Driver & User LEDs
//!
//! BeagleBone Black User LEDs:
//! - USR0: GPIO1_21
//! - USR1: GPIO1_22
//! - USR2: GPIO1_23
//! - USR3: GPIO1_24
//!
//! Registers:
//! - OE (Output Enable): offset 0x134 (0 = output, 1 = input)
//! - DATAIN: offset 0x138
//! - DATAOUT: offset 0x13C
//! - CLEARDATAOUT: offset 0x190
//! - SETDATAOUT: offset 0x194

const std = @import("std");
const builtin = @import("builtin");
const clock = @import("clock.zig");

pub const GPIO0_BASE: usize = 0x44E07000;
pub const GPIO1_BASE: usize = 0x4804C000;
pub const GPIO2_BASE: usize = 0x480AC000;
pub const GPIO3_BASE: usize = 0x481AE000;

pub const GPIO_OE: usize = 0x134;
pub const GPIO_DATAIN: usize = 0x138;
pub const GPIO_DATAOUT: usize = 0x13C;
pub const GPIO_CLEARDATAOUT: usize = 0x190;
pub const GPIO_SETDATAOUT: usize = 0x194;

// BeagleBone Black User LED pin numbers on GPIO1
pub const USR0_PIN: u5 = 21;
pub const USR1_PIN: u5 = 22;
pub const USR2_PIN: u5 = 23;
pub const USR3_PIN: u5 = 24;

pub const USR_LEDS_MASK: u32 = (1 << USR0_PIN) | (1 << USR1_PIN) | (1 << USR2_PIN) | (1 << USR3_PIN);

const is_embedded = !builtin.is_test and (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb);

// Host mock state
pub var mock_gpio1_oe: u32 = 0xFFFFFFFF;
pub var mock_gpio1_out: u32 = 0x00000000;

inline fn writeReg(base: usize, offset: usize, val: u32) void {
    if (builtin.is_test) {
        if (base == GPIO1_BASE) {
            if (offset == GPIO_OE) mock_gpio1_oe = val;
            if (offset == GPIO_SETDATAOUT) mock_gpio1_out |= val;
            if (offset == GPIO_CLEARDATAOUT) mock_gpio1_out &= ~val;
            if (offset == GPIO_DATAOUT) mock_gpio1_out = val;
        }
        return;
    }
    if (is_embedded) {
        const ptr: *volatile u32 = @ptrFromInt(base + offset);
        ptr.* = val;
    }
}

inline fn readReg(base: usize, offset: usize) u32 {
    if (builtin.is_test) {
        if (base == GPIO1_BASE) {
            if (offset == GPIO_OE) return mock_gpio1_oe;
            if (offset == GPIO_DATAOUT) return mock_gpio1_out;
        }
        return 0;
    }
    if (is_embedded) {
        const ptr: *volatile u32 = @ptrFromInt(base + offset);
        return ptr.*;
    }
    return 0;
}

pub const Gpio = struct {
    base: usize = GPIO1_BASE,

    pub fn initLeds() void {
        // 1. Enable GPIO1 clock in PRCM
        clock.enableGpio(1);

        // 2. Configure USR0..USR3 as outputs (clear bits in OE register)
        var oe = readReg(GPIO1_BASE, GPIO_OE);
        oe &= ~USR_LEDS_MASK;
        writeReg(GPIO1_BASE, GPIO_OE, oe);

        // 3. Turn off all LEDs initially
        writeReg(GPIO1_BASE, GPIO_CLEARDATAOUT, USR_LEDS_MASK);
    }

    pub fn setLed(index: u2, on: bool) void {
        const pin: u5 = switch (index) {
            0 => USR0_PIN,
            1 => USR1_PIN,
            2 => USR2_PIN,
            3 => USR3_PIN,
        };
        const mask: u32 = @as(u32, 1) << pin;
        if (on) {
            writeReg(GPIO1_BASE, GPIO_SETDATAOUT, mask);
        } else {
            writeReg(GPIO1_BASE, GPIO_CLEARDATAOUT, mask);
        }
    }

    pub fn toggleLed(index: u2) void {
        const pin: u5 = switch (index) {
            0 => USR0_PIN,
            1 => USR1_PIN,
            2 => USR2_PIN,
            3 => USR3_PIN,
        };
        const mask: u32 = @as(u32, 1) << pin;
        const current = readReg(GPIO1_BASE, GPIO_DATAOUT);
        if ((current & mask) != 0) {
            writeReg(GPIO1_BASE, GPIO_CLEARDATAOUT, mask);
        } else {
            writeReg(GPIO1_BASE, GPIO_SETDATAOUT, mask);
        }
    }

    pub fn setLedsPattern(pattern: u4) void {
        var set_mask: u32 = 0;
        var clr_mask: u32 = 0;

        inline for (0..4) |i| {
            const pin = USR0_PIN + i;
            const bit = (@as(u32, pattern) >> @intCast(i)) & 1;
            if (bit == 1) {
                set_mask |= (@as(u32, 1) << @intCast(pin));
            } else {
                clr_mask |= (@as(u32, 1) << @intCast(pin));
            }
        }

        if (set_mask != 0) writeReg(GPIO1_BASE, GPIO_SETDATAOUT, set_mask);
        if (clr_mask != 0) writeReg(GPIO1_BASE, GPIO_CLEARDATAOUT, clr_mask);
    }
};

test "leds initialization and pattern" {
    Gpio.initLeds();
    try std.testing.expectEqual(@as(u32, ~USR_LEDS_MASK), mock_gpio1_oe);

    Gpio.setLed(0, true);
    try std.testing.expect((mock_gpio1_out & (1 << USR0_PIN)) != 0);

    Gpio.setLed(0, false);
    try std.testing.expect((mock_gpio1_out & (1 << USR0_PIN)) == 0);

    Gpio.setLedsPattern(0b1010);
    try std.testing.expect((mock_gpio1_out & (1 << USR1_PIN)) != 0);
    try std.testing.expect((mock_gpio1_out & (1 << USR3_PIN)) != 0);
    try std.testing.expect((mock_gpio1_out & (1 << USR0_PIN)) == 0);
    try std.testing.expect((mock_gpio1_out & (1 << USR2_PIN)) == 0);
}
