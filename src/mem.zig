//! Alignment-safe ARM EABI memory primitives (memcpy, memmove, memset)
//!
//! On ARMv7-A Cortex-A8 without MMU page table attributes configured for Normal memory,
//! DDR memory (0x80000000 - 0x8FFFFFFF) is treated as Strongly-Ordered memory.
//! The ARM architecture strictly forbids unaligned halfword/word accesses on Strongly-Ordered
//! memory (triggering immediate Alignment Fault Data Aborts, even with SCTLR.A = 0).
//!
//! GNU Newlib's libc.a contains assembly routines that blindly execute `ldrhcs` and `strhcs`
//! on odd addresses. These replacement routines guarantee complete alignment safety across
//! all C and Zig runtime operations.

const std = @import("std");
const builtin = @import("builtin");

pub fn memcpy(dest: ?[*]u8, src: ?[*]const u8, n: usize) callconv(.c) ?[*]u8 {
    if (dest == null or src == null or n == 0) return dest;
    const d = dest.?;
    const s = src.?;

    // If both pointers share the same 4-byte alignment, copy initial bytes then 32-bit words
    if (((@intFromPtr(d) ^ @intFromPtr(s)) & 3) == 0) {
        var d_ptr = d;
        var s_ptr = s;
        var count = n;
        while ((@intFromPtr(d_ptr) & 3) != 0 and count > 0) {
            d_ptr[0] = s_ptr[0];
            d_ptr += 1;
            s_ptr += 1;
            count -= 1;
        }
        var d32: [*]u32 = @ptrCast(@alignCast(d_ptr));
        var s32: [*]const u32 = @ptrCast(@alignCast(s_ptr));
        while (count >= 4) {
            d32[0] = s32[0];
            d32 += 1;
            s32 += 1;
            count -= 4;
        }
        d_ptr = @ptrCast(d32);
        s_ptr = @ptrCast(s32);
        while (count > 0) {
            d_ptr[0] = s_ptr[0];
            d_ptr += 1;
            s_ptr += 1;
            count -= 1;
        }
        return dest;
    }

    // Pointers have differing alignment: copy byte-by-byte (ldrb/strb)
    // to strictly prevent Cortex-A8 hardware alignment faults.
    var i: usize = 0;
    while (i < n) : (i += 1) {
        d[i] = s[i];
    }
    return dest;
}

pub fn __aeabi_memcpy(dest: ?[*]u8, src: ?[*]const u8, n: usize) callconv(.c) void {
    _ = memcpy(dest, src, n);
}

pub fn __aeabi_memcpy4(dest: ?[*]u8, src: ?[*]const u8, n: usize) callconv(.c) void {
    _ = memcpy(dest, src, n);
}

pub fn __aeabi_memcpy8(dest: ?[*]u8, src: ?[*]const u8, n: usize) callconv(.c) void {
    _ = memcpy(dest, src, n);
}

pub fn memmove(dest: ?[*]u8, src: ?[*]const u8, n: usize) callconv(.c) ?[*]u8 {
    if (dest == null or src == null or n == 0) return dest;
    const d = dest.?;
    const s = src.?;
    if (@intFromPtr(d) <= @intFromPtr(s)) {
        return memcpy(dest, src, n);
    }
    // Overlapping backwards copy: byte-by-byte for complete alignment safety
    var i = n;
    while (i > 0) {
        i -= 1;
        d[i] = s[i];
    }
    return dest;
}

pub fn __aeabi_memmove(dest: ?[*]u8, src: ?[*]const u8, n: usize) callconv(.c) void {
    _ = memmove(dest, src, n);
}

pub fn __aeabi_memmove4(dest: ?[*]u8, src: ?[*]const u8, n: usize) callconv(.c) void {
    _ = memmove(dest, src, n);
}

pub fn __aeabi_memmove8(dest: ?[*]u8, src: ?[*]const u8, n: usize) callconv(.c) void {
    _ = memmove(dest, src, n);
}

pub fn memset(dest: ?[*]u8, c: c_int, n: usize) callconv(.c) ?[*]u8 {
    if (dest == null or n == 0) return dest;
    const d = dest.?;
    const byte: u8 = @truncate(@as(u32, @bitCast(c)));
    var d_ptr = d;
    var count = n;

    // Align to 4 bytes
    while ((@intFromPtr(d_ptr) & 3) != 0 and count > 0) {
        d_ptr[0] = byte;
        d_ptr += 1;
        count -= 1;
    }

    // Fill 32-bit words
    if (count >= 4) {
        const word: u32 = (@as(u32, byte) * 0x01010101);
        var d32: [*]u32 = @ptrCast(@alignCast(d_ptr));
        while (count >= 4) {
            d32[0] = word;
            d32 += 1;
            count -= 4;
        }
        d_ptr = @ptrCast(d32);
    }

    // Fill tail bytes
    while (count > 0) {
        d_ptr[0] = byte;
        d_ptr += 1;
        count -= 1;
    }

    return dest;
}

pub fn __aeabi_memset(dest: ?[*]u8, n: usize, c: c_int) callconv(.c) void {
    // Note: RTABI __aeabi_memset argument order is (dest, n, c)
    _ = memset(dest, c, n);
}

pub fn __aeabi_memset4(dest: ?[*]u8, n: usize, c: c_int) callconv(.c) void {
    _ = memset(dest, c, n);
}

pub fn __aeabi_memset8(dest: ?[*]u8, n: usize, c: c_int) callconv(.c) void {
    _ = memset(dest, c, n);
}

pub fn __aeabi_memclr(dest: ?[*]u8, n: usize) callconv(.c) void {
    _ = memset(dest, 0, n);
}

pub fn __aeabi_memclr4(dest: ?[*]u8, n: usize) callconv(.c) void {
    _ = memset(dest, 0, n);
}

pub fn __aeabi_memclr8(dest: ?[*]u8, n: usize) callconv(.c) void {
    _ = memset(dest, 0, n);
}

comptime {
    if (!builtin.is_test) {
        @export(&memcpy, .{ .name = "memcpy" });
        @export(&__aeabi_memcpy, .{ .name = "__aeabi_memcpy" });
        @export(&__aeabi_memcpy4, .{ .name = "__aeabi_memcpy4" });
        @export(&__aeabi_memcpy8, .{ .name = "__aeabi_memcpy8" });
        @export(&memmove, .{ .name = "memmove" });
        @export(&__aeabi_memmove, .{ .name = "__aeabi_memmove" });
        @export(&__aeabi_memmove4, .{ .name = "__aeabi_memmove4" });
        @export(&__aeabi_memmove8, .{ .name = "__aeabi_memmove8" });
        @export(&memset, .{ .name = "memset" });
        @export(&__aeabi_memset, .{ .name = "__aeabi_memset" });
        @export(&__aeabi_memset4, .{ .name = "__aeabi_memset4" });
        @export(&__aeabi_memset8, .{ .name = "__aeabi_memset8" });
        @export(&__aeabi_memclr, .{ .name = "__aeabi_memclr" });
        @export(&__aeabi_memclr4, .{ .name = "__aeabi_memclr4" });
        @export(&__aeabi_memclr8, .{ .name = "__aeabi_memclr8" });
    }
}

test "unaligned memcpy and memmove correctness" {
    var src: [64]u8 = undefined;
    var dest: [64]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    @memset(&dest, 0);

    // Test mismatched odd offsets (e.g. src at offset 1, dest at offset 3)
    _ = memcpy(dest[3..].ptr, src[1..].ptr, 25);
    try std.testing.expectEqualSlices(u8, src[1..26], dest[3..28]);

    // Test overlapping memmove
    _ = memmove(src[5..].ptr, src[1..].ptr, 10);
    try std.testing.expectEqualSlices(u8, dest[3..13], src[5..15]);
}
