#include <stdint.h>
#include <stddef.h>

#define SRC_ADDRESS  0xFF250000  // Memory-mapped source address
#define DST_ADDRESS  0x46D00000  // Memory-mapped destination address

volatile uint32_t *source = (volatile uint32_t *)SRC_ADDRESS;
volatile uint32_t *destination = (volatile uint32_t *)DST_ADDRESS;

// Declaration of the benchmark function
int audiobeam_entry(void);

int main(void) {
    uint32_t start_time = 0, end_time = 0;
    uint32_t timeout;

    // Save start time from the timer memory area
    start_time = *source;
    if (start_time == 0) {
        *destination = 0xDEAD0000;  // Error code for invalid timer start
        return -1;
    }
    *destination = start_time;

    // Run the benchmark
    int result = audiobeam_entry();

    // Save end time from the timer memory area
    end_time = *source;
    if (end_time == 0) {
        *destination = 0xDEAD0001;  // Error code for invalid timer end
        return -1;
    }

    // Wait for synchronization with the root cell script
    timeout = 0xFFFFFF;
    while (*destination != 0xBEEFDEAD && timeout--) {
        __asm__ volatile ("nop");
    }
    if (timeout == 0) {
        *destination = 0xDEAD0002;  // Error code for timeout
        return -1;
    }

    // Write the end time to the shared memory
    *destination = end_time;

    // Optionally return the benchmark result
    return result;
}
