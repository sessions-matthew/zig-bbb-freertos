//! BeagleBone Black Hardware Abstraction Layer (HAL)

pub const clock = @import("clock.zig");
pub const uart = @import("uart.zig");
pub const gpio = @import("gpio.zig");
pub const delay = @import("delay.zig");
pub const cio = @import("cio.zig");

pub const Uart = uart.Uart;
pub const Uart0 = uart.Uart0;
pub const Gpio = gpio.Gpio;
pub const Cio = cio;

test {
    _ = clock;
    _ = uart;
    _ = gpio;
    _ = delay;
    _ = cio;
}
