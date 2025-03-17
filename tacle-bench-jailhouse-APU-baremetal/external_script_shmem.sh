#!/bin/bash

# Variables
ITERATIONS=31
INITIAL_VALUE=0xDEADBEEF
INTERMEDIATE_VALUE=0xBEEFDEAD
ADDRESS=0x46d00000
BAREMETAL_INMATE_CELL="zynqmp-kv260-APU-inmate-demo.cell"
BIN_FILE_DIR="/root/taclebench/executables/APU_jailhouse/shmem"
CELL_NAME="inmate-demo-APU"
RESULTS_DIR="/root/taclebench/results/APU_jailhouse/shmem"
TIMEOUT_SECONDS=30
TIMEOUT_THRESHOLD=3

# Ensure the results directory exists
mkdir -p "$RESULTS_DIR"

# Function to display help message
function show_help() {
    echo "Usage: $0 [-b benchmark1 benchmark2 ...]"
    echo "  -b          Run only the specified benchmarks (list benchmark names without .bin)"
    echo "  -h, --help  Show this help message and exit"
    exit 0
}

# Parse arguments
SELECTED_BENCHMARKS=()
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
elif [[ "$1" == "-b" ]]; then
    shift
    SELECTED_BENCHMARKS=("$@")
fi

# Fetch every bin file in the bin directory
ALL_BENCHMARKS=$(find "$BIN_FILE_DIR" -type f | xargs -n 1 basename)

if [[ -z "$ALL_BENCHMARKS" ]]; then
    echo "No Benchmark binaries found within $BIN_FILE_DIR. Exiting..."
    exit 1
fi

echo "Found $(echo "$ALL_BENCHMARKS" | wc -l) benchmarks."

# Filter benchmarks if user provided a subset
if [[ ${#SELECTED_BENCHMARKS[@]} -gt 0 ]]; then
    BENCHMARKS=()
    for BENCH in "${SELECTED_BENCHMARKS[@]}"; do
        if [[ -f "$BIN_FILE_DIR/$BENCH.bin" ]]; then
            BENCHMARKS+=("$BENCH.bin")
        else
            echo "Error: Benchmark '$BENCH.bin' not found in $BIN_FILE_DIR." >&2
            exit 1
        fi
    done
else
    BENCHMARKS=($ALL_BENCHMARKS)
fi

# Initialize benchmark counter
BENCHMARK_COUNTER=0
FAILED_BENCHMARKS=()

# Iterate over each benchmark
for BIN_FILE in ${BENCHMARKS[@]}; do
    echo "Processing benchmark $BIN_FILE..."
    BENCHMARK_COUNTER=$((BENCHMARK_COUNTER + 1))
    echo "Benchmark counter: $BENCHMARK_COUNTER"

    # Prepare result file for the current benchmark
    RESULT_FILE="$RESULTS_DIR/results_${BIN_FILE}.txt"
    : > "$RESULT_FILE"

    TIMEOUT_COUNT=0

    # Execute the benchmark ITERATIONS times
    for ((ITER=1; ITER<=ITERATIONS; ITER++)); do
        echo "Iteration $ITER/$ITERATIONS for benchmark $BIN_FILE..."

        # Write the initial value to memory using devmem
        echo "Writing initial value to memory address..."
        if ! devmem $ADDRESS 32 $INITIAL_VALUE; then
            echo "Error: Failed to write initial value to memory." >&2
            continue
        fi

        # Create the Jailhouse non-root cell
        echo "Creating the Jailhouse non-root cell..."
        if ! jailhouse cell create ${JAILHOUSE_DIR}/configs/arm64/${BAREMETAL_INMATE_CELL}; then
            echo "Error: Failed to create Jailhouse cell." >&2
            continue
        fi

        # Load the binary into the cell
        echo "Loading binary into the Jailhouse cell..."
        if ! jailhouse cell load $CELL_NAME $BIN_FILE_DIR/$BIN_FILE; then
            echo "Error: Failed to load binary into Jailhouse cell." >&2
            jailhouse cell destroy $CELL_NAME
            continue
        fi

        # Start the non-root cell
        echo "Starting the non-root cell..."
        if ! jailhouse cell start $CELL_NAME; then
            echo "Error: Failed to start Jailhouse cell." >&2
            jailhouse cell destroy $CELL_NAME
            continue
        fi

        # Monitor the memory address for changes (Start value)
        CURRENT_VALUE=$INITIAL_VALUE
        echo "Monitoring memory to extract start value..."
        SECONDS=0
        while :
        do
            START_VALUE=$(devmem $ADDRESS 32 2>/dev/null | grep -oE '0x[0-9A-Fa-f]+$')
            if [[ -z "$START_VALUE" ]]; then
                echo "Error: Failed to read memory address." >&2
                break
            fi
            if [ "$START_VALUE" != "$CURRENT_VALUE" ]; then
                # We saw a change, so we write the INTERMEDIATE_VALUE
                if ! devmem $ADDRESS 32 $INTERMEDIATE_VALUE; then
                    echo "Error: Failed to write intermediate value to memory." >&2
                fi
                echo "Value changed! Start value: $START_VALUE"
                break
            fi
            if (( SECONDS >= TIMEOUT_SECONDS )); then
                echo "Timeout while waiting for start value." >&2
                jailhouse cell destroy $CELL_NAME
                TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
                break
            fi
            sleep 1
        done

        # Check for excessive timeouts after waiting for start value
        if (( TIMEOUT_COUNT >= TIMEOUT_THRESHOLD )); then
            echo "Benchmark $BIN_FILE failed due to excessive timeouts. Moving to next benchmark."
            FAILED_BENCHMARKS+=("$BIN_FILE")
            break
        fi

        # Monitor the memory address for changes (End value)
        CURRENT_VALUE=$INTERMEDIATE_VALUE
        echo "Monitoring memory to extract end value..."
        SECONDS=0
        while :
        do
            END_VALUE=$(devmem $ADDRESS 32 2>/dev/null | grep -oE '0x[0-9A-Fa-f]+$')
            if [[ -z "$END_VALUE" ]]; then
                echo "Error: Failed to read memory address." >&2
                break
            fi
            if [ "$END_VALUE" != "$CURRENT_VALUE" ]; then
                echo "Value changed! End value: $END_VALUE"
                break
            fi
            if (( SECONDS >= TIMEOUT_SECONDS )); then
                echo "Timeout while waiting for end value." >&2
                jailhouse cell destroy $CELL_NAME
                TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
                break
            fi
            sleep 1
        done

        # Check for excessive timeouts after waiting for end value
        if (( TIMEOUT_COUNT >= TIMEOUT_THRESHOLD )); then
            echo "Benchmark $BIN_FILE failed due to excessive timeouts. Moving to next benchmark."
            FAILED_BENCHMARKS+=("$BIN_FILE")
            break
        fi

        # Destroy the non-root cell
        echo "Destroying the non-root cell..."
        jailhouse cell destroy $CELL_NAME

        # Flush system caches
        echo "Flushing caches..."
        sync
        echo 3 > /proc/sys/vm/drop_caches
        sleep 2

        # Save the result for the current iteration
        echo "Iteration $ITER: Start value: $START_VALUE, End value: $END_VALUE" >> "$RESULT_FILE"
    done

    # If we broke from the iteration loop due to timeouts, skip the rest
    if (( TIMEOUT_COUNT >= TIMEOUT_THRESHOLD )); then
        continue
    fi

    echo "Benchmark $BIN_FILE completed. Results saved to $RESULT_FILE."
done

# Report failed benchmarks
if [[ ${#FAILED_BENCHMARKS[@]} -gt 0 ]]; then
    echo "The following benchmarks failed due to excessive timeouts:"
    for FAILED in "${FAILED_BENCHMARKS[@]}"; do
        echo "- $FAILED"
    done
else
    echo "All benchmarks completed successfully."
fi

# Exit
echo "Script completed. All benchmarks executed."
