# BeagleBone Black Cortex-A8 Zig FreeRTOS Project

Preemptive multi-tasking FreeRTOS firmware for the BeagleBone Black (TI AM3359 / ARM Cortex-A8) written in **Zig 0.17**, featuring zero-overhead unified FreeRTOS bindings and seamless Texas Instruments **Code Composer Studio (Theia)** integration.

## Architecture & Features

- **Unified FreeRTOS Zig Bindings**:
  - Direct 1-to-1 match with the production patterns in `~/Projects/zig-stm32` and `~/Projects/zig-esp-idf`.
  - Type-safe, compile-time checked queues: `StaticQueue(T, capacity)` (zero heap allocation) and dynamic `Queue(T)`.
  - Thread-safe synchronization: `Mutex` with RAII `LockGuard` (`defer lock.release()`), `Semaphore`, and `CriticalGuard`.
  - Task abstraction: `Task.createStatic(...)` and `Task.spawn(...)` with delay, yield, and stack high-watermark inspection.
- **Embedded Multi-Task Design**:
  1. **Heartbeat Task** (Priority 1):
     - Periodically blinks on-board `USR0` LED.
     - Samples FreeRTOS system tick and stack high-water mark.
     - Publishes `TelemetryMsg` to static FreeRTOS queue.
  2. **Telemetry Task** (Priority 2):
     - Blocks on the FreeRTOS telemetry queue.
     - Acquires the console `Mutex` to guarantee atomic serialization.
     - Emits formatted telemetry reports via UART0 (`115200 8N1`).
     - Strobes `USR1` LED upon message dispatch.
  3. **Monitor Task** (Priority 1):
     - Alternates `USR2` and `USR3` LEDs to indicate active multitasking.
- **Low-Level Startup**:
  - Cortex-A8 vector table, stacks for UND/ABT/FIQ/IRQ/SVC/SYS modes.
  - VFP/NEON coprocessor initialization and Vector Base Address Register (VBAR) setup.
  - AM335x DMTimer tick timer integration at 1000 Hz.
- **Dual Build & Test Workflow**:
  - Command line via `zig build` and `zig build test --summary all` (host macOS unit tests mock kernel without hardware).
  - Code Composer Studio Theia with XDS100v2 JTAG debug probe profile.

## Build & Test Instructions

### Command Line (Native Zig)
```bash
# Build ELF executable (.out) and binary image (.bin)
zig build

# Run all 16 host unit tests (HAL, RTOS primitives, application queue/mutex logic)
zig build test --summary all

# Clean build artifacts
zig build clean
```

Outputs:
- `Debug/BeagleBoneZigRTOS.out`: ELF executable loaded by CCS Theia debugger
- `zig-out/bin/BeagleBoneZigRTOS.out`: Primary ELF artifact
- `zig-out/bin/BeagleBoneZigRTOS.bin`: Flat binary image

### In Code Composer Studio (Theia)

1. Open CCS Theia in this workspace (`/Users/matthewsessions/workspace_ccstheia`).
2. Select **BeagleBoneZigRTOS** in the Project Explorer.
3. Click the **Hammer** icon (Build) or run `make`.
4. Connect external **XDS100v2 USB Debug Probe** to BeagleBone Black JTAG header.
5. In the **Run & Debug** pane, select `BeagleBoneZigRTOS` and click **Start Debugging** (F5).
6. CCS initializes DDR3 memory via GEL, loads `Debug/BeagleBoneZigRTOS.out` at `0x80000000`, and runs FreeRTOS!
