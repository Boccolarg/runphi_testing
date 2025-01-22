#!/bin/bash

# Directory to store the compiled executables
elf_dir="executables/elf"
bin_dir="executables/bin"

# File containing the benchmark names and directory structure
benchmark_file="benchmark_used.txt"

# Variables to track compilation results
total_count=0
success_count=0
failures=()
skipped_lines=0

# Clear previous error log
error_log="compilation_errors.log"
> $error_log

# Clear previous compilation report
compilation_report="compilation_report.txt"
> $compilation_report

# Clear previous executables folder
rm -rf executables/

# Create the output directory if it doesn't exist
mkdir -p $elf_dir
mkdir -p $bin_dir

# Function to create a C wrapper
create_wrapper() {
    local benchmark_name=$1
    local benchmark_dir=$2
    local wrapper_file="$benchmark_dir/${benchmark_name}_wrapper.c"

    cat << EOF > "$wrapper_file"
#include <stdint.h>
#include <stddef.h>
#include <inmate.h>

#define SRC_ADDRESS  0xFF250000  // Memory-mapped source address
#define DST_ADDRESS  0x46D00000  // Memory-mapped destination address

volatile uint32_t *source = (volatile uint32_t *)SRC_ADDRESS;
volatile uint32_t *destination = (volatile uint32_t *)DST_ADDRESS;

// Declaration of the benchmark function
int ${benchmark_name}_entry(void);

int inmate_main(void) {

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
    int result = ${benchmark_name}_entry();

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
EOF
}

# Read the benchmark file line by line
current_directory=""
while IFS= read -r line; do
    # Trim leading and trailing whitespace and non-standard characters
    line=$(echo "$line" | tr -d '$' | xargs)

    # Skip blank lines
    if [[ -z $line ]]; then
        skipped_lines=$((skipped_lines + 1))
        continue
    fi

    if [[ $line =~ ^[A-Z]+$ ]]; then
        # Capital letters indicate a directory
        current_directory=$(echo "$line" | tr '[:upper:]' '[:lower:]')
    elif [[ $line =~ ^[a-zA-Z0-9_-]+$ ]]; then
        # Matches valid benchmark names with letters, numbers, underscores, or dashes
        benchmark_name=$line
        benchmark_dir="./$current_directory/$benchmark_name"
        
        # Find all .c files in the benchmark's directory (excluding the wrapper)
        benchmark_files=$(find "$benchmark_dir" -maxdepth 1 -type f -name "*.c" ! -name "*_wrapper.c" 2>/dev/null | tr '\n' ' ')

        # Add the wrapper file explicitly at the beginning
        wrapper_file="$benchmark_dir/${benchmark_name}_wrapper.c"

        if [[ -z $benchmark_files ]]; then
            echo "No source files found for $benchmark_name" >> $error_log
            failures+=("$benchmark_name")
            total_count=$((total_count + 1))
            continue
        fi

        # Rename only the function definition in benchmark files
        for benchmark_file in $benchmark_files; do
            sed -i "s/^void[[:space:]]\+${benchmark_name}_entry[[:space:]]*(/int ${benchmark_name}_entry(/" "$benchmark_file"
        done

        # Create C wrapper file
        create_wrapper "$benchmark_name" "$benchmark_dir"

        # Compile the benchmark with the wrapper
        echo "Compiling $benchmark_name with wrapper..."
        # aarch64-none-elf-gcc -O2 -nostdlib -nodefaultlibs -ffreestanding \
        #     -o "$elf_dir/$benchmark_name.elf" "$wrapper_file" $benchmark_files 2>> $error_log
        aarch64-none-elf-gcc -O0 -nostdlib -nodefaultlibs -ffreestanding \
            -g3 -v \
            -I./ \
            -T lscript.ld \
            -o "$elf_dir/$benchmark_name.elf" "$wrapper_file" $benchmark_files 2>> $error_log

        aarch64-none-elf-objcopy -O binary "$elf_dir/$benchmark_name.elf" "$bin_dir/$benchmark_name.bin" 2>> $error_log

        # Check if compilation was successful
        if [[ $? -eq 0 ]]; then
            success_count=$((success_count + 1))
        else
            failures+=("$benchmark_name")
        fi

        total_count=$((total_count + 1))
    else
        # Skip any lines that do not match expected formats
        echo "Skipping unrecognized line: $line" >> $error_log
        skipped_lines=$((skipped_lines + 1))
    fi

done < $benchmark_file

# Generate report
echo "Compilation Report:"
echo "-------------------"
echo "Total benchmarks: $total_count"
echo "Successful compilations: $success_count"
echo "Failed compilations: ${#failures[@]}"
if [[ ${#failures[@]} -gt 0 ]]; then
    echo "Benchmarks that failed to compile:"
    for failed_benchmark in "${failures[@]}"; do
        echo "  - $failed_benchmark"
    done
fi

echo "Skipped lines: $skipped_lines"

# Save the report to a file
report_file="compilation_report.txt"
{
    echo "Compilation Report:"
    echo "-------------------"
    echo "Total benchmarks: $total_count"
    echo "Successful compilations: $success_count"
    echo "Failed compilations: ${#failures[@]}"
    if [[ ${#failures[@]} -gt 0 ]]; then
        echo "Benchmarks that failed to compile:"
        for failed_benchmark in "${failures[@]}"; do
            echo "  - $failed_benchmark"
        done
    fi
    echo "Skipped lines: $skipped_lines"
} > $report_file

echo "Report saved to $report_file"
echo "Compilation errors saved to $error_log"

# Cleanup: Remove logs if there are no errors and no skipped lines
if [[ ${#failures[@]} -eq 0 && $skipped_lines -eq 0 ]]; then
    echo "No errors or skipped lines. Cleaning up logs..."
    rm -f compilation_errors.log compilation_report.txt
    echo "Cleanup complete."
fi
