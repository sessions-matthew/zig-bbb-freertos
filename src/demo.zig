//! BeagleBone Black FreeRTOS Demo in Zig 0.17
//!
//! Features:
//! - Blinker Task: delays 2000 ms, toggles USR1 LED (GPIO1_22).
//! - Timer Task: waits on binary semaphore, toggles USR0 LED (GPIO1_21) on 500ms DMTimer7 overflow.
//! - Button Task: waits on binary semaphore, logs press count over CIO, toggles DMTimer7 on/off.
//! - Hardware Interrupts: DMTimer7 overflow ISR & GPIO1_2 button ISR with `xSemaphoreGiveFromISR`.
//! - Watchdog: kicked in FreeRTOS idle hook.

const std = @import("std");
const builtin = @import("builtin");
const hal = @import("hal");
const rtos = @import("rtos");
pub const mem = @import("mem.zig");

// ============================================================================
// Hardware Register Base Addresses & Offsets
// ============================================================================

const CM_PER_BASE: usize = 0x44E00000;
const CM_PER_GPIO1_CLKCTRL: usize = CM_PER_BASE + 0xAC;
const CM_PER_TIMER7_CLKCTRL: usize = CM_PER_BASE + 0x7C;

const CONTROL_MODULE_BASE: usize = 0x44E10000;
const CONF_GPMC_AD2: usize = CONTROL_MODULE_BASE + 0x808; // P9_23 button (GPIO1_2)

const GPIO1_BASE: usize = 0x4804C000;
const GPIO_CTRL: usize = GPIO1_BASE + 0x130;
const GPIO_OE: usize = GPIO1_BASE + 0x134;
const GPIO_IRQSTATUS_0: usize = GPIO1_BASE + 0x2C;
const GPIO_IRQSTATUS_SET_0: usize = GPIO1_BASE + 0x34;
const GPIO_LEVELDETECT0: usize = GPIO1_BASE + 0x140;
const GPIO_LEVELDETECT1: usize = GPIO1_BASE + 0x144;
const GPIO_RISINGDETECT: usize = GPIO1_BASE + 0x148;
const GPIO_FALLINGDETECT: usize = GPIO1_BASE + 0x14C;
const GPIO_CLEARDATAOUT: usize = GPIO1_BASE + 0x190;
const GPIO_SETDATAOUT: usize = GPIO1_BASE + 0x194;

const DMTIMER7_BASE: usize = 0x4804A000;
const DMTIMER7_TIOCP_CFG: usize = DMTIMER7_BASE + 0x10;
const DMTIMER7_IRQSTATUS: usize = DMTIMER7_BASE + 0x28;
const DMTIMER7_IRQENABLE_SET: usize = DMTIMER7_BASE + 0x2C;
const DMTIMER7_TCLR: usize = DMTIMER7_BASE + 0x38;
const DMTIMER7_TCRR: usize = DMTIMER7_BASE + 0x3C;
const DMTIMER7_TLDR: usize = DMTIMER7_BASE + 0x40;

const WDT1_BASE: usize = 0x44E35000;
const WDT1_WTGR: usize = WDT1_BASE + 0x30;

// 500ms reload value based on 24 MHz clock
const TIMER_RELOAD_VALUE: u32 = 0xFF48F300;

// Interrupt numbers for AM335x AINTC
const SYS_INT_TINT7: c_uint = 95;
const SYS_INT_GPIOINT1A: c_uint = 98;
const AINTC_HOSTINT_ROUTE_IRQ: c_uint = 0;

inline fn writeReg(addr: usize, val: u32) void {
    if (!builtin.is_test and (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb)) {
        const ptr: *volatile u32 = @ptrFromInt(addr);
        ptr.* = val;
    }
}

inline fn readReg(addr: usize) u32 {
    if (!builtin.is_test and (builtin.cpu.arch == .arm or builtin.cpu.arch == .thumb)) {
        const ptr: *volatile u32 = @ptrFromInt(addr);
        return ptr.*;
    }
    return 0;
}

// ============================================================================
// INTC and FreeRTOS External Function Declarations
// ============================================================================

extern fn IntRegister(intrNum: c_uint, fnHandler: *const fn () callconv(.c) void) callconv(.c) void;
extern fn IntPrioritySet(intrNum: c_uint, priority: c_uint, hostIntRoute: c_uint) callconv(.c) void;
extern fn IntSystemEnable(intrNum: c_uint) callconv(.c) void;

extern fn xQueueGenericCreate(uxQueueLength: rtos.UBaseType_t, uxItemSize: rtos.UBaseType_t, ucQueueType: u8) callconv(.c) rtos.QueueHandle_t;
extern fn xQueueGiveFromISR(xQueue: rtos.QueueHandle_t, pxHigherPriorityTaskWoken: *rtos.BaseType_t) callconv(.c) rtos.BaseType_t;
extern fn xQueueSemaphoreTake(xQueue: rtos.QueueHandle_t, xTicksToWait: rtos.TickType_t) callconv(.c) rtos.BaseType_t;
extern var ulPortYieldRequired: u32;

inline fn yieldFromISR(switch_required: rtos.BaseType_t) void {
    if (switch_required != rtos.pdFALSE) {
        ulPortYieldRequired = rtos.pdTRUE;
    }
}

// ============================================================================
// Task Stacks and Static Control Blocks
// ============================================================================

pub const STACK_WORDS = 2048;

var g_blinker_stack: [STACK_WORDS]rtos.StackType_t align(8) = undefined;
var g_blinker_tcb: rtos.StaticTask_t align(8) = undefined;

var g_timer_stack: [STACK_WORDS]rtos.StackType_t align(8) = undefined;
var g_timer_tcb: rtos.StaticTask_t align(8) = undefined;

var g_button_stack: [STACK_WORDS * 2]rtos.StackType_t align(8) = undefined;
var g_button_tcb: rtos.StaticTask_t align(8) = undefined;

// Idle and Timer stacks required for static allocation
pub const IDLE_STACK_WORDS = 1024;
var g_idle_stack: [IDLE_STACK_WORDS]rtos.StackType_t align(8) = undefined;
var g_idle_tcb: rtos.StaticTask_t align(8) = undefined;

var g_timer_svc_stack: [IDLE_STACK_WORDS]rtos.StackType_t align(8) = undefined;
var g_timer_svc_tcb: rtos.StaticTask_t align(8) = undefined;

// Semaphores
var xButtonSemaphore: rtos.QueueHandle_t = null;
var xTimerSemaphore: rtos.QueueHandle_t = null;

var led0Flag: u1 = 0;
var led1Flag: u1 = 0;

// ============================================================================
// FreeRTOS Memory Callbacks & Hooks
// ============================================================================

fn vApplicationGetIdleTaskMemory(
    ppxIdleTaskTCBBuffer: *?*rtos.StaticTask_t,
    ppxIdleTaskStackBuffer: *?[*]rtos.StackType_t,
    pulIdleTaskStackSize: *u32,
) callconv(.c) void {
    ppxIdleTaskTCBBuffer.* = &g_idle_tcb;
    ppxIdleTaskStackBuffer.* = &g_idle_stack;
    pulIdleTaskStackSize.* = IDLE_STACK_WORDS;
}

fn vApplicationGetTimerTaskMemory(
    ppxTimerTaskTCBBuffer: *?*rtos.StaticTask_t,
    ppxTimerTaskStackBuffer: *?[*]rtos.StackType_t,
    pulTimerTaskStackSize: *u32,
) callconv(.c) void {
    ppxTimerTaskTCBBuffer.* = &g_timer_svc_tcb;
    ppxTimerTaskStackBuffer.* = &g_timer_svc_stack;
    pulTimerTaskStackSize.* = IDLE_STACK_WORDS;
}

fn vWatchDogKicker() void {
    writeReg(WDT1_WTGR, readReg(WDT1_WTGR) +% 1);
}

fn vApplicationIdleHook() callconv(.c) void {
    vWatchDogKicker();
}

fn vApplicationTickHook() callconv(.c) void {}

fn vApplicationStackOverflowHook(xTask: rtos.TaskHandle_t, pcTaskName: ?[*:0]const u8) callconv(.c) void {
    _ = xTask;
    _ = pcTaskName;
    while (true) {}
}

fn vApplicationMallocFailedHook() callconv(.c) void {
    while (true) {}
}

comptime {
    if (!builtin.is_test) {
        @export(&vApplicationGetIdleTaskMemory, .{ .name = "vApplicationGetIdleTaskMemory" });
        @export(&vApplicationGetTimerTaskMemory, .{ .name = "vApplicationGetTimerTaskMemory" });
        @export(&vApplicationIdleHook, .{ .name = "vApplicationIdleHook" });
        @export(&vApplicationTickHook, .{ .name = "vApplicationTickHook" });
        @export(&vApplicationStackOverflowHook, .{ .name = "vApplicationStackOverflowHook" });
        @export(&vApplicationMallocFailedHook, .{ .name = "vApplicationMallocFailedHook" });
        @export(&main, .{ .name = "main" });
        _ = mem;
    }
}

// ============================================================================
// Hardware Interrupt Service Routines (ISRs)
// ============================================================================

pub fn vDMTimer7_Handler() callconv(.c) void {
    // Check overflow interrupt flag (bit 1)
    if ((readReg(DMTIMER7_IRQSTATUS) & 0x2) != 0) {
        // Clear overflow interrupt status flag
        writeReg(DMTIMER7_IRQSTATUS, 0x2);

        var higher_prio_woken: rtos.BaseType_t = rtos.pdFALSE;
        if (xTimerSemaphore) |sem| {
            _ = xQueueGiveFromISR(sem, &higher_prio_woken);
        }
        yieldFromISR(higher_prio_woken);
    }
}

pub fn vGPIO1_Button_Handler() callconv(.c) void {
    // Clear GPIO peripheral interrupt flag for pin 2
    writeReg(GPIO_IRQSTATUS_0, (1 << 2));

    var higher_prio_woken: rtos.BaseType_t = rtos.pdFALSE;
    if (xButtonSemaphore) |sem| {
        _ = xQueueGiveFromISR(sem, &higher_prio_woken);
    }
    yieldFromISR(higher_prio_woken);
}

// ============================================================================
// Hardware Initialization
// ============================================================================

fn prvSetupHardware() void {
    // 1. Enable GPIO1 module and functional clock in PRCM
    writeReg(CM_PER_GPIO1_CLKCTRL, readReg(CM_PER_GPIO1_CLKCTRL) | (0x2 | (1 << 18)));
    while ((readReg(CM_PER_GPIO1_CLKCTRL) & 0x3) != 0x2) {}

    // 2. Pinmux for button GPIO1_2 (P9_23): Mode 7 (GPIO), RX active, Pull-up
    writeReg(CONF_GPMC_AD2, 0x37);

    // 3. Enable GPIO1 module (clear DISABLEMODULE bit)
    writeReg(GPIO_CTRL, readReg(GPIO_CTRL) & ~@as(u32, 0x1));

    // 4. Direction: USR0..USR3 (GPIO1_21..24) as outputs (0=Output, 1=Input)
    writeReg(GPIO_OE, readReg(GPIO_OE) & ~(@as(u32, 0xF) << 21));

    // Set GPIO1_2 (Button) as input
    writeReg(GPIO_OE, readReg(GPIO_OE) | (@as(u32, 1) << 2));

    // 5. Turn off all USR LEDs initially
    writeReg(GPIO_CLEARDATAOUT, @as(u32, 0xF) << 21);

    // 6. Configure GPIO1_2 for Falling Edge interrupt
    writeReg(GPIO_RISINGDETECT, readReg(GPIO_RISINGDETECT) & ~(@as(u32, 1) << 2));
    writeReg(GPIO_FALLINGDETECT, readReg(GPIO_FALLINGDETECT) | (@as(u32, 1) << 2));
    writeReg(GPIO_LEVELDETECT0, readReg(GPIO_LEVELDETECT0) & ~(@as(u32, 1) << 2));
    writeReg(GPIO_LEVELDETECT1, readReg(GPIO_LEVELDETECT1) & ~(@as(u32, 1) << 2));
    writeReg(GPIO_IRQSTATUS_0, @as(u32, 1) << 2);      // Clear pending
    writeReg(GPIO_IRQSTATUS_SET_0, @as(u32, 1) << 2);  // Enable interrupt line 0 for pin 2

    // 7. Enable DMTimer7 module clock in PRCM
    writeReg(CM_PER_TIMER7_CLKCTRL, readReg(CM_PER_TIMER7_CLKCTRL) | 0x2);
    while ((readReg(CM_PER_TIMER7_CLKCTRL) & 0x3) != 0x2) {}

    // 8. Soft-reset DMTimer7
    writeReg(DMTIMER7_TIOCP_CFG, readReg(DMTIMER7_TIOCP_CFG) | 0x1);
    while ((readReg(DMTIMER7_TIOCP_CFG) & 0x1) != 0) {}

    // 9. Configure DMTimer7: Auto-reload mode (AR = Bit 1)
    writeReg(DMTIMER7_TCLR, @as(u32, 1) << 1);

    // 10. Load 500ms initial and reload values
    writeReg(DMTIMER7_TLDR, TIMER_RELOAD_VALUE);
    writeReg(DMTIMER7_TCRR, TIMER_RELOAD_VALUE);

    // 11. Clear and enable overflow interrupt (OVF = Bit 1)
    writeReg(DMTIMER7_IRQSTATUS, 0x2);
    writeReg(DMTIMER7_IRQENABLE_SET, 0x2);

    // 12. Start DMTimer7 (ST = Bit 0)
    writeReg(DMTIMER7_TCLR, readReg(DMTIMER7_TCLR) | 0x1);

    hal.Cio.writeString("Hardware initialization complete.\r\n");
}

// ============================================================================
// FreeRTOS Task Runners
// ============================================================================

/// Blinker task: delays 2 seconds, toggles USR1 LED (GPIO1_22)
fn blinkerTaskRunner(param: ?*anyopaque) callconv(.c) void {
    _ = param;

    while (true) {
        rtos.delayMs(2000);

        if (led1Flag == 0) {
            writeReg(GPIO_SETDATAOUT, @as(u32, 1) << 22);
            led1Flag = 1;
        } else {
            writeReg(GPIO_CLEARDATAOUT, @as(u32, 1) << 22);
            led1Flag = 0;
        }
    }
}

/// Timer task: responds to DMTimer7 interrupt, toggles USR0 LED (GPIO1_21)
fn timerTaskRunner(param: ?*anyopaque) callconv(.c) void {
    _ = param;

    // Register DMTimer7 interrupt with AINTC
    IntRegister(SYS_INT_TINT7, vDMTimer7_Handler);
    IntPrioritySet(SYS_INT_TINT7, 10, AINTC_HOSTINT_ROUTE_IRQ);
    IntSystemEnable(SYS_INT_TINT7);

    while (true) {
        if (xTimerSemaphore) |sem| {
            if (xQueueSemaphoreTake(sem, rtos.portMAX_DELAY) == rtos.pdPASS) {
                if (led0Flag == 1) {
                    writeReg(GPIO_CLEARDATAOUT, @as(u32, 1) << 21);
                    led0Flag = 0;
                } else {
                    writeReg(GPIO_SETDATAOUT, @as(u32, 1) << 21);
                    led0Flag = 1;
                }
            }
        }
    }
}

/// Button task: responds to button press, logs over CIO, toggles DMTimer7 on/off
fn buttonTaskRunner(param: ?*anyopaque) callconv(.c) void {
    _ = param;

    // Register GPIO1_2 interrupt with AINTC
    IntRegister(SYS_INT_GPIOINT1A, vGPIO1_Button_Handler);
    IntPrioritySet(SYS_INT_GPIOINT1A, 8, AINTC_HOSTINT_ROUTE_IRQ);
    IntSystemEnable(SYS_INT_GPIOINT1A);

    var presses: u32 = 0;

    while (true) {
        if (xButtonSemaphore) |sem| {
            if (xQueueSemaphoreTake(sem, rtos.portMAX_DELAY) == rtos.pdPASS) {
                presses +%= 1;

                hal.Cio.print("Button pressed! {d} times.\r\n", .{presses});

                // Toggle Timer 7 start/stop (ST is Bit 0)
                const current_tclr = readReg(DMTIMER7_TCLR);
                if ((current_tclr & 0x1) != 0) {
                    writeReg(DMTIMER7_TCLR, current_tclr & ~@as(u32, 0x1)); // Stop
                } else {
                    writeReg(DMTIMER7_TCLR, current_tclr | 0x1);           // Start
                }
            }
        }
    }
}

// ============================================================================
// Application Entry Point
// ============================================================================

pub fn main() callconv(.c) c_int {
    // 1. Initialize CIO / Semihosting subsystem
    hal.Cio.init();

    hal.Cio.writeString("\r\n=====================================================\r\n");
    hal.Cio.writeString("   BeagleBone Black FreeRTOS Demo (Zig 0.17)         \r\n");
    hal.Cio.writeString("   DMTimer7 (500ms) + GPIO Button + USR LEDs        \r\n");
    hal.Cio.writeString("=====================================================\r\n\r\n");

    // 2. Hardware peripheral configuration
    prvSetupHardware();

    // 3. Create binary semaphores (queue length = 1, item size = 0, type = BINARY_SEMAPHORE = 3)
    xButtonSemaphore = xQueueGenericCreate(1, 0, 3);
    xTimerSemaphore = xQueueGenericCreate(1, 0, 3);

    // 4. Create tasks statically
    _ = rtos.Task.createStatic(
        STACK_WORDS,
        "blinker",
        1,
        blinkerTaskRunner,
        null,
        &g_blinker_stack,
        &g_blinker_tcb,
    );

    _ = rtos.Task.createStatic(
        STACK_WORDS,
        "timer",
        2,
        timerTaskRunner,
        null,
        &g_timer_stack,
        &g_timer_tcb,
    );

    _ = rtos.Task.createStatic(
        STACK_WORDS * 2,
        "button",
        3,
        buttonTaskRunner,
        null,
        &g_button_stack,
        &g_button_tcb,
    );

    hal.Cio.writeString("Starting FreeRTOS Scheduler...\r\n");

    // 5. Start scheduler
    rtos.startScheduler();

    while (true) {}
}

test "timer reload calculation" {
    // 24MHz clock, 500ms = 12,000,000 counts. 0xFFFFFFFF - 12000000 + 1 = 0xFF48F300
    const counts: u32 = 24_000_000 / 2;
    const reload: u32 = ~counts +% 1;
    try std.testing.expectEqual(TIMER_RELOAD_VALUE, reload);
}
