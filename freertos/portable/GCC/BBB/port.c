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

/* Standard includes. */
#include <stdlib.h>
#include <string.h>

/* Board/driver includes */
#include "am3358.h"
#include "intc.h"
#include "serial.h"

/* Scheduler includes. */
#include "FreeRTOS.h"
#include "task.h"

extern volatile int **pxCurrentTCB;

/* Some vendor specific files default configCLEAR_TICK_INTERRUPT() in
portmacro.h. */

#ifndef configCLEAR_TICK_INTERRUPT
	#define configCLEAR_TICK_INTERRUPT()
#endif

/* A critical section is exited when the critical section nesting count reaches
this value. */
#define portNO_CRITICAL_NESTING			( ( uint32_t ) 0 )


/* Tasks are not created with a floating point context, but can be given a
floating point context after they have been created.  A variable is stored as
part of the tasks context that holds portNO_FLOATING_POINT_CONTEXT if the task
does not have an FPU context, or any other value if the task does have an FPU
context. */
#define portNO_FLOATING_POINT_CONTEXT	( ( StackType_t ) 0 )

/* Constants required to setup the initial task context. */
#define portINITIAL_SPSR				( ( StackType_t ) 0x1f ) /* System mode, ARM mode, IRQ enabled FIQ enabled. */
#define portTHUMB_MODE_BIT				( ( StackType_t ) 0x20 )
#define portINTERRUPT_ENABLE_BIT		( 0x80UL )
#define portTHUMB_MODE_ADDRESS			( 0x01UL )

/* Used by portASSERT_IF_INTERRUPT_PRIORITY_INVALID() when ensuring the binary
point is zero. */
#define portBINARY_POINT_BITS			( ( uint8_t ) 0x03 )

/* Masks all bits in the APSR other than the mode bits. */
#define portAPSR_MODE_BITS_MASK			( 0x1F )

/* The value of the mode bits in the APSR when the CPU is executing in user
mode. */
#define portAPSR_USER_MODE				( 0x10 )

/* The critical section macros only mask interrupts up to an application
determined priority level.  Sometimes it is necessary to turn interrupt off in
the CPU itself before modifying certain hardware registers. */
#define portCPU_IRQ_DISABLE()										\
	__asm volatile ( "CPSID i" );									\
	__asm volatile ( "DSB" );										\
	__asm volatile ( "ISB" );

#define portCPU_IRQ_ENABLE()										\
	__asm volatile ( "CPSIE i" );									\
	__asm volatile ( "DSB" );										\
	__asm volatile ( "ISB" );

#if 1
/* Macro to unmask all interrupt priorities. */
#define portCLEAR_INTERRUPT_MASK()									\
{																	\
	portCPU_IRQ_DISABLE();											\
    IntPriorityThresholdSet(portUNMASK_VALUE);		                \
	__asm volatile (	"DSB		\n"								\
						"ISB		\n" );							\
	if( xTaskGetSchedulerState() != taskSCHEDULER_NOT_STARTED )		\
	{																\
		portCPU_IRQ_ENABLE();										\
	}																\
}
#else
/* Macro to unmask all interrupt priorities. */
#define portCLEAR_INTERRUPT_MASK()									\
{																	\
	IntPriorityThresholdSet(portUNMASK_VALUE);		                \
	__asm volatile (	"DSB		\n"								\
						"ISB		\n" );							\
}
#endif
#define portINTERRUPT_PRIORITY_REGISTER_OFFSET		0x400UL
#define portMAX_8_BIT_VALUE							( ( uint8_t ) 0xff )
#define portBIT_0_SET								( ( uint8_t ) 0x01 )

/* Let the user override the pre-loading of the initial LR with the address of
prvTaskExitError() in case it messes up unwinding of the stack in the
debugger. */
#ifdef configTASK_RETURN_ADDRESS
	#define portTASK_RETURN_ADDRESS	configTASK_RETURN_ADDRESS
#else
	#define portTASK_RETURN_ADDRESS	prvTaskExitError
#endif

/* The space on the stack required to hold the FPU registers.  This is 32 64-bit
registers, plus a 32-bit status register. */
#define portFPU_REGISTER_WORDS	( ( 32 * 2 ) + 1 ) // D0-D7 + FPSCR

/*-----------------------------------------------------------*/

/* Port specific interrupt related definitions. These were previouls in in portISR.c. */

#define portSEI()                                                          \
{                                                                          \
    __asm volatile("PUSH {R0};");                                          \
    __asm volatile("MRS R0, CPSR;");     /* Read the status register */    \
    __asm volatile("BIC R0, R0, #0x80;"); /* Clear the I bit */            \
    __asm volatile("MSR CPSR, R0;");     /*Write it back to enable IRQs */ \
    __asm volatile("POP {R0};");                                           \
}

#define portDI()                                                           \
{                                                                          \
    __asm volatile("PUSH {R0};");                                          \
    __asm volatile("MRS R0, CPSR;");     /* Read the status register */    \
    __asm volatile("ORR R0, R0, #0x80;"); /* Set the I bit */              \
    __asm volatile("MSR CPSR, R0;");     /*Write it back to disable IRQs */\
    __asm volatile("POP {R0};");                                           \
}

/*-----------------------------------------------------------*/

/* Used in the asm file. */
__attribute__(( used )) const uint32_t ulMaxAPIPriorityMask = ( configMAX_API_CALL_INTERRUPT_PRIORITY );

/*-----------------------------------------------------------*/
/*-----------------------------------------------------------*/

/*
 * Starts the first task executing.  This function is necessarily written in
 * assembly code so is implemented in portASM.s.
 */
extern void vPortRestoreTaskContext( void );

/*
 * Used to catch tasks that attempt to return from their implementing function.
 */
static void prvTaskExitError( void );

/*
 * BBB wrapper for the FreeRTOS tick handler 
 */
void vBeagleBone_Tick_Handler(void);

/*
 * The application IRQ handler. This is the dispatcher. Using the FPU safe
 * version since the FPU is enabled.
 */
void vApplicationFPUSafeIRQHandler(void);

/*-----------------------------------------------------------*/

/* A variable is used to keep track of the critical section nesting.  This
variable has to be stored as part of the task context and must be initialised to
a non zero value to ensure interrupts don't inadvertently become unmasked before
the scheduler starts.  As it is stored as part of the task context it will
automatically be set to 0 when the first task is started. */
volatile uint32_t ulCriticalNesting = 9999UL;

/* Saved as part of the task context.  If ulPortTaskHasFPUContext is non-zero then
a floating point context must be saved and restored for the task. */
volatile uint32_t ulPortTaskHasFPUContext = pdFALSE;

/* Set to 1 to pend a context switch from an ISR. */
volatile uint32_t ulPortYieldRequired = pdFALSE;

/* Counts the interrupt nesting depth.  A context switch is only performed if
if the nesting depth is 0. */
volatile uint32_t ulPortInterruptNesting = 0UL;

/* These are defined in intc.c. */
extern void (*fnRAMVectors[configMAX_IRQ_VECTORS])(void);
extern void IntIrqEnableNewIrqs(void);

/*-----------------------------------------------------------*/

/*
 * See header file for description.
 */
StackType_t *pxPortInitialiseStack( StackType_t *pxTopOfStack, TaskFunction_t pxCode, void *pvParameters )
{
	/* Setup the initial stack of the task.  The stack is set exactly as
	expected by the portRESTORE_CONTEXT() macro.

	The fist real value on the stack is the status register, which is set for
	system mode, with interrupts enabled.  A few NULLs are added first to ensure
	GDB does not try decoding a non-existent return address. */
	*pxTopOfStack = ( StackType_t ) NULL;
	pxTopOfStack--;
	*pxTopOfStack = ( StackType_t ) NULL;
	pxTopOfStack--;
	*pxTopOfStack = ( StackType_t ) NULL;
	pxTopOfStack--;
	*pxTopOfStack = ( StackType_t ) portINITIAL_SPSR;

	if( ( ( uint32_t ) pxCode & portTHUMB_MODE_ADDRESS ) != 0x00UL )
	{
		/* The task will start in THUMB mode. */
		*pxTopOfStack |= portTHUMB_MODE_BIT;
	}

	pxTopOfStack--;

	/* Next the return address, which in this case is the start of the task. */
	*pxTopOfStack = ( StackType_t ) pxCode;
	pxTopOfStack--;

	/* Next all the registers other than the stack pointer. */
	*pxTopOfStack = ( StackType_t ) portTASK_RETURN_ADDRESS;	/* R14 */
	pxTopOfStack--;
	*pxTopOfStack = ( StackType_t ) 0x12121212;	/* R12 */
	pxTopOfStack--;
	*pxTopOfStack = ( StackType_t ) 0x11111111;	/* R11 */
	pxTopOfStack--;
	*pxTopOfStack = ( StackType_t ) 0x10101010;	/* R10 */
	pxTopOfStack--;
	*pxTopOfStack = ( StackType_t ) 0x09090909;	/* R9 */
	pxTopOfStack--;
	*pxTopOfStack = ( StackType_t ) 0x08080808;	/* R8 */
	pxTopOfStack--;
	*pxTopOfStack = ( StackType_t ) 0x07070707;	/* R7 */
	pxTopOfStack--;
	*pxTopOfStack = ( StackType_t ) 0x06060606;	/* R6 */
	pxTopOfStack--;
	*pxTopOfStack = ( StackType_t ) 0x05050505;	/* R5 */
	pxTopOfStack--;
	*pxTopOfStack = ( StackType_t ) 0x04040404;	/* R4 */
	pxTopOfStack--;
	*pxTopOfStack = ( StackType_t ) 0x03030303;	/* R3 */
	pxTopOfStack--;
	*pxTopOfStack = ( StackType_t ) 0x02020202;	/* R2 */
	pxTopOfStack--;
	*pxTopOfStack = ( StackType_t ) 0x01010101;	/* R1 */
	pxTopOfStack--;
	*pxTopOfStack = ( StackType_t ) pvParameters; /* R0 */
	pxTopOfStack--;

	/* The task will start with a critical nesting count of 0 as interrupts are
	enabled. */
	*pxTopOfStack = portNO_CRITICAL_NESTING;

	#if( configUSE_TASK_FPU_SUPPORT == 1 )
	{
		/* The task will start without a floating point context.  A task that
		uses the floating point hardware must call vPortTaskUsesFPU() before
		executing any floating point instructions. */
		pxTopOfStack--;
		*pxTopOfStack = portNO_FLOATING_POINT_CONTEXT;
	}
	#elif( configUSE_TASK_FPU_SUPPORT == 2 )
	{
		/* The task will start with a floating point context.  Leave enough
		space for the registers - and ensure they are initialised to 0. */
		pxTopOfStack -= portFPU_REGISTER_WORDS;
		memset( pxTopOfStack, 0x00, portFPU_REGISTER_WORDS * sizeof( StackType_t ) );

		pxTopOfStack--;
		*pxTopOfStack = pdTRUE;
		ulPortTaskHasFPUContext = pdTRUE;
	}
	#else
	{
		#error Invalid configUSE_TASK_FPU_SUPPORT setting -
        configUSE_TASK_FPU_SUPPORT must be set to 1, 2, or left undefined.
	}
	#endif
	
	return pxTopOfStack;
}
/*-----------------------------------------------------------*/

static void prvTaskExitError( void )
{
	/* A function that implements a task must not exit or attempt to return to
	its caller as there is nothing to return to.  If a task wants to exit it
	should instead call vTaskDelete( NULL ).

	Artificially force an assert() to be triggered if configASSERT() is
	defined, then stop here so application writers can catch the error. */
	configASSERT( ulPortInterruptNesting == ~0UL );
	portDISABLE_INTERRUPTS();
	for( ;; );
}
/*-----------------------------------------------------------*/

BaseType_t xPortStartScheduler( void )
{
uint32_t ulAPSR;
	/* Only continue if the CPU is not in User mode.  The CPU must be in a
	Privileged mode for the scheduler to start. */
	__asm volatile ( "MRS %0, CPSR" : "=r" ( ulAPSR ) );
	ulAPSR &= portAPSR_MODE_BITS_MASK;
	configASSERT( ulAPSR != portAPSR_USER_MODE );

	if( ulAPSR != portAPSR_USER_MODE )
	{
		/* Interrupts are turned off in the CPU itself to ensure tick does
			not execute	while the scheduler is being started.  Interrupts are
			automatically turned back on in the CPU when the first task starts
			executing. */
		portCPU_IRQ_DISABLE();

		/* Start the timer that generates the tick ISR. */
		configSETUP_TICK_INTERRUPT(); // should start TI DMTIMER

		// for debug
		/* while(HWREG(DMTIMER2 + IRQSTATUS) != 2) {}
		serial_puts(UART0_BASE,"Interrupt Triggered!\n\r");
		serial_puts(UART0_BASE,"In xPortStartScheduler...\n\r"); */

		/* Start the first task executing. */
		vPortRestoreTaskContext();		
	}
	/* Will only get here if vTaskStartScheduler() was called with the CPU in
	a non-privileged mode or the binary point register was not set to its lowest
	possible value.  prvTaskExitError() is referenced to prevent a compiler
	warning about it being defined but not referenced in the case that the user
	defines their own exit address. */
	( void ) prvTaskExitError;
	return 0;
}
/*-----------------------------------------------------------*/

void vPortEndScheduler( void )
{
	/* Not implemented in ports where there is nothing to return to.
	Artificially force an assert. */
	configASSERT( ulCriticalNesting == 1000UL );
}
/*-----------------------------------------------------------*/

void vPortEnterCritical( void )
{
	//extern portBASE_TYPE xInsideISR;
	
	{
		/* Mask interrupts up to the max syscall interrupt priority. */
		ulPortSetInterruptMask();
		/* 	Now interrupts are disabled ulCriticalNesting can be accessed
				directly.  Increment ulCriticalNesting to keep a count of how many times
				portENTER_CRITICAL() has been called. */
		
		ulCriticalNesting++;
		/* This is not the interrupt safe version of the enter critical function so
		assert() if it is being called from an interrupt context.  Only API
		functions that end in "FromISR" can be used in an interrupt.  Only assert if
		the critical nesting count is 1 to protect against recursive calls if the
		assert function also uses a critical section. */
		if( ulCriticalNesting >= 1 )
		{
			while(ulPortInterruptNesting);
			configASSERT( ulPortInterruptNesting == 0 );
		}
	}
}
/*-----------------------------------------------------------*/

void vPortExitCritical( void )
{
	//extern portBASE_TYPE xInsideISR;
	
	if( ulCriticalNesting > portNO_CRITICAL_NESTING )
	{
		/* Decrement the nesting count as the critical section is being
		exited. */
		ulCriticalNesting--;

		/* If the nesting level has reached zero then all interrupt
		priorities must be re-enabled. */
		if( ulCriticalNesting == portNO_CRITICAL_NESTING )
		{
			/* Critical nesting has reached zero so all interrupt priorities
			should be unmasked. */
			portCLEAR_INTERRUPT_MASK();
		}
	}
}
/*-----------------------------------------------------------*/

void FreeRTOS_Tick_Handler( void )
{
	/* Increment the RTOS tick. */
	if( xTaskIncrementTick() != pdFALSE )
	{
		ulPortYieldRequired = pdTRUE;
	}	
}

/*-----------------------------------------------------------*/


#if( configUSE_TASK_FPU_SUPPORT != 2 )

	void vPortTaskUsesFPU( void )
	{
	uint32_t ulInitialFPSCR = 0;

		/* A task is registering the fact that it needs an FPU context.  Set the
		FPU flag (which is saved as part of the task context). */
		ulPortTaskHasFPUContext = pdTRUE;

		/* Initialise the floating point status register. */
		__asm volatile ( "FMXR 	FPSCR, %0" :: "r" (ulInitialFPSCR) );
	}

#endif /* configUSE_TASK_FPU_SUPPORT */
/*-----------------------------------------------------------*/

/* void vPortClearInterruptMask( uint32_t ulNewMaskValue )
{
	if((ulNewMaskValue == pdFALSE) && (ulPortInterruptNesting == 0))
	{
		portCLEAR_INTERRUPT_MASK();
	}
} */

void vPortClearInterruptMask( uint32_t ulNewMaskValue )
{
    if(ulNewMaskValue == pdFALSE)
    {
        if(ulPortInterruptNesting == 0)
        {
            /* Called from a task: Safe to use the full macro which enables CPU interrupts */
            portCLEAR_INTERRUPT_MASK();
        }
        else
        {
            /* Called from an ISR: ONLY restore the INTC threshold, do NOT touch CPU I-bit */
            IntPriorityThresholdSet(portUNMASK_VALUE);
            __asm volatile ( "dsb \n" "isb \n" );
        }
    }
}
/*-----------------------------------------------------------*/

uint32_t ulPortSetInterruptMask( void )
{
	uint32_t ulReturn;
	if(ulPortInterruptNesting == 0) {
		portCPU_IRQ_DISABLE();
	}
	uint32_t current_threshold = IntPriorityThresholdGet();
	if((uint32_t) (configMAX_API_CALL_INTERRUPT_PRIORITY) == current_threshold)
	{
		/* Interrupts were already masked. */
		ulReturn = pdTRUE;
	}
	else
	{
		ulReturn = pdFALSE;
		IntPriorityThresholdSet(
            (uint32_t)(configMAX_API_CALL_INTERRUPT_PRIORITY));
		__asm volatile (	"dsb		\n"
							"isb		\n" );
	}
	if((ulPortInterruptNesting == 0) && (xTaskGetSchedulerState() != taskSCHEDULER_NOT_STARTED)) {
		portCPU_IRQ_ENABLE();
	}
	return ulReturn;
}
/*-----------------------------------------------------------*/

#if( configASSERT_DEFINED == 1 )

	void vPortValidateInterruptPriority( void )
	{
		/* The following assertion will fail if a service routine (ISR) for
		an interrupt that has been assigned a priority above
		configMAX_SYSCALL_INTERRUPT_PRIORITY calls an ISR safe FreeRTOS API
		function.  ISR safe FreeRTOS API functions must *only* be called
		from interrupts that have been assigned a priority at or below
		configMAX_SYSCALL_INTERRUPT_PRIORITY.

		Numerically low interrupt priority numbers represent logically high
		interrupt priorities, therefore the priority of the interrupt must
		be set to a value equal to or numerically *higher* than
		configMAX_SYSCALL_INTERRUPT_PRIORITY.

		FreeRTOS maintains separate thread and ISR API functions to ensure
		interrupt entry is as fast and simple as possible. */
        configASSERT(
            IntCurrIrqPriorityGet() >=
            (uint32_t)(configMAX_API_CALL_INTERRUPT_PRIORITY));
	}

#endif /* configASSERT_DEFINED */
/*-----------------------------------------------------------*/

/* Port specific interrupt related functions. These were previoulsy in in portISR.c. */

/* Tick Handler Wrapper to clear the timer interrupt. Needed becaause 
FreeRTOS_Tick_Handler() doesn't reset DMTIMER2 interrupt.*/
void vBeagleBone_Tick_Handler(void)
{
    // Clear the hardware timer interrupt
    vPortClearTickInterrupt();
    
    // Call the standard FreeRTOS tick logic
    FreeRTOS_Tick_Handler(); 
}

/* This function sets up and starts DMTimer2 as the timer for the system tick. 
We could use the dmtimer driver functions here, but insted this function uses 
direct register manipulation to remain unreliant on the dirver. */
void vSetupTickInterrupt( void )
{
    uint32_t ulTimerCount;
	
    /* Initialize interrupt controller.
	This function is from intc.c of TI's SDK */
    IntINTCInit();

    /* Register Tick interrupt handler.
	This function is from intc.c of TI's SDK */
    IntRegister(SYS_INT_TINT2, vBeagleBone_Tick_Handler);

	/* Set the tick interrupt to the lowest priority required by FreeRTOS */
    IntPrioritySet(SYS_INT_TINT2, configKERNEL_INTERRUPT_PRIORITY, AINTC_HOSTINT_ROUTE_IRQ);
	
	/* Enable Interrupt 68 and 96 and 97 which is used for DMTIMER 2 and GPIO0INTS*/
	HWREG(INTCPS + INTC_MIR_CLEAR(2)) = 0x10;

	/* Calculate the match value required for our wanted tick rate using 24 MHz CLK_M_OSC */
    ulTimerCount = (0xFFFFFFFF - (24000000 / configTICK_RATE_HZ) + 1);
    
	/* Set and enable DMTIMER2 (select 24 MHz CLK_M_OSC as clock source) */
	HWREG(CM_DPLL + CLKSEL_TIMER2_CLK) = 0x1;
	HWREG(CM_PER + CM_PER_TIMER2_CLKCTRL) = 0x2;

	/* reset interface */
	HWREG(DMTIMER2 + TIOCP_CFG) = 0x1; 

	/* initialize counter */
	HWREG(DMTIMER2 + TCRR) = ulTimerCount; // initialize counter
	 
	/* Clear pending matching interrupt (if any) */
	HWREG(DMTIMER2 + IRQSTATUS) = 0x7;

	/* Enable matching interrupts */
	HWREG(DMTIMER2 + IRQENABLE_SET) = 0x2;

	/* Reload value -- IS THIS NEEDED GIVEN BELOW? */
	HWREG(DMTIMER2 + TLDR) = ulTimerCount; //reload value
 
	/* Timer Control Register
	 * bit 0 -> start
	 * bit 1 -> autoreload
	 * bit 6 -> compare enabled
	 */
	HWREG(DMTIMER2 + TCLR) = 0x3;
}

void vPortClearTickInterrupt(void){
    HWREG(DMTIMER2 + IRQSTATUS) = 0x07;
}

// this is for non-FPU safe applications
/* void vApplicationFPUSafeIRQHandler(void)
{
    uint32_t ulInterruptID;

    // Ask the TI INTC which interrupt fired
    ulInterruptID = IntActiveIrqNumGet();

    // Protect against spurious interrupts
    if (ulInterruptID < configMAX_IRQ_VECTORS) 
    {
        // Execute the specific handler registered via IntRegister()
        if (fnRAMVectors[ulInterruptID] != NULL) 
        {
            fnRAMVectors[ulInterruptID]();
        }
    }

    // CRITICAL: Acknowledge the AINTC so it allows the next interrupt
    IntIrqEnableNewIrqs();
} */

void vApplicationFPUSafeIRQHandler(void)
{
    uint32_t ulInterruptID = IntActiveIrqNumGet();

    if (ulInterruptID < configMAX_IRQ_VECTORS) 
    {
        if (fnRAMVectors[ulInterruptID] != NULL) 
        {
            fnRAMVectors[ulInterruptID]();
        }
        else
        {
            // SAFETY TRAP: We caught an unhandled interrupt!
            // Print the ID and halt so we know exactly what went wrong.
            serial_puts(UART0_BASE, "\n\rFATAL: Unhandled IRQ!\n\r");
            while(1);
        }
    }

    //IntIrqEnableNewIrqs(); 
}
