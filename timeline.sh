#!/bin/bash

# Number of iterations for the boot time experiment
iterations=50  # Adjust as needed

for ((i=1; i<=iterations; i++))
do
    echo "Iteration $i: Measuring times..."

    # Run the Docker container in the background
    #echo "Starting Docker container..."

    docker run --name time_sampler --rm dessertunina/helloworld:arm64jh &

    sleep 5
    # Stop and remove the Docker container
    #echo "Stopping Docker container..."
    docker stop time_sampler > /dev/null 2>&1
    docker rm time_sampler > /dev/null 2>&1

    # Optional: Sleep to reduce CPU usage
    #sleep 1
    
    # Sync filesystem to flush pending writes
    #sync

    # Drop caches
    #echo "Dropping caches..."
    #echo 3 > /proc/sys/vm/drop_caches

    # Optional: Sleep a few seconds to allow the system to stabilize
    sleep 4
done

echo "All iterations completed."
