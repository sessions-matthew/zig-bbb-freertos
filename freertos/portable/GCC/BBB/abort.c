/**
 * \file   abort.c
 *
 * \brief  C abort/exception handler called from portASM.S for ARMv7-A Cortex-A8.
 *         Outputs comprehensive fault diagnostics to:
 *         1. Code Composer Studio CIO Console via ARM Semihosting (_write / svc 0xab)
 *         2. In-memory circular log buffer (g_LogBuffer) viewable in CCS Expressions
 *         3. BeagleBone Black hardware UART0 (115200 8N1)
 */

#include <stdint.h>
#include <stddef.h>

// Driver includes
#include "serial.h"
#include "am3358.h"

// FreeRTOS task query (weak symbols to avoid hard coupling)
struct tskTaskControlBlock;
typedef struct tskTaskControlBlock * TaskHandle_t;
extern TaskHandle_t xTaskGetCurrentTaskHandle(void) __attribute__((weak));
extern char *pcTaskGetName(TaskHandle_t xTaskToQuery) __attribute__((weak));

// Semihosting / CIO syscall provided by librdimon.a
extern int _write(int file, const void *ptr, size_t len) __attribute__((weak));

// In-memory circular log buffer defined in cio.zig
extern uint8_t g_LogBuffer[] __attribute__((weak));
extern uint32_t g_LogIndex __attribute__((weak));

// Function prototypes
void vDataAbortHandler(uint32_t ulFaultAddress);

static void cio_print(const char *str)
{
    if (!str) return;

    size_t len = 0;
    while (str[len] != '\0') {
        len++;
    }

    // 1. Record into circular memory buffer for live CCS Expressions inspection
    if (g_LogBuffer) {
        for (size_t i = 0; i < len; i++) {
            g_LogBuffer[g_LogIndex % 1023] = (uint8_t)str[i];
            g_LogIndex++;
            g_LogBuffer[g_LogIndex % 1023] = 0;
        }
    }

    // 2. Transmit to Code Composer Studio CIO Console via ARM Semihosting (stdout = 1)
    if (_write) {
        _write(1, str, len);
    }

    // 3. Mirror to BeagleBone Black hardware UART0
    serial_puts(UART0_BASE, (char *)str);
}

static void cio_print_hex(uint32_t val)
{
    char buf[11];
    buf[0] = '0';
    buf[1] = 'x';
    const char hex_chars[] = "0123456789ABCDEF";
    for (int i = 0; i < 8; i++) {
        uint32_t shift = (7 - i) * 4;
        buf[2 + i] = hex_chars[(val >> shift) & 0xF];
    }
    buf[10] = '\0';
    cio_print(buf);
}

static const char *decode_dfsr_fault(uint32_t dfsr)
{
    // FS[4] = bit 10, FS[3:0] = bits [3:0]
    uint32_t fs = (dfsr & 0x0F) | ((dfsr >> 6) & 0x10);
    switch (fs) {
        case 0x01: return "Alignment Fault";
        case 0x02: return "Debug Event";
        case 0x03: return "Access Flag Fault (Section)";
        case 0x04: return "Instruction Cache Maintenance Fault";
        case 0x05: return "Translation Fault (Section)";
        case 0x06: return "Access Flag Fault (Page)";
        case 0x07: return "Translation Fault (Page)";
        case 0x08: return "Synchronous External Abort (Non-translation)";
        case 0x09: return "Domain Fault (Section)";
        case 0x0B: return "Domain Fault (Page)";
        case 0x0C: return "Translation Fault (1st Level Table Walk)";
        case 0x0D: return "Permission Fault (Section)";
        case 0x0E: return "Translation Fault (2nd Level Table Walk)";
        case 0x0F: return "Permission Fault (Page)";
        case 0x14: return "Lockdown Fault";
        case 0x16: return "Asynchronous External Abort";
        case 0x19: return "Memory Access Synchronous Parity Error";
        default:   return "Unspecified Fault Status";
    }
}

static const char *decode_arm_mode(uint32_t spsr)
{
    switch (spsr & 0x1F) {
        case 0x10: return "User (USR)";
        case 0x11: return "FIQ";
        case 0x12: return "IRQ";
        case 0x13: return "Supervisor (SVC)";
        case 0x16: return "Monitor (MON)";
        case 0x17: return "Abort (ABT)";
        case 0x1A: return "Hyp (HYP)";
        case 0x1B: return "Undefined (UND)";
        case 0x1F: return "System (SYS) [FreeRTOS Task]";
        default:   return "Unknown Mode";
    }
}

// Data abort handler for BBB
void vDataAbortHandler(uint32_t ulFaultAddress)
{
    static volatile int in_abort = 0;
    if (in_abort) {
        while(1);
    }
    in_abort = 1;

    uint32_t dfsr = 0, dfar = 0, ifsr = 0, ifar = 0, spsr = 0;

    /* Read ARMv7-A CP15 fault status and address registers */
    __asm volatile ("mrc p15, 0, %0, c5, c0, 0" : "=r" (dfsr)); /* Data Fault Status Register */
    __asm volatile ("mrc p15, 0, %0, c5, c0, 1" : "=r" (ifsr)); /* Instruction Fault Status Register */
    __asm volatile ("mrc p15, 0, %0, c6, c0, 0" : "=r" (dfar)); /* Data Fault Address Register */
    __asm volatile ("mrc p15, 0, %0, c6, c0, 2" : "=r" (ifar)); /* Instruction Fault Address Register */
    __asm volatile ("mrs %0, spsr" : "=r" (spsr));              /* Saved Program Status Register */

    cio_print("\r\n");
    cio_print("======================================================================\r\n");
    cio_print("  FATAL EXCEPTION: DATA ABORT (ARMv7-A Cortex-A8)\r\n");
    cio_print("======================================================================\r\n");

    // 1. Offending instruction and exception return
    cio_print("  Offending Instruction (~LR-8): ");
    cio_print_hex(ulFaultAddress - 8);
    cio_print("\r\n");

    cio_print("  Exception Return Address (LR): ");
    cio_print_hex(ulFaultAddress);
    cio_print("\r\n");

    // 2. Data Fault Address & Status
    cio_print("  Faulting Memory Address (DFAR): ");
    cio_print_hex(dfar);
    cio_print("\r\n");

    cio_print("  Data Fault Status (DFSR):       ");
    cio_print_hex(dfsr);
    cio_print(" [");
    cio_print((dfsr & (1 << 11)) ? "WRITE" : "READ");
    cio_print(" | ");
    cio_print(decode_dfsr_fault(dfsr));
    cio_print("]\r\n");

    // 3. Instruction Fault Status & Address (if non-zero)
    if (ifsr != 0 || ifar != 0) {
        cio_print("  Instruction Fault (IFSR/IFAR):  ");
        cio_print_hex(ifsr);
        cio_print(" / ");
        cio_print_hex(ifar);
        cio_print("\r\n");
    }

    // 4. Processor status register (SPSR)
    cio_print("  Pre-Fault CPU State (SPSR):     ");
    cio_print_hex(spsr);
    cio_print(" [");
    cio_print(decode_arm_mode(spsr));
    cio_print((spsr & (1 << 5)) ? " | Thumb" : " | ARM");
    cio_print("]\r\n");

    // 5. Active FreeRTOS task if scheduler is active
    if (xTaskGetCurrentTaskHandle && pcTaskGetName) {
        TaskHandle_t hCurrent = xTaskGetCurrentTaskHandle();
        if (hCurrent != NULL) {
            const char *pcName = pcTaskGetName(hCurrent);
            if (pcName != NULL) {
                cio_print("  Active FreeRTOS Task:           \"");
                cio_print(pcName);
                cio_print("\"\r\n");
            }
        }
    }

    cio_print("----------------------------------------------------------------------\r\n");
    cio_print("  System halted. Connect CCS JTAG debugger to inspect variables/stack.\r\n");
    cio_print("======================================================================\r\n\r\n");

    // Halt the core permanently for JTAG debugging
    while(1)
    {
    }
}
