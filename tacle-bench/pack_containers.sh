#!/bin/bash

# Directory containing the executables
executables_dir="./executables"

# Ensure the executables directory exists
if [[ ! -d $executables_dir ]]; then
    echo "Error: Directory $executables_dir does not exist."
    exit 1
fi

# Iterate over all executables in the directory
for executable in "$executables_dir"/*; do
    if [[ -x $executable && ! -d $executable ]]; then
        # Extract the benchmark name (file name without directory)
        benchmark_name=$(basename "$executable")

        # Create a temporary directory for the Docker context
        temp_dir=$(mktemp -d)
        
        # Write the Dockerfile
        cat > "$temp_dir/Dockerfile" <<EOL
FROM arm64v8/ubuntu:22.04

RUN apt-get update && apt-get install -y \\
    libstdc++6 \\
    && rm -rf /var/lib/apt/lists/*

WORKDIR /home
COPY $benchmark_name /usr/local/bin/$benchmark_name
RUN chmod +x /usr/local/bin/$benchmark_name

CMD ["/usr/local/bin/$benchmark_name"]
EOL

        # Copy the executable to the temporary directory
        cp "$executable" "$temp_dir/$benchmark_name"

        # Build the Docker image
        echo "Building Docker image for $benchmark_name..."
        docker buildx build --platform linux/arm64 -t "tacle-$benchmark_name" "$temp_dir" --load

        # Clean up the temporary directory
        rm -rf "$temp_dir"
    else
        echo "Skipping non-executable file: $executable"
    fi
done

echo "All Docker images have been built."
