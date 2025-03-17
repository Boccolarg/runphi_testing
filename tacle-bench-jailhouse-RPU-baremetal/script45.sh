#!/bin/bash

# Variables
ITERATIONS=40
BIN_FILE_DIR="benchmarks-list/"
RESULTS_DIR="/root/tacle-bench-results-jailhouse-APU"
UART_DEVICE="/dev/kria-01"

# Ensure the results directory exists
mkdir -p "$RESULTS_DIR"

# Fetch every bin file (list should match what’s on the board)
BENCHMARKS=$(find "$BIN_FILE_DIR" -type f | xargs -n 1 basename | sort)

# Check if any benchmarks were found
if [[ -z "$BENCHMARKS" ]]; then
    echo "No Benchmark binaries found within $BIN_FILE_DIR. Exiting..."
    exit 1
else
    echo "Found $(echo "$BENCHMARKS" | wc -l) benchmarks."
fi

# Iterate over each benchmark
for BIN_FILE in $BENCHMARKS; do
    echo "Processing benchmark $BIN_FILE..."

    # Prepare result file for the current benchmark
    RESULT_FILE="$RESULTS_DIR/results_${BIN_FILE}.txt"
    : > "$RESULT_FILE"  # Safely clear the file if it exists

    # Extract benchmark name (capitalize first letter and remove .bin extension)
    BENCHMARK_NAME=$(echo "$BIN_FILE" | sed -E 's/\.bin$//' | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')

    # Execute the benchmark ITERATIONS times
    for ((ITER=1; ITER<=ITERATIONS; ITER++)); do
        echo "Iteration $ITER/$ITERATIONS for benchmark $BIN_FILE..."

        # Capture execution time from UART
        echo "Waiting for execution time from UART..."
        EXECUTION_TIME=""
        SECONDS=0
        while (( SECONDS < 20 )); do
            cat $UART_DEVICE >> /tmp/uart_log.txt &
            sleep 1  # Give some time for output to be captured
            UART_OUTPUT=$(grep "$BENCHMARK_NAME benchmark execution time is:\|Sync exception" /tmp/uart_log.txt | tail -n 1)

            # Check for sync exception
            if echo "$UART_OUTPUT" | grep -q "Sync exception"; then
                echo "Warning: Sync exception detected. Skipping iteration $ITER."
                EXECUTION_TIME="SKIPPED"
                break
            fi

            # Extract execution time if valid output is found
            if [[ -n "$UART_OUTPUT" ]]; then
                EXECUTION_TIME=$(echo "$UART_OUTPUT" | grep -oE '[0-9]+' | tail -n1)
                break
            fi
            sleep 1
        done

        if [[ "$EXECUTION_TIME" == "SKIPPED" ]]; then
            continue
        fi

        if [[ -z "$EXECUTION_TIME" ]]; then
            echo "Error: Timeout or failed to retrieve execution time from UART." >&2
            continue
        fi

        echo "Execution time captured: $EXECUTION_TIME ns"

        # Save the result for the current iteration
        echo "Iteration $ITER: Execution time: $EXECUTION_TIME ns" >> "$RESULT_FILE"
    done

    echo "Benchmark $BIN_FILE completed. Results saved to $RESULT_FILE."
done

# Exit
echo "Script completed. All benchmarks executed $ITERATIONS times."
