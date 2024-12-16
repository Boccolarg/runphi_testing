#!/bin/bash

# Directory to store the compiled executables
output_dir="executables"

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
mkdir -p $output_dir

# Function to create a C wrapper
create_wrapper() {
    local benchmark_name=$1
    local benchmark_dir=$2
    local wrapper_file="$benchmark_dir/${benchmark_name}_wrapper.c"

    cat << EOF > "$wrapper_file"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

// Declaration of the benchmark function
void ${benchmark_name}_entry(void);

int main() {
    struct timespec start, end;
    double elapsed;

    // Get start time
    clock_gettime(CLOCK_MONOTONIC, &start);

    // Execute the benchmark entry function
    ${benchmark_name}_entry();

    // Get end time
    clock_gettime(CLOCK_MONOTONIC, &end);

    // Calculate elapsed time
    elapsed = (end.tv_sec - start.tv_sec) + 
              (end.tv_nsec - start.tv_nsec) / 1e9;

    // Write elapsed time to a file
    FILE *file = fopen("/home/execution_time.txt", "w");
    if (file != NULL) {
        fprintf(file, "%.6f\n", elapsed);
        fclose(file);
    } else {
        fprintf(stderr, "Error writing to file\n");
    }

    printf("Benchmark %s execution time: %.6f seconds\n", "$benchmark_name", elapsed);
    return 0;
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
        
        # Find all .c files in the benchmark's directory
        c_files=$(find "$benchmark_dir" -maxdepth 1 -type f -name "*.c" 2>/dev/null | tr '\n' ' ')

        if [[ -z $c_files ]]; then
            echo "No source files found for $benchmark_name" >> $error_log
            failures+=("$benchmark_name")
            total_count=$((total_count + 1))
            continue
        fi

        # Rename only the function definition in benchmark files
        for c_file in $c_files; do
            sed -i "s/^int[[:space:]]\+main[[:space:]]*(/void ${benchmark_name}_entry(/" "$c_file"
        done

        # Create C wrapper file
        create_wrapper "$benchmark_name" "$benchmark_dir"

        # Compile the benchmark with the wrapper
        echo "Compiling $benchmark_name with wrapper..."
        aarch64-linux-gnu-gcc -mcpu=cortex-a53 -march=armv8-a -O0 -w -g3 \
            -o "$output_dir/$benchmark_name" $c_files 2>> $error_log

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
