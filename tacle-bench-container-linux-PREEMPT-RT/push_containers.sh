#!/bin/bash

# Define your Docker registry
docker_registry="dessertunina"

# Ensure the Docker registry is defined
if [[ -z $docker_registry ]]; then
    echo "Error: Docker registry is not defined. Please set the 'docker_registry' variable."
    exit 1
fi

# List all images with the "tacle-" prefix
docker_images=$(docker images --format "{{.Repository}}" | grep "^tacle-")

# Check if any such images exist
if [[ -z $docker_images ]]; then
    echo "No Docker images with prefix 'tacle-' found to push. Ensure the images are built and available locally."
    exit 0
fi

# Push each image to the Docker registry
for image in $docker_images; do
    # Tag the image with the Docker registry
    new_image="$docker_registry/$image"
    echo "Tagging image $image as $new_image..."
    docker tag "$image" "$new_image"

    # Push the image to the Docker registry
    echo "Pushing $new_image to the Docker registry..."
    docker push "$new_image"

    if [[ $? -ne 0 ]]; then
        echo "Failed to push $new_image. Skipping..."
    else
        echo "Successfully pushed $new_image."
    fi
done

echo "All images have been processed."
