#!/bin/bash
# compile_all_benchmarks.sh
#
# This script iterates over every folder in the bench directory, invokes the
# jailhouse_compile.sh script with -r armr5 and -B <benchmark> for each folder,
# and then copies the produced <benchmark>-demo.elf file into /home/taclebench_elfs.
# If any step fails, an error is printed to the user.

# Directory where benchmark source folders are located.
BENCH_DIR="/home/environment/kria/jailhouse/build/jailhouse/inmates/demos/armr5/src_rpu0-taclebench/bench"
# Directory where the resulting ELF files are produced.
ELF_OUTPUT_DIR="/home/environment/kria/jailhouse/build/jailhouse/inmates/demos/armr5/src_rpu0-taclebench"
# Directory where we want to save the ELF files permanently.
DEST_DIR="/home/taclebench_elfs"

# Path to the compile script.
JAILHOUSE_SCRIPT="./jailhouse_compile.sh"

# Ensure the destination directory exists.
mkdir -p "$DEST_DIR" || { echo "ERROR: Cannot create destination directory $DEST_DIR"; exit 1; }

# Check that the jailhouse_compile.sh script exists and is executable.
if [ ! -x "$JAILHOUSE_SCRIPT" ]; then
    echo "ERROR: $JAILHOUSE_SCRIPT not found or not executable."
    exit 1
fi

# Loop over each subdirectory (benchmark) in BENCH_DIR.
for bench_path in "$BENCH_DIR"/*; do
    if [ -d "$bench_path" ]; then
        # Use the folder name as the benchmark name.
        bench_name=$(basename "$bench_path")
        echo "----------------------------------------------"
        echo "Compiling benchmark: $bench_name"

        # Call the compile script with the -r and -B options.
        $JAILHOUSE_SCRIPT -r armr5 -B "$bench_name"
        compile_status=$?
        if [ $compile_status -ne 0 ]; then
            echo "ERROR: Compilation script failed for benchmark '$bench_name' (exit code $compile_status)."
            continue
        fi

        # Define the expected ELF file path.
        elf_file="${ELF_OUTPUT_DIR}/${bench_name}-demo.elf"
        if [ ! -f "$elf_file" ]; then
            echo "ERROR: Expected ELF file '$elf_file' not found for benchmark '$bench_name'."
            continue
        fi

        # Copy the ELF file to the destination directory.
        cp "$elf_file" "$DEST_DIR/"
        if [ $? -ne 0 ]; then
            echo "ERROR: Failed to copy '$elf_file' to '$DEST_DIR'."
            continue
        fi

        echo "Benchmark '$bench_name' compiled successfully and ELF file copied to '$DEST_DIR'."
    fi
done

echo "----------------------------------------------"
echo "All benchmarks processed."
