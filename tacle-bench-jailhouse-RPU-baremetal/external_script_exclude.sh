#!/bin/bash

# Variables
ITERATIONS=40
BAREMETAL_INMATE_CELL="zynqmp-kv260-APU-inmate-demo.cell"
BIN_FILE_DIR="/root/tacle-bench-binaries/"
CELL_NAME="inmate-demo-APU"
TIMEOUT_SECONDS=15
SLEEP_TIME=2  # Time to wait between iterations for synchronization

# List of benchmarks to exclude
EXCLUDE_BENCHMARKS=(
    "adpcm_dec" "adpcm_enc" "ammunition" "anagram" "audiobeam" "bitcount"
    "bitonic" "bsort" "cjpeg_transupp" "cjpeg_wrbmp" "cosf" "countnegative"
    "cover" "cubic" "deg2rad" "dijkstra" "duff" "epic" "fac" "fft" "fir2dim"
    "fmref" "g723_enc" "gsm_dec" "gsm_enc" "h264_dec" "iir" "isqrt"
    "jfdctint" "lift" "lms" "ludcmp" "matrix1" "md5" "minver" "mpeg2"
)

# Fetch every bin file in the bin directory
BENCHMARKS=$(find "$BIN_FILE_DIR" -type f | xargs -n 1 basename | sort)

# Check if any benchmarks were found
if [[ -z "$BENCHMARKS" ]]; then
    echo "No Benchmark binaries found within $BIN_FILE_DIR. Exiting..."
    exit 1
else
    echo "Found $(echo "$BENCHMARKS" | wc -l) benchmarks."
fi

# Filter out excluded benchmarks
FILTERED_BENCHMARKS=()
for BIN_FILE in $BENCHMARKS; do
    BENCH_NAME="${BIN_FILE%.*}"
    if [[ ! " ${EXCLUDE_BENCHMARKS[@]} " =~ " $BENCH_NAME " ]]; then
        FILTERED_BENCHMARKS+=("$BIN_FILE")
    fi
done
echo "Executing $(echo "$FILTERED_BENCHMARKS" | wc -l) benchmarks."
# Initialize benchmark counter
BENCHMARK_COUNTER=0

# Iterate over each remaining benchmark
for BIN_FILE in "${FILTERED_BENCHMARKS[@]}"; do
    echo "Processing benchmark $BIN_FILE..."
    BENCHMARK_COUNTER=$((BENCHMARK_COUNTER + 1))
    echo "Benchmark counter: $BENCHMARK_COUNTER"
    
    # Execute the benchmark ITERATIONS times
    for ((ITER=1; ITER<=ITERATIONS; ITER++)); do
        echo "Iteration $ITER/$ITERATIONS for benchmark $BIN_FILE..."

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

        # Wait for synchronization
        echo "Waiting for $SLEEP_TIME seconds before the next iteration..."
        sleep $SLEEP_TIME

        # Destroy the non-root cell
        echo "Destroying the non-root cell..."
        jailhouse cell destroy $CELL_NAME

        # Flush system caches
        echo "Flushing caches..."
        sync
        echo 3 > /proc/sys/vm/drop_caches
        sleep 2
    done

    echo "Benchmark $BIN_FILE completed."
done

# Exit
echo "Script completed. All benchmarks executed $ITERATIONS times."
