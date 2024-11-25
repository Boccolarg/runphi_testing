#!/bin/bash

# Number of iterations for the boot time experiment
iterations=201  # Adjust as needed

# Address, initial value, and Docker image
ADDRESS=0x46d00000
INITIAL_VALUE=0xDEADBEEF
OUTPUT_FILE="/root/times.txt"
DOCKER_IMAGE="dessertunina/bootimessamplerultrascale:arm64"

for ((i=1; i<=iterations; i++))
do
    echo "Iteration $i: Measuring boot time..."

    # Write the initial value to the address
    #echo "Writing $INITIAL_VALUE to $ADDRESS..."
    devmem $ADDRESS 32 $INITIAL_VALUE

    # Run the Docker container in the background
    #echo "Starting Docker container..."
    cat /root/times.txt > /dev/null
    docker run --name time_sampler --rm $DOCKER_IMAGE &

    # Continuously check the value at the address until it changes
    # echo "Monitoring $ADDRESS for changes..."
    sleep 2
    while :; do
        CURRENT_VALUE=$(devmem $ADDRESS 32)
        if [[ "$CURRENT_VALUE" != "$INITIAL_VALUE" ]]; then
            #echo "Value changed at $ADDRESS! New value: $CURRENT_VALUE"

            # Record the new value with timestamp
            echo "$CURRENT_VALUE - STOP$i" >> $OUTPUT_FILE

            # Stop and remove the Docker container
            #echo "Stopping Docker container..."
            docker stop time_sampler > /dev/null 2>&1
            docker rm time_sampler > /dev/null 2>&1

            break
        fi
        # Optional: Sleep to reduce CPU usage
        sleep 2
    done

    # Sync filesystem to flush pending writes
    #sync

    # Drop caches
    #echo "Dropping caches..."
    #echo 3 > /proc/sys/vm/drop_caches

    # Optional: Sleep a few seconds to allow the system to stabilize
    sleep 3
done

echo "All iterations completed. Results saved to $OUTPUT_FILE."
