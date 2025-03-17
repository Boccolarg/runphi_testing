#include <inmate.h>

#define SYSTEM_COUNTER  0xFF250000  // Memory-mapped system_counter address
#define SHARED_MEMORY  0x46D00000  // Memory-mapped shared_memory address

volatile u32 *system_counter = (volatile u32 *)SYSTEM_COUNTER;
volatile u32 *shared_memory = (volatile u32 *)SHARED_MEMORY;

// Declaration of the benchmark function
int fft_entry(void);

void inmate_main(void) {
    //printk("Inmate main fft\n");
    map_range((void *)system_counter, 4, MAP_UNCACHED);
	map_range((void *)shared_memory, 4, MAP_UNCACHED);    
    u32 start_time = 0, end_time = 0;
    // Save start time from the timer memory area
    start_time = *system_counter;
    *shared_memory = start_time;
    // Run the benchmark
    fft_entry();
    // Save end time from the timer memory area
    end_time = *system_counter;
    // Wait for synchronization with the root cell script
    while (*shared_memory != 0xBEEFDEAD) {
        __asm__ volatile ("nop");
    }
    // Write the end time to the shared memory
    *shared_memory = end_time;
    //printk("End Inmate main fft\n");
}
