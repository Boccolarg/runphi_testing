#!/bin/bash

# Number of iterations
ITERATIONS=31

# Directory for execution time results
RESULTS_DIR="/root/tacle-bench_results"

# Ensure the results directory exists
mkdir -p "$RESULTS_DIR"

# Fetch all available benchmarks from Docker Hub with pagination (100 entries)
BENCHMARKS=$(docker search dessertunina --format "{{.Name}}" --limit 100 | grep "^dessertunina/tacle-")

# Check if any benchmarks were found
if [[ -z "$BENCHMARKS" ]]; then
    echo "No Docker images found with prefix 'dessertunina/tacle-'"
    exit 1
else
    echo "Found $(echo "$BENCHMARKS" | wc -l) benchmarks from Docker Hub."
fi

# Initialize benchmark counter
BENCHMARK_COUNTER=0

# Loop through each benchmark and run the container
for benchmark in $BENCHMARKS; do
    BENCHMARK_NAME=$(echo "$benchmark" | sed 's|dessertunina/tacle-||')
    echo "Processing benchmark: $BENCHMARK_NAME"

    # Pull the Docker image
    docker pull "$benchmark"

    # Run iterations for the current benchmark
    for i in $(seq 1 $ITERATIONS); do
        echo "Starting container $BENCHMARK_NAME, iteration $i..."

        # Run the Docker container without the -t otherwise there is an issue with nohup
        docker run --rm -i \
          --name "test_$BENCHMARK_NAME" \
          --cpu-rt-runtime=950000 \
          -v "$RESULTS_DIR:/home" \
          --privileged \
          "$benchmark"

        # Ensure the container has finished its execution
        sleep 1

        # Flush system caches
        echo "Flushing caches..."
        sync
        echo 3 > /proc/sys/vm/drop_caches

        # Optional: Add a short delay between iterations to avoid overlaps
        sleep 1
    done

    # Increment benchmark counter
    BENCHMARK_COUNTER=$((BENCHMARK_COUNTER + 1))

    # Rename the execution time file after completing all iterations
    EXEC_TIME_FILE="$RESULTS_DIR/execution_time.txt"
    if [[ -f $EXEC_TIME_FILE ]]; then
        NEW_FILE="$RESULTS_DIR/${BENCHMARK_NAME}_execution_time.txt"
        mv "$EXEC_TIME_FILE" "$NEW_FILE"
        echo "Saved execution time to $NEW_FILE"
    else
        echo "Error: Execution time file not found for $BENCHMARK_NAME"
    fi

    # Print the number of benchmarks executed so far
    echo "Benchmarks executed so far: $BENCHMARK_COUNTER"
done

echo "Completed all benchmarks with $ITERATIONS iterations each."
