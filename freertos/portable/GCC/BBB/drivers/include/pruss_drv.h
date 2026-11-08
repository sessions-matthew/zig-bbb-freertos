/**
 * \file  pruss_drv.h
 *
 * \brief High-level PRU-ICSS driver header and shared memory interface
 *        for AM3358 on BeagleBone Black.
 */

#ifndef __PRUSS_DRV_HIGH_H__
#define __PRUSS_DRV_HIGH_H__

#include <stdint.h>
#include <stdbool.h>
#include "pruss.h"

#ifdef __cplusplus
extern "C" {
#endif

/* PRU System Events */
#define PRU_SYSEVT_ARM_TO_PRU0       (16U)  /* pr1_pru_mst_intr[0]: Host -> PRU0 */
#define PRU_SYSEVT_PRU0_TO_ARM       (19U)  /* pr1_pru_mst_intr[3]: PRU0 -> Host (EVTOUT0) */

/* PRU INTC Channel and Host Mappings */
#define PRU_CHANNEL_0                (0U)   /* Mapped to Host 0 (PRU0 R31 bit 30) */
#define PRU_CHANNEL_1                (1U)   /* Mapped to Host 1 (PRU1 R31 bit 30) */
#define PRU_CHANNEL_2                (2U)   /* Mapped to Host 2 (SYS_INT_PRUSS1_EVTOUT0, IRQ 20) */

#define PRU_HOSTINT_0                (0U)   /* PRU0 */
#define PRU_HOSTINT_1                (1U)   /* PRU1 */
#define PRU_HOSTINT_2                (2U)   /* ARM AINTC EVTOUT0 */

/* PRU Core Indices */
#define PRU_CORE_0                   (0U)
#define PRU_CORE_1                   (1U)

/* PRU Control Register Offsets (relative to PRUxCONTROL_PHYS_BASE) */
#define PRU_CTRL_CONTROL_REG         (0x00U)
#define PRU_CTRL_STATUS_REG          (0x04U)
#define PRU_CTRL_WAKEUP_EN_REG       (0x08U)
#define PRU_CTRL_CYCLE_REG           (0x0CU)
#define PRU_CTRL_STALL_REG           (0x10U)

/* PRU Control Register Bits */
#define PRU_CTRL_SOFT_RST_N          (1U << 0)
#define PRU_CTRL_ENABLE              (1U << 1)
#define PRU_CTRL_SLEEPING            (1U << 2)
#define PRU_CTRL_COUNTER_EN          (1U << 3)
#define PRU_CTRL_RESET_PC            (1U << 4)

/* PRU Shared Memory Magic Signature */
#define PRU_SHARED_MEM_MAGIC         (0x50525530U) /* 'PRU0' in ASCII */

/* Commands sent from ARM Host to PRU */
typedef enum {
    PRU_CMD_NONE            = 0,
    PRU_CMD_ECHO_MULT       = 1,   /* Multiply argument by 42 */
    PRU_CMD_SQRT            = 2,   /* Compute integer square root */
    PRU_CMD_FIBONACCI       = 3,   /* Compute N-th Fibonacci number */
    PRU_CMD_CHECKSUM        = 4,   /* Compute 32-bit CRC / additive checksum */
    PRU_CMD_PULSE_GEN       = 5    /* High speed pulse generation test */
} pru_cmd_t;

/* Status flags reported by PRU */
typedef enum {
    PRU_STATUS_INIT         = 0,
    PRU_STATUS_READY        = 1,
    PRU_STATUS_BUSY         = 2,
    PRU_STATUS_DONE         = 3,
    PRU_STATUS_ERROR        = 0xFF
} pru_status_t;

/**
 * \brief Shared Memory layout between ARM Cortex-A8 (FreeRTOS) and PRU0.
 *
 * Mapped to PRU Data RAM 0:
 *   - ARM Host physical address: 0x4A300000
 *   - PRU0 local address:        0x00000000
 */
typedef struct {
    volatile uint32_t host_cmd;             /* Offset 0x00: Command from Host (pru_cmd_t) */
    volatile uint32_t host_param;           /* Offset 0x04: Input parameter/argument */
    volatile uint32_t pru_resp;             /* Offset 0x08: Result/response from PRU */
    volatile uint32_t pru_cycle_count;      /* Offset 0x0C: Cycles taken by PRU for last cmd */
    volatile uint32_t pru_heartbeat;        /* Offset 0x10: Monotonically increasing counter */
    volatile uint32_t pru_interrupt_count;  /* Offset 0x14: Number of interrupts handled by PRU */
    volatile uint32_t pru_status;           /* Offset 0x18: Current status (pru_status_t) */
    volatile uint32_t magic;                /* Offset 0x1C: Magic number (PRU_SHARED_MEM_MAGIC) */
    volatile uint32_t test_buffer[8];       /* Offset 0x20-0x3F: Optional data buffer for checksum */
} pru_shared_mem_t;

/* PRUSS Driver Functions */

/**
 * \brief Initialize PRU-ICSS power, clocks, and reset state.
 */
int PRUSS_Init(void);

/**
 * \brief Configure the PRU INTC (Interrupt Controller) for bidirectional
 *        communication between ARM Host and PRU0.
 */
void PRUSS_IntcInit(void);

/**
 * \brief Load firmware binary/instruction array into PRU Instruction RAM (IRAM).
 *
 * \param pruNum PRU core (PRU_CORE_0 or PRU_CORE_1)
 * \param instructions Array of 32-bit PRU instructions
 * \param numWords Number of 32-bit instruction words
 */
int PRUSS_LoadProgram(unsigned int pruNum, const uint32_t *instructions, unsigned int numWords);

/**
 * \brief Start PRU execution.
 */
int PRUSS_Start(unsigned int pruNum);

/**
 * \brief Stop/Halt PRU execution.
 */
int PRUSS_Stop(unsigned int pruNum);

/**
 * \brief Reset PRU core.
 */
int PRUSS_Reset(unsigned int pruNum);

/**
 * \brief Trigger a system event from Host to PRU.
 *
 * \param eventNum System event number (e.g. PRU_SYSEVT_ARM_TO_PRU0)
 */
void PRUSS_SendEvent(unsigned int eventNum);

/**
 * \brief Clear a pending system event in the PRU INTC.
 *
 * \param eventNum System event number (e.g. PRU_SYSEVT_PRU0_TO_ARM)
 */
void PRUSS_ClearEvent(unsigned int eventNum);

/**
 * \brief Get pointer to PRU Data RAM 0 (shared memory struct).
 */
pru_shared_mem_t* PRUSS_GetSharedMem(void);

#ifdef __cplusplus
}
#endif

#endif /* __PRUSS_DRV_HIGH_H__ */
