#include <stdint.h>
#include <stddef.h>

#define SRC_ADDRESS  0xFF250000  // Memory-mapped source address
#define DST_ADDRESS  0x46D00000  // Memory-mapped destination address

volatile uint32_t *source = (volatile uint32_t *)SRC_ADDRESS;
volatile uint32_t *destination = (volatile uint32_t *)DST_ADDRESS;

// Declaration of the benchmark function
int jfdctint_entry(void);

int main(void) {
    uint32_t start_time, end_time;

    // Save start time from the timer memory area
    start_time = *source;
    *destination = start_time;

    // Run the benchmark
    int result = jfdctint_entry();

    // Save end time from the timer memory area
    end_time = *source;

    // Wait for synchronization with the root cell script
    while (*destination != 0xBEEFDEAD) {
        // Add a no-operation instruction to prevent optimizations
        __asm__ volatile ("nop");
    }

    // Write the end time to the shared memory
    *destination = end_time;

    // Optionally return the benchmark result
    return result;
}
