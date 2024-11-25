#!/bin/bash

# Number of iterations
ITERATIONS=51

# Docker run command
DOCKER_CMD="docker run --rm -d -i -t \
  --name test \
  --cpu-rt-runtime=950000 \
  -v /root/container_volume:/home \
  --privileged \
  -v /proc/timer_list:/host_timer_list:ro \
  ubuntu /home/start.sh"

# Loop to execute the command 200 times
for i in $(seq 1 $ITERATIONS); do
  echo "Starting container $i..."

  # Run the Docker container
  CONTAINER_ID=$($DOCKER_CMD)

  # Wait for 5 seconds
  sleep 5

  # Stop the container
  echo "Stopping container $i..."
  docker stop "$CONTAINER_ID" >/dev/null 2>&1

  # Flush system caches
  #echo "Flushing caches..."
  #sync
  #echo 3 > /proc/sys/vm/drop_caches

  # Optional: Add a short delay between iterations to avoid overlaps
  sleep 3
done

echo "Completed $ITERATIONS iterations."
