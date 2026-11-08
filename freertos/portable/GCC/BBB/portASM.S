/*
 * FreeRTOS Kernel V11.1.0
 * Copyright (C) 2021 Amazon.com, Inc. or its affiliates. All Rights Reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy of
 * this software and associated documentation files (the "Software"), to deal in
 * the Software without restriction, including without limitation the rights to
 * use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
 * the Software, and to permit persons to whom the Software is furnished to do so,
 * subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
 * FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
 * COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
 * IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 * CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 *
 * https://www.FreeRTOS.org
 * https://github.com/FreeRTOS
 * 
 * This file is part of a FreeRTOS port for the Beaglebone Black.
 *
 */

    /* decalre main and exit functions */
    .extern main
	.extern exit


	.syntax unified
	.text
	.arm
	.fpu neon

	/* Hardware registers. */
	.extern ulICCIAR
	.extern ulICCEOIR
	.extern ulICCPMR

	/* Variables and functions. */
	.extern ulMaxAPIPriorityMask
	@ .extern _freertos_vector_table
	.extern pxCurrentTCB
	.extern vTaskSwitchContext
	@ .extern vApplicationIRQHandler
	.extern vApplicationFPUSafeIRQHandler
	.extern ulPortInterruptNesting
	.extern ulPortTaskHasFPUContext

	@ .extern indicator
	@ .extern undefIndicator

	.global FreeRTOS_IRQ_Handler
	.global FreeRTOS_SWI_Handler
	.global vPortRestoreTaskContext

    .align  0

	.extern __bss_beg__
	.extern __bss_end__
	.extern __stack_end__
	.extern __data_beg__
	.extern __data_end__
	.extern __data_beg_src__

    /* don't need these, I think? */
	@ .extern vIRQHandler
	@ .extern vPortYieldProcessor
	@ .extern DATA_ABORT

	.global start
	.global endless_loop

	@************************** Global symbols for TI ISR ************************************
	
	@ .global IRQHandler
	@ .global FIQHandler
	@ .global AbortHandler
	@ .global SVC_Handler
	@ .global UndefInstHandler
	@ .global CPUAbortHandler
	@ .global fnRAMVectors    

	.equ INTCPS, 0x48200000
	.equ INTC_SIR_IRQ, 0x40
	.equ INTC_SIR_FIQ, 0x44
	.equ INTC_CONTROL, 0x48
	.equ INTC_THRESHOLD, 0x68
	.equ INTC_IRQ_PRIORITY, 0x68
	
	.equ ADDR_SIR_IRQ, INTCPS + INTC_SIR_IRQ
	.equ ADDR_SIR_FIQ, INTCPS + INTC_SIR_FIQ
	.equ ADDR_CONTROL, INTCPS + INTC_CONTROL
	.equ ADDR_THRESHOLD, INTCPS + INTC_THRESHOLD
	.equ ADDR_IRQ_PRIORITY, INTCPS + INTC_IRQ_PRIORITY

	.equ MASK_ACTIVE_IRQ, 0x0000007F
	.equ MASK_ACTIVE_FIQ, 0x0000007F
	.equ NEWIRQAGR, 0x00000001
	.equ NEWFIQAGR, 0x00000002

	.equ MASK_SVC_NUM, 0xFF000000

    /* Standard definitions of Mode bits and Interrupt (I & F) flags in PSRs */
    .equ  MODE_USR, 0x10            /* User Mode */
    .equ  MODE_FIQ, 0x11            /* FIQ Mode */
    .equ  MODE_IRQ, 0x12            /* IRQ Mode */
    .equ  MODE_SVC, 0x13            /* Supervisor Mode */
    .equ  MODE_ABT, 0x17            /* Abort Mode */
    .equ  MODE_UND, 0x1B            /* Undefined Mode */
    .equ  MODE_SYS, 0x1F            /* System Mode */

    .equ  I_BIT, 0x80               /* when I bit is set, IRQ is disabled */
    .equ  F_BIT, 0x40               /* when F bit is set, FIQ is disabled */


    	/* Stack Sizes - ensure adequate headroom for Semihosting/CIO traps */
    .equ  UND_STACK_SIZE, 0x00001000   /* 4 KB */
    .equ  ABT_STACK_SIZE, 0x00002000   /* 8 KB */
    .equ  FIQ_STACK_SIZE, 0x00001000   /* 4 KB */
    .equ  IRQ_STACK_SIZE, 0x00002000   /* 8 KB */
    .equ  SVC_STACK_SIZE, 0x00002000   /* 8 KB */


.globl Entry
.weak _start
.weak _mainCRTStartup
Entry:
start:
_start:
_mainCRTStartup:

	/* Setup a stack for each mode - note that this only sets up a usable stack
	for system/user, SWI and IRQ modes.   Also each mode is setup with
	interrupts initially disabled. */
    ldr   r0, .LC6
    msr   CPSR_c, #MODE_UND|I_BIT|F_BIT /* Undefined Instruction Mode */
    mov   sp, r0
    sub   r0, r0, #UND_STACK_SIZE
    msr   CPSR_c, #MODE_ABT|I_BIT|F_BIT /* Abort Mode */
    mov   sp, r0
    sub   r0, r0, #ABT_STACK_SIZE
    msr   CPSR_c, #MODE_FIQ|I_BIT|F_BIT /* FIQ Mode */
    mov   sp, r0
    sub   r0, r0, #FIQ_STACK_SIZE
    msr   CPSR_c, #MODE_IRQ|I_BIT|F_BIT /* IRQ Mode */
    mov   sp, r0
    sub   r0, r0, #IRQ_STACK_SIZE
    msr   CPSR_c, #MODE_SVC|I_BIT|F_BIT /* Supervisor Mode */
    mov   sp, r0
    sub   r0, r0, #SVC_STACK_SIZE
    msr   CPSR_c, #MODE_SYS|I_BIT|F_BIT /* System Mode */
    mov   sp, r0

	/* Run main in system mode. System mode uses the main stack and ensures
	SVC calls (Semihosting / yields) trap to Supervisor mode without corrupting LR. */
	msr   CPSR_c, #MODE_SYS|I_BIT|F_BIT

	/* Clear BSS (fast 16-byte burst clear). */
	mov     r2, #0
	mov     r4, #0
	mov     r5, #0
	mov     r6, #0
	ldr		r1, .LC1		/* Start of memory block */
	ldr		r3, .LC2		/* End of memory block */

.clear_loop_16:
	add		r7, r1, #16
	cmp		r7, r3
	bgt		.clear_loop_1
	stmia	r1!, {r2, r4, r5, r6}
	b		.clear_loop_16

.clear_loop_1:
	cmp		r1, r3
	bhs		.end_clear_loop
	strb	r2, [r1], #1
	b		.clear_loop_1

.end_clear_loop:

	/* Initialise data. */

	ldr		r1, .LC3		/* Start of memory block */
	ldr		r2, .LC4		/* End of memory block */
	ldr		r3, .LC5
	subs	r3, r3, r1		/* Length of block */
	beq		.end_set_loop

.set_loop:
	ldrb	r4, [r2], #1
	strb	r4, [r1], #1
	subs	r3, r3, #1
	bgt		.set_loop

.end_set_loop:

	mov		r0, #0          /* no arguments  */
	mov		r1, #0          /* no argv either */

	    /* Set V=0, A=0 in CP15 SCTRL register - for VBAR to point to vector and disable strict alignment checking */
	    mrc    p15, 0, r0, c1, c0, 0    @ Read CP15 SCTRL Register
	    bic    r0, #(1 << 13)           @ V = 0
	    bic    r0, #(1 << 1)            @ A = 0 (disable strict alignment fault)
	    mcr    p15, 0, r0, c1, c0, 0    @ Write CP15 SCTRL Register

		// Read the CP Access register
        mrc p15,0,r0,c1,c0,2

        // Enable full access to NEON/VFP (Coprocessors 10 and 11)
        orr r0, r0, #0x00F00000 
        
        // Write the CP Access register
        mcr p15,0,r0,c1,c0,2 
        
        // Instruction Synchronization Barrier to ensure changes take effect
        isb 

        // Switch on the VFP and NEON hardware (by setting the EN bit in FPEXC)
        mov r0,#0x40000000 
        vmsr FPEXC, r0

	    /* Set vector address in CP15 VBAR register */
	    ldr     r0, =_vector_table
	    mcr     p15, 0, r0, c12, c0, 0  @Set VBAR

	    /* Enable Performance Monitor Counter (PMCCNTR) in CP15 */
	    mrc     p15, 0, r0, c9, c14, 0  @ Read PMUSERENR
	    orr     r0, r0, #1              @ Enable user/privileged access
	    mcr     p15, 0, r0, c9, c14, 0

	    mrc     p15, 0, r0, c9, c12, 0  @ Read PMCR
	    orr     r0, r0, #7              @ Bit 0=Enable, Bit 1=Reset events, Bit 2=Reset cycle counter
	    bic     r0, r0, #(1 << 3)       @ Bit 3=0: 1:1 cycle count
	    mcr     p15, 0, r0, c9, c12, 0

	    mov     r0, #(1 << 31)          @ Bit 31: Enable PMCCNTR cycle counter
	    mcr     p15, 0, r0, c9, c12, 1  @ PMCNTENSET

	bl main

.Lendless_loop:
	b .Lendless_loop

	.align 0

	.LC1:
	.word   __bss_beg__
	.LC2:
	.word   __bss_end__
	.LC3:
	.word   __data_beg__
	.LC4:
	.word   __data_beg_src__
	.LC5:
	.word   __data_end__
	.LC6:
	.word   __stack_end__


/* Setup vector table in .isr_vector at 0x80000000 */

.section .isr_vector, "ax"
         .code 32
         .align 5
.globl _vector_table
.globl __isr_vector
__isr_vector:
_vector_table:
	ldr pc, [pc, #24]    /* 0x00 Reset */
	ldr pc, [pc, #24]    /* 0x04 Undefined Instruction */
	ldr pc, [pc, #24]    /* 0x08 Supervisor Call (SVC) */
	ldr pc, [pc, #24]    /* 0x0C Prefetch Abort */
	ldr pc, [pc, #24]    /* 0x10 Data Abort */
	ldr pc, [pc, #24]    /* 0x14 Reserved */
	ldr pc, [pc, #24]    /* 0x18 IRQ */
	ldr pc, [pc, #24]    /* 0x1C FIQ */

	.long Entry
	.long UndefInstHandler
	.long FreeRTOS_SWI_Handler
	.long AbortHandler
	.long AbortHandler
	.long 0
	.long FreeRTOS_IRQ_Handler
	.long FIQHandler


.macro portSAVE_CONTEXT

	/* Save the LR and SPSR onto the system mode stack before switching to
	system mode to save the remaining system mode registers. */
	SRSDB	sp!, #MODE_SYS
	CPS		#MODE_SYS
	PUSH	{R0-R12, R14}

	/* Push the critical nesting count. */
	LDR		R2, ulCriticalNestingConst
	LDR		R1, [R2]
	PUSH	{R1}

	/* Does the task have a floating point context that needs saving?  If
	ulPortTaskHasFPUContext is 0 then no. */
	LDR		R2, ulPortTaskHasFPUContextConst
	LDR		R3, [R2]
	CMP		R3, #0

	/* Save the floating point context, if any. */
	VMRSNE  R1,  FPSCR
	PUSHNE	{R1}
	VPUSHNE {D0-D15}
	VPUSHNE	{D16-D31}

	/* Save ulPortTaskHasFPUContext itself. */
	PUSH	{R3}

	/* Save the stack pointer in the TCB. */
	LDR		R0, pxCurrentTCBConst
	LDR		R1, [R0]
	STR		SP, [R1]

	.endm

; /**********************************************************************/

.macro portRESTORE_CONTEXT

	/* Set the SP to point to the stack of the task being restored. */
	LDR		R0, pxCurrentTCBConst
	LDR		R1, [R0]
	LDR		SP, [R1]

	/* Is there a floating point context to restore?  If the restored
	ulPortTaskHasFPUContext is zero then no. */
	LDR		R0, ulPortTaskHasFPUContextConst
	POP		{R1}
	STR		R1, [R0]
	CMP		R1, #0

	/* Restore the floating point context, if any. */
	VPOPNE	{D16-D31}
	VPOPNE	{D0-D15}
	POPNE 	{R0}
	VMSRNE  FPSCR, R0

	/* Restore the critical section nesting depth. */
	LDR		R0, ulCriticalNestingConst
	POP		{R1}
	STR		R1, [R0]

	/* Ensure the priority mask is correct for the critical nesting depth. */
	LDR		R0, =ADDR_THRESHOLD
	LDR		R2, [R0]
	CMP		R1, #0
	MOVEQ	R4, #255
	LDRNE	R4, ulMaxAPIPriorityMaskConst
	LDRNE	R4, [R4]
	STR		R4, [R0]

	/* Restore all system mode registers other than the SP (which is already
	being used). */
	POP		{R0-R12, R14}

	/* Return to the task code, loading CPSR on the way. */
	RFEIA	sp!

	.endm




/******************************************************************************
 * SVC handler is used to start the scheduler.
 *****************************************************************************/
.align 4
.global FreeRTOS_SWI_Handler
.type FreeRTOS_SWI_Handler, %function
FreeRTOS_SWI_Handler:
	/* Check if the caller was in Thumb mode (T bit in SPSR) or ARM mode */
	push	{r0, r1}
	mrs		r0, spsr
	tst		r0, #0x20
	bne		.Lsvc_from_thumb

	/* ARM state: instruction is 4 bytes before LR */
	ldr		r1, [lr, #-4]
	bic		r1, r1, #0xFF000000
	cmp		r1, #0
	bne		.Lsemihosting_return
	pop		{r0, r1}

	/* FreeRTOS Yield (SWI 0): Save context, switch task, restore context */
	portSAVE_CONTEXT
	LDR		R0, vTaskSwitchContextConst
	BLX		R0
	portRESTORE_CONTEXT

.Lsvc_from_thumb:
	/* Thumb state: Semihosting is SVC 0xAB */
	/* Fallthrough to common return */

.Lsemihosting_return:
	pop		{r0, r1}
.global SVC_Handler
SVC_Handler:
	movs	pc, lr


/******************************************************************************
 * vPortRestoreTaskContext is used to start the scheduler.
 *****************************************************************************/
.align 4
.type vPortRestoreTaskContext, %function
vPortRestoreTaskContext:
	/* Switch to system mode. */
	CPS		#MODE_SYS
	portRESTORE_CONTEXT

.align 4
.type FreeRTOS_IRQ_Handler, %function
FreeRTOS_IRQ_Handler:
	/* Return to the interrupted instruction. */
	SUB		lr, lr, #4

	/* Push the return address and SPSR. */
	PUSH	{lr}
	MRS		lr, SPSR
	PUSH	{lr}

	/* Change to supervisor mode to allow reentry. */
	CPS		#MODE_SVC

	/* Push used registers. */
	PUSH	{r0-r3, r12}

	/* Increment nesting count.  r3 holds the address of ulPortInterruptNesting
	for future use.  r1 holds the original ulPortInterruptNesting value for
	future use. */
	LDR		r3, ulPortInterruptNestingConst
	LDR		r1, [r3]
	ADD		r2, r1, #1
	STR		r2, [r3]

	@ /* Read value from the interrupt acknowledge register, which is stored in r0
	@ for future parameter and interrupt clearing use. */
	@ LDR 	r2, ulICCIARConst
	@ LDR		r2, [r2]
	@ LDR		r0, [r2]

	/* Ensure bit 2 of the stack pointer is clear.  r2 holds the bit 2 value for
	future use.  _RB_ Does this ever actually need to be done provided the start
	of the stack is 8-byte aligned? */
	MOV		r2, sp
	AND		r2, r2, #4
	SUB		sp, sp, r2

	/* Call the interrupt handler.  r4 pushed to maintain alignment. */
	PUSH	{r0-r4, lr}
	LDR		r1, vApplicationIRQHandlerConst
	BLX		r1
	POP		{r0-r4, lr}
	ADD		sp, sp, r2

	CPSID	i
	DSB
	ISB

	@LDR		r1, indicatorConst
	@BLX		r1
	
	@ /* Write the value read from ICCIAR to ICCEOIR. */
	@ LDR 	r4, ulICCEOIRConst
	@ LDR		r4, [r4]
	@ STR		r0, [r4]

	MOV      r0, #NEWIRQAGR           @ Acknowledge the IRQ & Enable new IRQ Generation
	LDR      r2, =ADDR_CONTROL
	STR      r0, [r2]
	DSB
	ISB
	
	/* Restore the old nesting count. */
	STR		r1, [r3]

	/* A context switch is never performed if the nesting count is not 0. */
	CMP		r1, #0
	BNE		exit_without_switch

	/* Did the interrupt request a context switch?  r1 holds the address of
	ulPortYieldRequired and r0 the value of ulPortYieldRequired for future
	use. */
	LDR		r1, =ulPortYieldRequired
	LDR		r0, [r1]
	CMP		r0, #0
	BNE		switch_before_exit

exit_without_switch:
    /* No context switch.  Restore used registers, LR_irq and SPSR before
    returning. */
    POP     {r0-r3, r12}
    CPS     #MODE_IRQ
    POP     {LR}
    msr     SPSR_cxsf, LR 
    POP     {LR}
    MOVS    PC, LR

switch_before_exit:
    /* A context switch is to be performed.  Clear the context switch pending
    flag. */
    MOV     r0, #0
    STR     r0, [r1]

    /* Restore used registers, LR-irq and SPSR before saving the context
    to the task stack. */
    POP     {r0-r3, r12}
    CPS     #MODE_IRQ
    POP     {LR}
    msr     SPSR_cxsf, LR
    POP     {LR}
    portSAVE_CONTEXT

	/* Call the function that selects the new task to execute.
	vTaskSwitchContext() if vTaskSwitchContext() uses LDRD or STRD
	instructions, or 8 byte aligned stack allocated data.  LR does not need
	saving as a new LR will be loaded by portRESTORE_CONTEXT anyway. */
	LDR		R0, vTaskSwitchContextConst
	BLX		R0

	/* Restore the context of, and branch to, the task selected to execute
	next. */
	portRESTORE_CONTEXT



/******************************************************************************
 * If the application provides an implementation of vApplicationIRQHandler(),
 * then it will get called directly without saving the FPU registers on
 * interrupt entry, and this weak implementation of
 * vApplicationIRQHandler() will not get called.
 *
 * If the application provides its own implementation of
 * vApplicationFPUSafeIRQHandler() then this implementation of
 * vApplicationIRQHandler() will be called, save the FPU registers, and then
 * call vApplicationFPUSafeIRQHandler().
 *
 * Therefore, if the application writer wants FPU registers to be saved on
 * interrupt entry their IRQ handler must be called
 * vApplicationFPUSafeIRQHandler(), and if the application writer does not want
 * FPU registers to be saved on interrupt entry their IRQ handler must be
 * called vApplicationIRQHandler().
 *****************************************************************************/


.align 4
.weak vApplicationIRQHandler
.type vApplicationIRQHandler, %function
vApplicationIRQHandler:
	PUSH	{LR}
	VMRS  	R1,  FPSCR   @ 1. Save the REAL interrupted FPSCR context
	PUSH	{R1}         @ 2. Push it to the stack

	mov 	r1, #0       @ 3. Now it is safe to clear it for the ISR
	vmsr 	FPSCR, r1

	VPUSH 	{D0-D15}
	VPUSH	{D16-D31}

	LDR		r1, vApplicationFPUSafeIRQHandlerConst
	BLX		r1

	VPOP	{D16-D31}
	VPOP	{D0-D15}
	
	POP 	{R0}         @ Pop the original FPSCR we saved
	VMSR  	FPSCR, R0    @ Restore it back to hardware
	POP 	{PC}

@ vApplicationIRQHandler:
@
@	mov 	r1, #0
@	vmsr 	FPSCR, r1

@	PUSH	{LR}
@	VMRS  	R1,  FPSCR

@	VPUSH 	{D0-D7}
@	VPUSH	{D16-D31}
@	PUSH	{R1}

@	LDR		r1, vApplicationFPUSafeIRQHandlerConst
@	BLX		r1

@	POP 	{R0}
@	VPOP	{D16-D31}
@	VPOP	{D0-D7}
@	VMSR  	FPSCR, R0

@	POP {PC}







@******************************************************************************
@*                  Function Definition of FIQ Handler
@******************************************************************************    
@
@ FIQ is not supported for this SoC.
@
FIQHandler:
        SUBS     pc, r14, #0x4            @ Return to program before FIQ

@******************************************************************************
@* Function Definition of Abort/Undef Handler
@****************************************************************************** @
@ The Abort handler goes to the C handler of abort mode. Note that the undefined
@ instruction is not handled separately.
@ if nothing is done in the abort mode, the execution enters infinite loop.
@

    .global vDataAbortHandler  @ Declare the C function as external

AbortHandler:
UndefInstHandler:
    @ Disable all interrupts (IRQ and FIQ) to prevent context switching
    MRS     r0, cpsr
    ORR     r0, r0, #0xC0
    MSR     cpsr, r0
    
    @ The Link Register (lr) holds the return address (PC + 8 of the faulty instruction).
    @ Move it into r0 so it becomes the first parameter to our C function.
    MOV     r0, lr
    
    @ Branch to the C handler
    LDR     pc, =vDataAbortHandler 

    @ We should never return here, but just in case:
loop_abort:
    B       loop_abort

@ ulICCIARConst:	.word ulICCIAR      @ #IRQn
@ ulICCEOIRConst:	.word ulICCEOIR     @ End of Interrupt  
@ ulICCPMRConst: .word ulICCPMR       @ Priority Mask
pxCurrentTCBConst: .word pxCurrentTCB
ulCriticalNestingConst: .word ulCriticalNesting
ulPortTaskHasFPUContextConst: .word ulPortTaskHasFPUContext
ulMaxAPIPriorityMaskConst: .word ulMaxAPIPriorityMask
vTaskSwitchContextConst: .word vTaskSwitchContext
vApplicationIRQHandlerConst: .word vApplicationIRQHandler
@ vApplicationIRQHandlerConst: .word IRQHandler
ulPortInterruptNestingConst: .word ulPortInterruptNesting
vApplicationFPUSafeIRQHandlerConst: .word vApplicationFPUSafeIRQHandler
@ indicatorConst: .word indicator
@ undefIndicatorConst: .word undefIndicator


@*****************************************************************************
@
@ End of the file
@
.end





