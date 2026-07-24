#!/bin/bash

# Directory to store the compiled executables
elf_dir="executables/elf"
bin_dir="executables/bin"
output_dir="executables/bin2"

# File containing the benchmark names and directory structure
benchmark_file="benchmark_used.txt"

# Variables to track compilation results
total_count=0
success_count=0
failures=()
skipped_lines=0

# Clear previous error log
error_log="compilation_errors.log"
> $error_log

# Clear previous compilation report
compilation_report="compilation_report.txt"
> $compilation_report

# Clear previous executables folder
rm -rf $elf_dir
rm -rf $bin_dir
rm -rf $output_dir

# Create the output directory if it doesn't exist
mkdir -p $elf_dir
mkdir -p $bin_dir
mkdir -p $output_dir

# Function to create a C wrapper
create_wrapper() {
    local benchmark_name=$1
    local benchmark_dir=$2
    local wrapper_file="$benchmark_dir/${benchmark_name}_wrapper.c"

    cat << EOF > "$wrapper_file"
#include <inmate.h>

#define SRC_ADDRESS  0xFF250000  // Memory-mapped source address
#define DST_ADDRESS  0x46D00000  // Memory-mapped destination address

volatile u32 *source = (volatile u32 *)SRC_ADDRESS;
volatile u32 *destination = (volatile u32 *)DST_ADDRESS;

// Declaration of the benchmark function
int ${benchmark_name}_entry(void);

void inmate_main(void) {
    printk("Inmate main\n");    
    u32 start_time = 0, end_time = 0;
    unsigned int timeout;
    *destination = 0x11111111; // Signal that the inmate has started

    // Save start time from the timer memory area
    printk("Inmate main - before source\n");
    start_time = *source;
    if (start_time == 0) {
        *destination = 0xDEAD0000;  // Error code for invalid timer start
        //return -1;
    }
    *destination = start_time;
    printk("Inmate main - after source\n");
    // Run the benchmark
    //printk("Inmate main - before benchmark\n");
    ${benchmark_name}_entry();
    //printk("Inmate main - after benchmark\n");
    // Save end time from the timer memory area
    //printk("Inmate main - before source2\n");
    end_time = *source;
    if (end_time == 0) {
        *destination = 0xDEAD0001;  // Error code for invalid timer end
        //return -1;
    }
    //printk("Inmate main - after source2\n");
    // Wait for synchronization with the root cell script
    timeout = 0xFFFFFF;
    while (*destination != 0xBEEFDEAD && timeout--) {
        //printk("Inmate main - waiting for sync\n");
        __asm__ volatile ("nop");
    }
    if (timeout == 0) {
        *destination = 0xDEAD0002;  // Error code for timeout
        //return -1;
    }
    //printk("Inmate main - after sync\n");
    // Write the end time to the shared memory
    *destination = end_time;
    //printk("Inmate main - after end time\n");
}
EOF
}

LIB_FILES=$(find /home/boccolarg/runphi_project/environment_builder/environment/kria/jailhouse/build/jailhouse/inmates/lib -maxdepth 1 -type f -name "*.c" && \
            find /home/boccolarg/runphi_project/environment_builder/environment/kria/jailhouse/build/jailhouse/inmates/lib/arm-common -maxdepth 1 -type f -name "*.c")

# Read the benchmark file line by line
current_directory=""
while IFS= read -r line; do
    # Trim leading and trailing whitespace and non-standard characters
    line=$(echo "$line" | tr -d '$' | xargs)

    # Skip blank lines
    if [[ -z $line ]]; then
        skipped_lines=$((skipped_lines + 1))
        continue
    fi

    if [[ $line =~ ^[A-Z]+$ ]]; then
        # Capital letters indicate a directory
        current_directory=$(echo "$line" | tr '[:upper:]' '[:lower:]')
    elif [[ $line =~ ^[a-zA-Z0-9_-]+$ ]]; then
        # Matches valid benchmark names with letters, numbers, underscores, or dashes
        benchmark_name=$line
        benchmark_dir="./$current_directory/$benchmark_name"
        
        # Find all .c files in the benchmark's directory (excluding the wrapper)
        benchmark_files=$(find "$benchmark_dir" -maxdepth 1 -type f -name "*.c" ! -name "*_wrapper.c" 2>/dev/null | tr '\n' ' ')

        # Add the wrapper file explicitly at the beginning
        wrapper_file="$benchmark_dir/${benchmark_name}_wrapper.c"

        if [[ -z $benchmark_files ]]; then
            echo "No source files found for $benchmark_name" >> $error_log
            failures+=("$benchmark_name")
            total_count=$((total_count + 1))
            continue
        fi

        # Rename only the function definition in benchmark files
        for benchmark_file in $benchmark_files; do
            sed -i "s/^void[[:space:]]\+${benchmark_name}_entry[[:space:]]*(/int ${benchmark_name}_entry(/" "$benchmark_file"
        done

        # Create C wrapper file
        create_wrapper "$benchmark_name" "$benchmark_dir"

        # Compile the benchmark with the wrapper
        echo "Compiling $benchmark_name with wrapper..."

    # Directories
    lib_dir="/home/boccolarg/runphi_project/environment_builder/environment/kria/jailhouse/build/jailhouse/inmates/lib/arm64"
    jailhouse_dir="/home/boccolarg/runphi_project/environment_builder/environment/kria/jailhouse/build/jailhouse"

    # Verify source files exist before compiling
    for src_file in "$wrapper_file" $benchmark_files; do
        if [[ ! -f "$src_file" ]]; then
            echo "Error: Source file $src_file not found!" >> $error_log
            exit 1
        fi
    done

    #Removed -Wstrict-prototypes, -Wmissing-prototypes, -Wmissing-declarations from compiler call
    # Step 1: Compile the .o object file
    # Compile each source file into its own .o file
    for src_file in "$wrapper_file" $benchmark_files; do
        # Extract the base name of the source file (e.g., "file.c" -> "file")
        src_basename=$(basename "$src_file" .c)

        aarch64-linux-gnu-gcc \
            -Wp,-MMD,"${output_dir}/${src_basename}.o.d" \
            -nostdinc \
            -I${lib_dir} \
            -I${lib_dir}/../arm-common/include \
            -I${lib_dir}/../include \
            -I${lib_dir}/include \
            -I${jailhouse_dir}/include \
            -I${jailhouse_dir}/include/jailhouse \
            -I${jailhouse_dir}/include/arch/arm \
            -I${jailhouse_dir}/include/arch/arm64 \
            -I${jailhouse_dir}/include/arch/arm-common \
            -I${jailhouse_dir}/include/arch/x86 \
            -include ./compiler_types.h \
            -D__KERNEL__ \
            -mlittle-endian \
            -DKASAN_SHADOW_SCALE_SHIFT= \
            -fmacro-prefix-map=./= \
            -g -Os \
            -Werror -Wall -Wtype-limits \
            -fno-strict-aliasing -fomit-frame-pointer -fno-pic -fno-common \
            -fno-stack-protector -ffreestanding -ffunction-sections \
            -Wno-unknown-pragmas -Wno-error=unused-variable -Wno-error=maybe-uninitialized \
            -D__LINUX_COMPILER_TYPES_H \
            -include /home/boccolarg/runphi_project/environment_builder/environment/kria/jailhouse/build/jailhouse/include/jailhouse/config.h \
            -DKBUILD_MODFILE="\"${output_dir}/${benchmark_name}\"" \
            -DKBUILD_BASENAME="\"${benchmark_name}\"" \
            -DKBUILD_MODNAME="\"${benchmark_name}\"" \
            -D__KBUILD_MODNAME=kmod_${benchmark_name} \
            -c -o "${output_dir}/${src_basename}.o" \
            "$src_file" 2>> $error_log
    done

    # Step 2: Link the .o file to create the -linked.o object file
    aarch64-linux-gnu-ld \
    -EL \
    -maarch64elf \
    -z noexecstack \
    --gc-sections \
    -T ${lib_dir}/inmate.lds \
    "${output_dir}/${benchmark_name}_wrapper.o" \
    $(for src_file in $benchmark_files; do
        src_basename=$(basename "$src_file" .c)
        echo "${output_dir}/${src_basename}.o"
    done) \
    "${lib_dir}/lib.a" \
    -o "${output_dir}/${benchmark_name}-linked.o" 2>> $error_log

    # Step 3: Convert the linked object file to a binary file
    aarch64-linux-gnu-objcopy \
        -O binary \
        --remove-section=.note.gnu.property \
        "${output_dir}/${benchmark_name}-linked.o" \
        "${output_dir}/${benchmark_name}.bin" 2>> $error_log

    # Check if compilation was successful
        if [[ $? -eq 0 ]]; then
            success_count=$((success_count + 1))
        else
            failures+=("$benchmark_name")
        fi

        total_count=$((total_count + 1))
    else
        # Skip any lines that do not match expected formats
        echo "Skipping unrecognized line: $line" >> $error_log
        skipped_lines=$((skipped_lines + 1))
    fi

done < $benchmark_file

# Generate report
echo "Compilation Report:"
echo "-------------------"
echo "Total benchmarks: $total_count"
echo "Successful compilations: $success_count"
echo "Failed compilations: ${#failures[@]}"
if [[ ${#failures[@]} -gt 0 ]]; then
    echo "Benchmarks that failed to compile:"
    for failed_benchmark in "${failures[@]}"; do
        echo "  - $failed_benchmark"
    done
fi

echo "Skipped lines: $skipped_lines"

# Save the report to a file
report_file="compilation_report.txt"
{
    echo "Compilation Report:"
    echo "-------------------"
    echo "Total benchmarks: $total_count"
    echo "Successful compilations: $success_count"
    echo "Failed compilations: ${#failures[@]}"
    if [[ ${#failures[@]} -gt 0 ]]; then
        echo "Benchmarks that failed to compile:"
        for failed_benchmark in "${failures[@]}"; do
            echo "  - $failed_benchmark"
        done
    fi
    echo "Skipped lines: $skipped_lines"
} > $report_file

echo "Report saved to $report_file"
echo "Compilation errors saved to $error_log"

# Cleanup: Remove logs if there are no errors and no skipped lines
if [[ ${#failures[@]} -eq 0 && $skipped_lines -eq 0 ]]; then
    echo "No errors or skipped lines. Cleaning up logs..."
    rm -f compilation_errors.log compilation_report.txt
    echo "Cleanup complete."
fi
