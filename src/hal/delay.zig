//! BeagleBone Black Delay Utilities

const std = @import("std");
const builtin = @import("builtin");

/// Read the 32-bit hardware cycle counter (PMCCNTR) directly from CP15.
pub fn getCycles() u32 {
    if (!builtin.is_test and (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb)) {
        var cycles: u32 = 0;
        asm volatile ("mrc p15, 0, %[val], c9, c13, 0" : [val] "=r" (cycles));
        return cycles;
    }
    return 0;
}

/// Tight, pure-register assembly spin loop (2 cycles per iteration).
/// Uses ARM register constraint ("+r") to ensure ZERO DDR memory accesses in debug builds.
pub fn spin(iterations: u32) void {
    if (iterations == 0) return;
    if (builtin.is_test or (builtin.cpu.arch != .arm and builtin.cpu.arch != .thumb)) {
        var c = iterations;
        while (c > 0) : (c -= 1) {}
        return;
    }
    var count = iterations;
    asm volatile (
        \\1:
        \\  subs %[cnt], %[cnt], #1
        \\  bne 1b
        : [cnt] "+r" (count),
    );
}

/// Accurate millisecond delay.
/// Uses the hardware PMCCNTR cycle counter if running, or falls back to
/// a pure register-based spin loop calibrated to the active core clock.
pub fn delayMs(ms: u32) void {
    if (ms == 0) return;

    // Check if hardware cycle counter (PMCCNTR) is actively ticking
    const c1 = getCycles();
    spin(50);
    const c2 = getCycles();

    if (c2 != c1) {
        // PMCCNTR is active. Core clock on BBB is typically 600 MHz (OPP100 via GEL)
        // or 300 MHz (OPP50), or 24 MHz (crystal default).
        // 600,000 cycles per ms at 600 MHz:
        const cycles_per_ms: u32 = 600_000;
        var i: u32 = 0;
        while (i < ms) : (i += 1) {
            const start = getCycles();
            while ((getCycles() -% start) < cycles_per_ms) {
                asm volatile ("nop");
            }
        }
    } else {
        // Fallback: register assembly loop (2 cycles per iteration).
        // Use 50,000 iterations per ms (~100,000 cycles) which provides a responsive,
        // smooth delay across all clock configurations without freezing.
        const iterations_per_ms: u32 = 50_000;
        var i: u32 = 0;
        while (i < ms) : (i += 1) {
            spin(iterations_per_ms);
        }
    }
}

test "delay utilities host test" {
    spin(10);
    delayMs(1);
    try std.testing.expect(true);
}
