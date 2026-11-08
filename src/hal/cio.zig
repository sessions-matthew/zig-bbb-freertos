//! BeagleBone Black CIO (C I/O) Semihosting & Circular Buffer Logger
//!
//! Provides:
//! - Semihosting CIO output to Code Composer Studio (Theia) CIO Console via `_write`
//! - In-memory circular log buffer `g_LogBuffer` viewable in CCS Expressions / Variables
//! - Dual forwarding to UART0 hardware for physical serial terminals
//! - C ABI exports for FreeRTOS logging macros (`vMainUARTPrintString`)

const std = @import("std");
const builtin = @import("builtin");
const uart = @import("uart.zig");

// Low-level ARM Semihosting / Newlib Syscalls
extern fn initialise_monitor_handles() callconv(.c) void;
extern fn _write(file: c_int, ptr: [*]const u8, len: usize) callconv(.c) c_int;

fn default_initialise_monitor_handles() callconv(.c) void {}

fn default_write(file: c_int, ptr: [*]const u8, len: usize) callconv(.c) c_int {
    _ = file;
    if (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb) {
        const args: [3]usize = .{ 1, @intFromPtr(ptr), len };
        _ = asm volatile (
            "svc 0x00123456"
            : [ret] "={r0}" (-> usize),
            : [op] "{r0}" (@as(usize, 0x05)),
              [arg] "{r1}" (@intFromPtr(&args)),
        );
    }
    return @intCast(len);
}

pub const LOG_BUFFER_SIZE: usize = 1024;

/// In-memory log buffer viewable in CCS Expressions / Variables window
pub var g_LogBuffer: [LOG_BUFFER_SIZE]u8 = @splat(0);
pub var g_LogIndex: u32 = 0;

var is_initialized: bool = false;

/// Set to true to also mirror CIO output to BeagleBone Black UART0 hardware.
/// Defaults to false to eliminate synchronous UART baud-rate spinlocks (~6.5ms per print).
pub var enable_uart_mirror: bool = false;

/// Initialize ARM Semihosting handles for CCS CIO console
pub fn init() void {
    if (!builtin.is_test and (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb)) {
        initialise_monitor_handles();
    }
    is_initialized = true;
}

/// Write bytes to CCS CIO Console, circular memory buffer, and hardware UART0
pub fn write(bytes: []const u8) void {
    rawWrite(bytes);
}

fn rawWrite(bytes: []const u8) void {
    if (bytes.len == 0) return;

    // 1. Record into circular memory buffer for live CCS Expressions inspection
    for (bytes) |b| {
        g_LogBuffer[g_LogIndex % (LOG_BUFFER_SIZE - 1)] = b;
        g_LogIndex +%= 1;
        g_LogBuffer[g_LogIndex % (LOG_BUFFER_SIZE - 1)] = 0;
    }

    // 2. Transmit over ARM Semihosting / CIO (file descriptor 1 = stdout)
    if (!builtin.is_test and (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb)) {
        _ = _write(1, bytes.ptr, bytes.len);
    }

    // 3. Mirror to BeagleBone Black UART0 hardware (only when explicitly enabled)
    if (enable_uart_mirror) {
        uart.Uart0.write(bytes);
    }
}

/// Convenience method to log a string slice
pub fn writeString(s: []const u8) void {
    rawWrite(s);
}

/// Write an unsigned 32-bit integer in decimal (zero heap allocation, alignment-safe)
pub fn writeU32(val: u32) void {
    if (val == 0) {
        rawWrite("0");
        return;
    }
    var buf: [10]u8 = undefined;
    var v = val;
    var i: usize = 0;
    while (v > 0) : (i += 1) {
        buf[i] = @intCast((v % 10) + '0');
        v /= 10;
    }
    var j: usize = 0;
    while (j < i / 2) : (j += 1) {
        const tmp = buf[j];
        buf[j] = buf[i - 1 - j];
        buf[i - 1 - j] = tmp;
    }
    rawWrite(buf[0..i]);
}

/// Write an unsigned 32-bit integer in hexadecimal (zero heap allocation, alignment-safe)
pub fn writeHex(val: u32) void {
    const hex_chars = "0123456789ABCDEF";
    var buf: [8]u8 = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u5 = @intCast((7 - i) * 4);
        const nibble: usize = (val >> shift) & 0xF;
        buf[i] = hex_chars[nibble];
    }
    rawWrite(&buf);
}

/// VTable for Zig 0.17 std.Io.Writer interface
const cio_writer_vtable: std.Io.Writer.VTable = .{
    .drain = cioDrain,
};

/// Streaming drain implementation for Zig 0.17 std.Io.Writer.
/// Flushes any buffered bytes and streams unbuffered chunks directly to semihosting and UART.
fn cioDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    // 1. Flush any data buffered by the writer interface first
    if (w.end > 0) {
        rawWrite(w.buffer[0..w.end]);
        w.end = 0;
    }

    if (data.len == 0) return 0;

    // 2. Stream through slices directly
    const slice = data[0 .. data.len - 1];
    for (slice) |chunk| {
        rawWrite(chunk);
    }

    // 3. Handle splatted tail if any
    const pattern = data[slice.len];
    var i: usize = 0;
    while (i < splat) : (i += 1) {
        rawWrite(pattern);
    }

    var written: usize = pattern.len * splat;
    for (slice) |bytes| written += bytes.len;
    return written;
}

/// Create a streaming `std.Io.Writer` backed by an external buffer slice.
/// Enables passing a streaming CIO writer into arbitrary formatting pipelines.
pub fn customWriter(buffer: []u8) std.Io.Writer {
    return .{
        .vtable = &cio_writer_vtable,
        .buffer = buffer,
    };
}

/// Formatted log output supporting arbitrarily long print statements.
/// Batches output in a 128-byte aligned stack buffer so an entire log line
/// triggers only ONE semihosting SVC trap, matching C printf performance.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [128]u8 align(4) = undefined;
    var w: std.Io.Writer = .{
        .vtable = &cio_writer_vtable,
        .buffer = &buf,
    };
    w.print(fmt, args) catch {};
    w.flush() catch {};
}

/// C ABI export for FreeRTOS logging hooks
pub export fn vMainUARTPrintString(pcString: [*:0]const u8) callconv(.c) void {
    write(std.mem.span(pcString));
}

comptime {
    if (!builtin.is_test) {
        // Weak exports ensure that:
        // 1. Standalone `zig build` resolves symbols without requiring external C libraries.
        // 2. CCS / GCC builds with -specs="rdimon.specs" allow newlib's librdimon.a to provide
        //    the canonical strong symbols without "multiple definition" linker collisions.
        @export(&default_initialise_monitor_handles, .{
            .name = "initialise_monitor_handles",
            .linkage = .weak,
        });
        @export(&default_write, .{
            .name = "_write",
            .linkage = .weak,
        });
        @export(&g_LogBuffer, .{ .name = "g_LogBuffer" });
        @export(&g_LogIndex, .{ .name = "g_LogIndex" });
    }
}

test "LineWriter arbitrarily long formatted print" {
    g_LogIndex = 0;
    // Format an arbitrarily long message exceeding typical small buffers
    print("Test {d}: {s} -> value 0x{X}, count={d}, status={s}\r\n", .{
        1,
        "A very long diagnostic message used to verify that our streaming LineWriter can seamlessly handle print statements that span several hundreds of bytes without buffer truncation, without stack bloat, and without triggering any unaligned memory access exceptions on ARM Cortex-A8 targets",
        0xDEADBEEF,
        999999,
        "OK",
    });

    try std.testing.expect(g_LogIndex > 250);
}
