//! BeagleBone Black (AM335x) UART0 Driver
//!
//! Controls the primary console UART connected to BeagleBone Black header J1.
//! Standard Configuration: 115200 Baud, 8 Data Bits, 1 Stop Bit, No Parity (8N1).
//! Input Clock: 48 MHz (from PRCM).

const std = @import("std");
const builtin = @import("builtin");
const clock = @import("clock.zig");

pub const UART0_BASE: usize = 0x44E09000;
pub const UART4_BASE: usize = 0x481A6000;

// Register offsets from UART base
pub const RHR: usize = 0x00; // Receive Holding Register (read)
pub const THR: usize = 0x00; // Transmit Holding Register (write)
pub const DLL: usize = 0x00; // Divisor Latch LSB (when LCR[7] == 1)
pub const IER: usize = 0x04; // Interrupt Enable Register
pub const DLH: usize = 0x04; // Divisor Latch MSB (when LCR[7] == 1)
pub const IIR: usize = 0x08; // Interrupt Identification Register
pub const FCR: usize = 0x08; // FIFO Control Register
pub const LCR: usize = 0x0C; // Line Control Register
pub const MCR: usize = 0x10; // Modem Control Register
pub const LSR: usize = 0x14; // Line Status Register
pub const MDR1: usize = 0x20; // Mode Definition Register 1

// Bit definitions
pub const LSR_DR: u32 = 1 << 0; // Data Ready
pub const LSR_THRE: u32 = 1 << 5; // Transmitter Holding Register Empty
pub const LSR_TEMT: u32 = 1 << 6; // Transmitter Empty

pub const LCR_8N1: u32 = 0x03; // 8 bits, 1 stop bit, no parity
pub const LCR_DLAB: u32 = 0x80; // Divisor Latch Access Bit

pub const FCR_FIFO_EN: u32 = 0x01;
pub const FCR_RXSR: u32 = 0x02; // RX FIFO soft reset
pub const FCR_TXSR: u32 = 0x04; // TX FIFO soft reset

pub const MDR1_16X: u32 = 0x00; // 16x oversampling (standard UART mode)

const is_embedded = !builtin.is_test and (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb);

// Host test mock buffer
pub var mock_tx_buffer: [512]u8 = undefined;
pub var mock_tx_len: usize = 0;

inline fn writeReg(base: usize, offset: usize, val: u32) void {
    if (is_embedded) {
        const ptr: *volatile u32 = @ptrFromInt(base + offset);
        ptr.* = val;
    }
}

inline fn readReg(base: usize, offset: usize) u32 {
    if (is_embedded) {
        const ptr: *volatile u32 = @ptrFromInt(base + offset);
        return ptr.*;
    }
    return 0;
}

pub const Uart = struct {
    base: usize = UART0_BASE,

    pub fn init(self: Uart, baud: u32) void {
        if (!is_embedded) return;

        // 1. Enable module clock in PRCM
        if (self.base == UART0_BASE) {
            clock.enableUart0();
        }

        // 2. Disable interrupts
        writeReg(self.base, IER, 0x00);

        // 3. Calculate clock divisor (48 MHz clock with 16x oversampling)
        // divisor = 48,000,000 / (16 * baud)
        // For 115200: 26 (0x001A)
        const divisor: u16 = @intCast(calcDivisor(baud));

        // 4. Enable Divisor Latch Access (DLAB = 1)
        writeReg(self.base, LCR, LCR_DLAB | LCR_8N1);

        // 5. Write divisor low and high bytes
        writeReg(self.base, DLL, divisor & 0xFF);
        writeReg(self.base, DLH, (divisor >> 8) & 0xFF);

        // 6. Clear DLAB and configure 8N1
        writeReg(self.base, LCR, LCR_8N1);

        // 7. Enable DTR & RTS
        writeReg(self.base, MCR, 0x03);

        // 8. Enable & reset FIFOs
        writeReg(self.base, FCR, FCR_FIFO_EN | FCR_RXSR | FCR_TXSR);

        // 9. Configure 16x mode
        writeReg(self.base, MDR1, MDR1_16X);
    }

    pub fn calcDivisor(baud: u32) u32 {
        if (baud == 115200) return 26;
        if (baud == 38400) return 78;
        if (baud == 9600) return 312;
        return 48_000_000 / (16 * baud);
    }

    pub fn putc(self: Uart, c: u8) void {
        if (builtin.is_test) {
            if (mock_tx_len < mock_tx_buffer.len) {
                mock_tx_buffer[mock_tx_len] = c;
                mock_tx_len += 1;
            }
            return;
        }

        if (is_embedded) {
            // Wait for Transmitter Holding Register Empty (THRE)
            while ((readReg(self.base, LSR) & LSR_THRE) == 0) {}
            writeReg(self.base, THR, c);
        }
    }

    pub fn write(self: Uart, bytes: []const u8) void {
        for (bytes) |c| {
            if (c == '\n') self.putc('\r');
            self.putc(c);
        }
    }

    pub fn writeString(self: Uart, str: []const u8) void {
        self.write(str);
    }

    pub fn writeU32(self: Uart, val: u32) void {
        var buf: [10]u8 = undefined;
        var v = val;
        var idx: usize = 0;
        if (v == 0) {
            self.putc('0');
            return;
        }
        while (v > 0) : (idx += 1) {
            buf[idx] = @intCast('0' + (v % 10));
            v /= 10;
        }
        while (idx > 0) {
            idx -= 1;
            self.putc(buf[idx]);
        }
    }

    pub fn writeHex32(self: Uart, val: u32) void {
        self.write("0x");
        const hex = "0123456789ABCDEF";
        var i: usize = 8;
        while (i > 0) {
            i -= 1;
            const shift: u5 = @intCast(i * 4);
            const nibble: usize = (val >> shift) & 0xF;
            self.putc(hex[nibble]);
        }
    }

    pub fn hasChar(self: Uart) bool {
        if (!is_embedded) return false;
        return (readReg(self.base, LSR) & LSR_DR) != 0;
    }

    pub fn getc(self: Uart) ?u8 {
        if (!self.hasChar()) return null;
        return @intCast(readReg(self.base, RHR) & 0xFF);
    }
};

pub const Uart0 = Uart{ .base = UART0_BASE };

test "uart divisor calculation" {
    try std.testing.expectEqual(@as(u32, 26), Uart.calcDivisor(115200));
    try std.testing.expectEqual(@as(u32, 78), Uart.calcDivisor(38400));
    try std.testing.expectEqual(@as(u32, 312), Uart.calcDivisor(9600));
}

test "uart mock write output" {
    mock_tx_len = 0;
    Uart0.write("Hello BBB!\n");
    try std.testing.expectEqualStrings("Hello BBB!\r\n", mock_tx_buffer[0..mock_tx_len]);
}
