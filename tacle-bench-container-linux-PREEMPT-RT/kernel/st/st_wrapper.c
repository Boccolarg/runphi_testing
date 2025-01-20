#include <stdio.h>
#include <stdlib.h>
#include <time.h>

// Declaration of the benchmark function
void st_entry(void);

int main() {
    struct timespec start, end;
    double elapsed;

    // Get start time
    clock_gettime(CLOCK_MONOTONIC, &start);

    // Execute the benchmark entry function
    st_entry();

    // Get end time
    clock_gettime(CLOCK_MONOTONIC, &end);

    // Calculate elapsed time
    elapsed = (end.tv_sec - start.tv_sec) + 
              (end.tv_nsec - start.tv_nsec) / 1e9;

    // Write elapsed time to a file (Append Mode)
    FILE *file = fopen("/home/execution_time.txt", "a");
    if (file != NULL) {
        fprintf(file, "%.6f\n", elapsed);
        fclose(file);
    } else {
        fprintf(stderr, "Error writing to file\n");
    }

    printf("Benchmark %s execution time: %.6f seconds\n", "st", elapsed);
    return 0;
}
