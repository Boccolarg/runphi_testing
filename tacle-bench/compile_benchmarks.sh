#!/bin/bash

# Directory to store the compiled executables
output_dir="executables"

# File containing the benchmark names and directory structure
benchmark_file="benchmark_used.txt"

# Create the output directory if it doesn't exist
mkdir -p $output_dir

# Variables to track compilation results
total_count=0
success_count=0
failures=()
skipped_lines=0

# Clear previous error log
error_log="compilation_errors.log"
> $error_log

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
        c_files=$(find "$benchmark_dir" -type f -name "*.c" 2>/dev/null | tr '\n' ' ')

        if [[ -z $c_files ]]; then
            echo "No source files found for $benchmark_name" >> $error_log
            failures+=("$benchmark_name")
            total_count=$((total_count + 1))
            continue
        fi

        # Compile the benchmark
        echo "Compiling $benchmark_name from $c_files..."
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
