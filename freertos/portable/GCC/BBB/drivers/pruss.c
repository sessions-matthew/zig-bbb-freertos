/**
 * \file  pruss.c
 *
 * \brief Implementation of PRU-ICSS driver functions for AM3358 BeagleBone Black.
 */

#include "pruss_drv.h"
#include "soc_AM335x.h"
#include "hw_types.h"
#include <string.h>

#define CM_PER_PRU_ICSS_CLKCTRL_OFF  (0xE8U)
#define CM_PER_PRU_ICSS_CLKSTCTRL_OFF (0x140U)
#define CM_DPLL_CLKSEL_PRU_ICSS_OFF  (0x30U)
#define PRM_PER_RSTCTRL_OFFSET       (0x00U)
#define PRM_PER_PRU_ICSS_LRST_BIT    (1U << 1)

/**
 * \brief Initialize PRU-ICSS module clock and de-assert reset.
 */
int PRUSS_Init(void)
{
    volatile uint32_t timeout = 0x100000;

    /* 1. De-assert PRU-ICSS local reset in PRM_PER */
    HWREG(SOC_PRM_PER_REGS + PRM_PER_RSTCTRL_OFFSET) &= ~PRM_PER_PRU_ICSS_LRST_BIT;

    /* 2. Select L3F as PRU-ICSS OCP clock (200 MHz) in CM_DPLL */
    HWREG(SOC_CM_DPLL_REGS + CM_DPLL_CLKSEL_PRU_ICSS_OFF) = 0x00;

    /* 3. Wake up PRU-ICSS clock domain in CM_PER (SW_WKUP = 0x2) */
    HWREG(SOC_CM_PER_REGS + CM_PER_PRU_ICSS_CLKSTCTRL_OFF) = 0x02;

    /* 4. Enable PRU-ICSS module clock in CM_PER (MODULEMODE = 0x2) */
    HWREG(SOC_CM_PER_REGS + CM_PER_PRU_ICSS_CLKCTRL_OFF) = 0x02;

    /* Wait for MODULEMODE to be set */
    timeout = 0x100000;
    while (((HWREG(SOC_CM_PER_REGS + CM_PER_PRU_ICSS_CLKCTRL_OFF) & 0x03) != 0x02) && (--timeout > 0))
    {
        /* Wait */
    }

    /* Wait for module to transition out of DISABLED state (IDLEST != 3) */
    timeout = 0x100000;
    while (((HWREG(SOC_CM_PER_REGS + CM_PER_PRU_ICSS_CLKCTRL_OFF) & 0x00030000) == 0x00030000) && (--timeout > 0))
    {
        /* Wait */
    }

    if (timeout == 0)
    {
        return -1; /* Clock initialization timed out */
    }

    /* 2. De-assert PRU-ICSS local reset in PRM_PER */
    HWREG(SOC_PRM_PER_REGS + PRM_PER_RSTCTRL_OFFSET) &= ~PRM_PER_PRU_ICSS_LRST_BIT;

    /* 3. Configure PRU-ICSS CFG SYSCFG: Clear STANDBY_INIT (bit 4), set NO-IDLE/NO-STANDBY */
    HWREG(PRUSS_CFG_BASE + 0x04) = 0x05;

    /* 4. Disable both PRU cores initially */
    PRUSS_Stop(PRU_CORE_0);
    PRUSS_Stop(PRU_CORE_1);

    /* 5. Configure default PRU INTC routing */
    PRUSS_IntcInit();

    /* 6. Clear Shared Memory / Data RAM0 */
    pru_shared_mem_t *sharedMem = PRUSS_GetSharedMem();
    if (sharedMem != NULL)
    {
        memset((void *)sharedMem, 0, sizeof(pru_shared_mem_t));
    }

    return 0;
}

/**
 * \brief Configure the PRU INTC (Interrupt Controller) for bidirectional
 *        ARM <-> PRU0 communication.
 *
 * Mappings:
 *   - SysEvt 16 (ARM -> PRU0) -> Channel 0 -> Host 0 (sets PRU0 R31[30])
 *   - SysEvt 19 (PRU0 -> ARM) -> Channel 2 -> Host 2 (triggers AM335x AINTC IRQ 20)
 */
void PRUSS_IntcInit(void)
{
    /* Clear global enable while configuring */
    HWREG(INTC_PHYS_BASE + PRU_INTC_GER_REG) = 0x00;

    /* Clear all pending system event status in SECR1 and SECR2 */
    HWREG(INTC_PHYS_BASE + PRU_INTC_SECR1_REG) = 0xFFFFFFFF;
    HWREG(INTC_PHYS_BASE + PRU_INTC_SECR2_REG) = 0xFFFFFFFF;

    /* Disable all system events initially */
    HWREG(INTC_PHYS_BASE + PRU_INTC_ECR1_REG) = 0xFFFFFFFF;
    HWREG(INTC_PHYS_BASE + PRU_INTC_ECR2_REG) = 0xFFFFFFFF;

    /* Map System Events to Channels (CMR1..CMR16) */
    /* CMR5 controls events 16, 17, 18, 19:
     *   - Byte 0 (Evt 16): Channel 0 (0x00)
     *   - Byte 1 (Evt 17): Channel 0 (0x00)
     *   - Byte 2 (Evt 18): Channel 1 (0x01)
     *   - Byte 3 (Evt 19): Channel 2 (0x02)
     */
    HWREG(INTC_PHYS_BASE + PRU_INTC_CMR5_REG) = (0x02 << 24) | (0x01 << 16) | (0x00 << 8) | (0x00 << 0);

    /* Map Channels to Host Interrupts (HMR1..HMR3) */
    /* HMR1 controls channels 0, 1, 2, 3:
     *   - Byte 0 (Ch 0): Host 0 (0x00) -> PRU0 R31[30]
     *   - Byte 1 (Ch 1): Host 1 (0x01) -> PRU1 R31[30]
     *   - Byte 2 (Ch 2): Host 2 (0x02) -> EVTOUT0 (AINTC IRQ 20)
     *   - Byte 3 (Ch 3): Host 3 (0x03) -> EVTOUT1 (AINTC IRQ 21)
     */
    HWREG(INTC_PHYS_BASE + PRU_INTC_HMR1_REG) = (0x03 << 24) | (0x02 << 16) | (0x01 << 8) | (0x00 << 0);

    /* Enable System Event 16 (ARM -> PRU0) and System Event 19 (PRU0 -> ARM) via EISR */
    HWREG(INTC_PHYS_BASE + PRU_INTC_EISR_REG) = PRU_SYSEVT_ARM_TO_PRU0;
    HWREG(INTC_PHYS_BASE + PRU_INTC_EISR_REG) = PRU_SYSEVT_PRU0_TO_ARM;

    /* Enable Host Interrupt 0 (PRU0) and Host Interrupt 2 (ARM EVTOUT0) via HIEISR */
    HWREG(INTC_PHYS_BASE + PRU_INTC_HIEISR_REG) = PRU_HOSTINT_0;
    HWREG(INTC_PHYS_BASE + PRU_INTC_HIEISR_REG) = PRU_HOSTINT_2;

    /* Enable all host interrupts globally (GER) */
    HWREG(INTC_PHYS_BASE + PRU_INTC_GER_REG) = 0x01;
}

/**
 * \brief Load firmware instructions into PRU Instruction RAM.
 */
int PRUSS_LoadProgram(unsigned int pruNum, const uint32_t *instructions, unsigned int numWords)
{
    uint32_t iramBase;
    uint32_t i;

    if (instructions == NULL || numWords == 0)
    {
        return -1;
    }

    if (pruNum == PRU_CORE_0)
    {
        iramBase = PRU0IRAM_PHYS_BASE;
    }
    else if (pruNum == PRU_CORE_1)
    {
        iramBase = PRU1IRAM_PHYS_BASE;
    }
    else
    {
        return -1;
    }

    /* 1. Stop and reset PRU core */
    PRUSS_Stop(pruNum);
    PRUSS_Reset(pruNum);

    /* 2. Write 32-bit instructions to PRU IRAM */
    for (i = 0; i < numWords; i++)
    {
        HWREG(iramBase + (i * 4U)) = instructions[i];
    }

    return 0;
}

/**
 * \brief Start PRU execution.
 */
int PRUSS_Start(unsigned int pruNum)
{
    uint32_t ctrlBase;

    if (pruNum == PRU_CORE_0)
    {
        ctrlBase = PRU0CONTROL_PHYS_BASE;
    }
    else if (pruNum == PRU_CORE_1)
    {
        ctrlBase = PRU1CONTROL_PHYS_BASE;
    }
    else
    {
        return -1;
    }

    /* Start PRU at PC=0 with cycle counter enabled (CTR_EN | EN | SOFT_RST_N) */
    HWREG(ctrlBase + PRU_CTRL_CONTROL_REG) = (PRU_CTRL_COUNTER_EN | PRU_CTRL_ENABLE | PRU_CTRL_SOFT_RST_N);
    return 0;
}

/**
 * \brief Stop/Halt PRU execution.
 */
int PRUSS_Stop(unsigned int pruNum)
{
    uint32_t ctrlBase;

    if (pruNum == PRU_CORE_0)
    {
        ctrlBase = PRU0CONTROL_PHYS_BASE;
    }
    else if (pruNum == PRU_CORE_1)
    {
        ctrlBase = PRU1CONTROL_PHYS_BASE;
    }
    else
    {
        return -1;
    }

    HWREG(ctrlBase + PRU_CTRL_CONTROL_REG) &= ~PRU_CTRL_ENABLE;
    return 0;
}

/**
 * \brief Reset PRU core program counter and state.
 */
int PRUSS_Reset(unsigned int pruNum)
{
    uint32_t ctrlBase;

    if (pruNum == PRU_CORE_0)
    {
        ctrlBase = PRU0CONTROL_PHYS_BASE;
    }
    else if (pruNum == PRU_CORE_1)
    {
        ctrlBase = PRU1CONTROL_PHYS_BASE;
    }
    else
    {
        return -1;
    }

    /* 1. Disable PRU and assert soft reset with PC reset value = 0 */
    HWREG(ctrlBase + PRU_CTRL_CONTROL_REG) = 0x00000000;

    /* 2. Release soft reset with PRU disabled */
    HWREG(ctrlBase + PRU_CTRL_CONTROL_REG) = PRU_CTRL_SOFT_RST_N;
    return 0;
}

/**
 * \brief Trigger a system event to PRU from ARM Host (via SISR).
 */
void PRUSS_SendEvent(unsigned int eventNum)
{
    HWREG(INTC_PHYS_BASE + PRU_INTC_SISR_REG) = eventNum;
}

/**
 * \brief Clear a pending system event in PRU INTC (via SICR).
 */
void PRUSS_ClearEvent(unsigned int eventNum)
{
    HWREG(INTC_PHYS_BASE + PRU_INTC_SICR_REG) = eventNum;
}

/**
 * \brief Return pointer to PRU Data RAM 0 (shared memory struct).
 */
pru_shared_mem_t* PRUSS_GetSharedMem(void)
{
    return (pru_shared_mem_t *)DATARAM0_PHYS_BASE;
}
