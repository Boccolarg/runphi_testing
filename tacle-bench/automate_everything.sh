#!/bin/bash

# Step 1: Compile the benchmarks
echo "Step 1: Compiling benchmarks..."
if ./compile_benchmarks.sh; then
    echo "Benchmarks compiled successfully."
else
    echo "Error during benchmark compilation. Exiting..."
    exit 1
fi

# Step 2: Pack executables into containers
echo "Step 2: Packing containers..."
if ./pack_containers.sh; then
    echo "Containers packed successfully."
else
    echo "Error during container packing. Exiting..."
    exit 1
fi

# Step 3: Push containers to the Docker registry
echo "Step 3: Pushing containers to the registry..."
if ./push_containers.sh; then
    echo "Containers pushed successfully."
else
    echo "Error during container push. Exiting..."
    exit 1
fi

echo "All steps completed successfully!"
