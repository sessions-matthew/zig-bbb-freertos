/**
 * @file    serial.c
 * @author  Hfo (Original: 2014)
 * @brief   Bare-metal UART/Serial communication driver for AM335x.
 *
 * @details This file provides the low-level implementation for basic serial 
 * communication. It includes functions to initialize the UART 
 * hardware (specifically targeting UART0 and UART4), calculate baud 
 * rate divisors, and transmit single characters, strings, and data 
 * buffers. It interacts directly with the hardware memory-mapped 
 * registers defined in "am335.h".
 *
 * @note    This implementation currently features blocking transmission 
 * (polling the THRE flag) and focuses on the transmit (TX) path.
 */

#include <stdint.h>
#include "am3358.h"
#include "serial.h"

/**
 * @brief Calculates the clock divisor for a specific baud rate.
 * * This is an internal helper function and typically shouldn't be called 
 * directly from outside this file. It derives the divisor needed for the 
 * UART's baud rate generator based on the system's UART_CLK.
 * * @param baud The desired baud rate (e.g., 115200).
 * @return The integer divisor value to be written to the UART divisor latches.
 */
static int calc_divisor (unsigned int baud)
{
	if (baud == 115200) return 26;
	if (baud == 38400) return 78;
	return (UART_CLK / (16 * baud));
}

/**
 * @brief Initializes the UART hardware at the given base address.
 *
 * You must call this function before attempting to read from or write to 
 * the serial port. It configures the baud rate, enables FIFOs, and sets up 
 * the line control register (e.g., 8 data bits, no parity).
 *
 * @param base The base memory address of the UART module (e.g., UART0_BASE or UART4_BASE).
 */
void init_serial(unsigned int base) {
    /* Enable UART0 clock in PRCM before accessing memory-mapped registers */
    if (base == UART0_BASE) {
        volatile uint32_t *pClkCtrl = (volatile uint32_t *)0x44E004B4;
        *pClkCtrl = 0x2; /* MODULEMODE = ENABLE */
        while ((*pClkCtrl & 0x3) != 0x2);
    }

    int clock_divisor;

    /* Determine the correct baud rate divisor based on which UART is being initialized */
    if (base == UART4_BASE) {
        clock_divisor = calc_divisor(UART4_BAUDRATE);
        (*(REG32(base+0x4))) = 0x0;
        serial_puts(UART0_BASE,"Init4\n");
    }
    else {
        clock_divisor = calc_divisor(UART0_BAUDRATE);
        (*(REG32(base+0x4))) = 0x0;
    }

    /* Unlock divisor latches (DLAB=1) to set the baud rate */
    (*(REG32(base+0xC))) = 0x83;

    /* Write the lower and upper bytes of the divisor */
    (*(REG32(base+0x0))) = clock_divisor & 0xff;
    (*(REG32(base+0x4))) = (clock_divisor >> 8) & 0xff;

    /* Line Control Register (8n1: 8 data bits, no parity, 1 stop bit) */
    (*(REG32(base+0xC))) = 0x03;

    /* Modem Control Register (DTR and RTS high) */
    (*(REG32(base+0x10))) = 0x03;

    /* Enable and clear FIFOs for transmission and reception */
    (*(REG32(base+0x8))) = (FCR_FIFO_EN | FCR_RXSR | FCR_TXSR);

    /* Set MDR1 to 16x Oversampling Mode to enable the UART */
    (*(REG32(base+0x20))) = 0x0;
}

/**
 * @brief Transmits a single character over the serial port.
 * * This is a blocking function. It will wait in a loop until the UART's 
 * Transmitter Holding Register Empty (THRE) flag is set, ensuring the 
 * hardware is ready to accept the next character.
 * * @param base The base memory address of the UART module (e.g., UART0_BASE).
 * @param c The character to transmit.
 */
void serial_putc( unsigned int base, const char c )	{
	/* Ensure UART0 clock is active in PRCM before accessing registers */
	if (base == UART0_BASE) {
		volatile uint32_t *pClkCtrl = (volatile uint32_t *)0x44E004B4;
		if ((*pClkCtrl & 0x3) != 0x2) {
			*pClkCtrl = 0x2;
			while ((*pClkCtrl & 0x3) != 0x2);
		}
	}

	/* Wait until the transmit buffer is empty */
	while (((*(REG32(base+0x14))) & LSR_THRE) == 0);
	
	/* Write the character to the transmit register */
	(*(REG32(base+0x00))) = c;
}

/**
 * @brief Transmits a null-terminated string over the serial port.
 * * Use this function when you want to print standard C strings. It loops 
 * through the string character by character until it hits the null terminator 
 * ('\0'), sending each via serial_putc.
 * * @param base The base memory address of the UART module.
 * @param s Pointer to the null-terminated string to be sent.
 */
void serial_puts (unsigned int base, const char *s)
{
	while (*s) {
		serial_putc (base,*s++);
	}
}

/**
 * @brief Transmits a specified number of characters from a buffer.
 * * Use this function for sending raw data, data buffers, or strings that 
 * might not be null-terminated. It sends exactly 'n' bytes starting from 
 * the memory address 's'.
 * * @param base The base memory address of the UART module.
 * @param s Pointer to the data/string buffer to send.
 * @param n The exact number of bytes to transmit.
 */
void serial_putsn (unsigned int base, const char *s, int n)
{
	int i;
	for (i=0; i<n; i++)	{
		serial_putc (base,s[i]);
	}
}

/**
 * @brief Lightweight unsigned integer-to-ASCII string converter.
 *
 * @details Converts a 32-bit unsigned integer into a null-terminated string 
 * representation based on the provided numerical base. This implementation 
 * is designed to be lightweight and uses no dynamic memory allocation, 
 * relying instead on a small local stack buffer for the conversion.
 *
 * @param value  The 32-bit unsigned integer value to convert.
 * @param buffer Pointer to the character array where the resulting string will 
 * be stored. 
 * IMPORTANT: Ensure this buffer is large enough to hold the 
 * output. For a 32-bit integer in base 2 (binary), the buffer 
 * must be at least 33 bytes long (32 characters + null terminator).
 * @param base   The numerical base for the conversion (e.g., 2 for binary, 
 * 10 for decimal, 16 for hexadecimal).
 *
 * @note For bases greater than 10, the function uses uppercase letters ('A'-'Z').
 */
void uitoa(uint32_t value, char* buffer, int base) 
{
    char temp[33];
    int i = 0;
    
    // Handle 0 explicitly
    if (value == 0) 
    {
        buffer[0] = '0';
        buffer[1] = '\0';
        return;
    }

    // Extract digits backwards
    while (value != 0) 
    {
        uint32_t rem = value % base;
        temp[i++] = (rem > 9) ? (rem - 10) + 'A' : rem + '0';
        value /= base;
    }

    // Reverse the string into the final buffer
    int j = 0;
    while (i > 0) 
    {
        buffer[j++] = temp[--i];
    }
    buffer[j] = '\0';
}
