#!/bin/bash
#
# Build the TACLeBench suite as Jailhouse AArch64 bare-metal inmates.
#
# Each benchmark's main() is renamed to <name>_entry() and a generated wrapper
# provides inmate_main(), which timestamps the run from the ZynqMP system
# counter and hands the values to the root cell through a shared memory word.
# See external_script_shmem.sh for the other half of the handshake.
#
# Output:
#   $OUTPUT_DIR/bin/<name>.bin   raw binaries to load with `jailhouse cell load`
#   $OUTPUT_DIR/obj/             intermediate objects and linked ELFs
#
# Usage: ./compile_benchmark_wrap.sh [-b bench1 bench2 ...]

set -u

# ---------------------------------------------------------------- board config
# Jailhouse build tree providing the inmate library, headers and linker script.
JAILHOUSE_BUILD="${JAILHOUSE_BUILD:-/home/boccolarg/runphi/environment_builder/environment/zcu104/jailhouse/build/jailhouse}"

# Addresses must match the inmate cell configuration
# (custom_build/jailhouse/configs/arm64/zynqmp-zcu104-APU-inmate-demo.c).
SYSTEM_COUNTER_ADDR="0xFF250000"   # ZynqMP system counter, read aperture, 100 MHz
SHARED_MEMORY_ADDR="0x3AD00000"    # 1-word mailbox shared with the root cell

# Thin archives built inside a container record their members under
# /home/environment/...; rewrite that prefix to reach them on this host.
CONTAINER_PREFIX="/home/environment/"
HOST_PREFIX="/home/boccolarg/runphi/environment_builder/environment/"

OUTPUT_DIR="executables_shm"
BENCHMARK_FILE="benchmark_used.txt"
# -----------------------------------------------------------------------------

LIB_DIR="${JAILHOUSE_BUILD}/inmates/lib/arm64"
BIN_DIR="${OUTPUT_DIR}/bin"
OBJ_DIR="${OUTPUT_DIR}/obj"
ERROR_LOG="compilation_errors.log"
REPORT_FILE="compilation_report.txt"

SELECTED_BENCHMARKS=()
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0 [-b bench1 bench2 ...]"
    echo "  -b   build only the listed benchmarks instead of all of $BENCHMARK_FILE"
    exit 0
elif [[ "${1:-}" == "-b" ]]; then
    shift
    SELECTED_BENCHMARKS=("$@")
fi

total_count=0
success_count=0
failures=()

: > "$ERROR_LOG"
: > "$REPORT_FILE"
rm -rf "$OUTPUT_DIR"
mkdir -p "$BIN_DIR" "$OBJ_DIR"

# ---------------------------------------------------------------------------
# The inmate library ships as a *thin* archive whose member paths point inside
# the build container. Repack it as a regular archive so ld can find them.
# ---------------------------------------------------------------------------
FIXED_LIB="${OBJ_DIR}/libinmate.a"

prepare_inmate_lib() {
    local thin="${LIB_DIR}/lib.a"

    if [[ ! -f $thin ]]; then
        echo "Error: inmate library $thin not found." >&2
        exit 1
    fi

    if [[ $(head -c 8 "$thin") != '!<thin>' ]]; then
        cp "$thin" "$FIXED_LIB"
        echo "Inmate library is a regular archive, used as is."
        return
    fi

    local members
    members=$(python3 - "$thin" <<'PYEOF'
import sys
data = open(sys.argv[1], 'rb').read()
off, longnames, names = 8, b'', []
while off + 60 <= len(data):
    header = data[off:off + 60]
    name = header[0:16].decode('ascii', 'replace')
    size = int(header[48:58].decode().strip() or 0)
    if name.startswith('// '):                  # long name table
        longnames = data[off + 60:off + 60 + size]
        off += 60 + size + (size % 2)
        continue
    if name.startswith('/ '):                   # symbol table
        off += 60 + size + (size % 2)
        continue
    if name.startswith('/'):
        i = int(name[1:].strip())
        names.append(longnames[i:longnames.find(b'/\n', i)].decode())
    off += 60                                   # thin members carry no payload
print('\n'.join(names))
PYEOF
    )

    if [[ -z $members ]]; then
        echo "Error: could not read any member from the thin archive $thin." >&2
        exit 1
    fi

    members=$(sed "s|^${CONTAINER_PREFIX}|${HOST_PREFIX}|" <<< "$members")

    local missing=()
    while read -r m; do
        [[ -f $m ]] || missing+=("$m")
    done <<< "$members"

    if (( ${#missing[@]} > 0 )); then
        echo "Error: ${#missing[@]} archive members are missing on this host:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        echo "Rebuild the Jailhouse inmate library, or fix CONTAINER_PREFIX/HOST_PREFIX." >&2
        exit 1
    fi

    # shellcheck disable=SC2046
    aarch64-linux-gnu-ar rcs "$FIXED_LIB" $(echo "$members")
    echo "Repacked $(wc -l <<< "$members") thin-archive members into $FIXED_LIB."
}

# Generate the timing wrapper that becomes the inmate entry point.
create_wrapper() {
    local benchmark_name=$1
    local benchmark_dir=$2

    cat > "${benchmark_dir}/${benchmark_name}_wrapper.c" <<EOF
#include <inmate.h>

#define SYSTEM_COUNTER  ${SYSTEM_COUNTER_ADDR}  // Memory-mapped system_counter address
#define SHARED_MEMORY   ${SHARED_MEMORY_ADDR}  // Memory-mapped shared_memory address

volatile u32 *system_counter = (volatile u32 *)SYSTEM_COUNTER;
volatile u32 *shared_memory = (volatile u32 *)SHARED_MEMORY;

// Declaration of the benchmark function
int ${benchmark_name}_entry(void);

void inmate_main(void) {
    map_range((void *)system_counter, 4, MAP_UNCACHED);
    map_range((void *)shared_memory, 4, MAP_UNCACHED);
    u32 start_time = 0, end_time = 0;
    // Save start time from the timer memory area
    start_time = *system_counter;
    *shared_memory = start_time;
    // Run the benchmark
    ${benchmark_name}_entry();
    // Save end time from the timer memory area
    end_time = *system_counter;
    // Wait for synchronization with the root cell script
    while (*shared_memory != 0xBEEFDEAD) {
        __asm__ volatile ("nop");
    }
    // Write the end time to the shared memory
    *shared_memory = end_time;
}
EOF
}

# -O0: the experiment measures unoptimised code on purpose, do not raise this.
compile_one() {
    local src_file=$1 obj_file=$2 benchmark_name=$3

    aarch64-linux-gnu-gcc \
        -Wp,-MMD,"${obj_file}.d" \
        -nostdinc \
        -I"${LIB_DIR}" \
        -I"${LIB_DIR}/../arm-common/include" \
        -I"${LIB_DIR}/../include" \
        -I"${LIB_DIR}/include" \
        -I"${JAILHOUSE_BUILD}/include" \
        -I"${JAILHOUSE_BUILD}/include/jailhouse" \
        -I"${JAILHOUSE_BUILD}/include/arch/arm" \
        -I"${JAILHOUSE_BUILD}/include/arch/arm64" \
        -I"${JAILHOUSE_BUILD}/include/arch/arm-common" \
        -include ./compiler_types.h \
        -D__KERNEL__ \
        -mlittle-endian \
        -DKASAN_SHADOW_SCALE_SHIFT= \
        -fmacro-prefix-map=./= \
        -g -O0 \
        -Werror -Wall -Wtype-limits \
        -fno-strict-aliasing -fomit-frame-pointer -fno-pic -fno-common \
        -fno-stack-protector -ffreestanding -ffunction-sections \
        -Wno-unknown-pragmas -Wno-error=unused-variable -Wno-error=maybe-uninitialized \
        -D__LINUX_COMPILER_TYPES_H \
        -include ./config.h \
        -DKBUILD_MODFILE="\"${benchmark_name}\"" \
        -DKBUILD_BASENAME="\"${benchmark_name}\"" \
        -DKBUILD_MODNAME="\"${benchmark_name}\"" \
        -D__KBUILD_MODNAME=kmod_${benchmark_name} \
        -c -o "$obj_file" "$src_file" 2>> "$ERROR_LOG"
}

build_benchmark() {
    local benchmark_name=$1 benchmark_dir=$2
    local wrapper_file="${benchmark_dir}/${benchmark_name}_wrapper.c"

    local benchmark_files
    benchmark_files=$(find "$benchmark_dir" -maxdepth 1 -type f -name "*.c" ! -name "*_wrapper.c" 2>/dev/null)

    if [[ -z $benchmark_files ]]; then
        echo "[$benchmark_name] no source files found in $benchmark_dir" >> "$ERROR_LOG"
        return 1
    fi

    # main() -> <name>_entry(); a no-op once the sources have been converted.
    while read -r src; do
        sed -i -E "s/^(\s*)int\s+main\s*\(\s*void\s*\)/\1int ${benchmark_name}_entry(void)/" "$src"
    done <<< "$benchmark_files"

    if ! grep -rqE "^\s*int\s+${benchmark_name}_entry\s*\(\s*void\s*\)" "$benchmark_dir"; then
        echo "[$benchmark_name] no ${benchmark_name}_entry(void) definition: the main() signature" \
             "differs from 'int main(void)' and must be renamed by hand" >> "$ERROR_LOG"
        return 1
    fi

    create_wrapper "$benchmark_name" "$benchmark_dir"

    local objects=("${OBJ_DIR}/${benchmark_name}_wrapper.o")
    if ! compile_one "$wrapper_file" "${OBJ_DIR}/${benchmark_name}_wrapper.o" "$benchmark_name"; then
        echo "[$benchmark_name] failed to compile the wrapper" >> "$ERROR_LOG"
        return 1
    fi

    while read -r src; do
        local obj="${OBJ_DIR}/${benchmark_name}__$(basename "$src" .c).o"
        if ! compile_one "$src" "$obj" "$benchmark_name"; then
            echo "[$benchmark_name] failed to compile $src" >> "$ERROR_LOG"
            return 1
        fi
        objects+=("$obj")
    done <<< "$benchmark_files"

    if ! aarch64-linux-gnu-ld \
            -EL \
            -maarch64elf \
            -z noexecstack \
            --gc-sections \
            -T "${LIB_DIR}/inmate.lds" \
            "${objects[@]}" \
            "$FIXED_LIB" \
            -o "${OBJ_DIR}/${benchmark_name}-linked.o" 2>> "$ERROR_LOG"; then
        echo "[$benchmark_name] link failed" >> "$ERROR_LOG"
        return 1
    fi

    if ! aarch64-linux-gnu-objcopy \
            -O binary \
            --remove-section=.note.gnu.property \
            "${OBJ_DIR}/${benchmark_name}-linked.o" \
            "${BIN_DIR}/${benchmark_name}.bin" 2>> "$ERROR_LOG"; then
        echo "[$benchmark_name] objcopy failed" >> "$ERROR_LOG"
        return 1
    fi

    [[ -s "${BIN_DIR}/${benchmark_name}.bin" ]]
}

prepare_inmate_lib

# benchmark_used.txt lists an upper-case directory name followed by the
# benchmarks it contains.
current_directory=""
while IFS= read -r line; do
    line=$(tr -d '$' <<< "$line" | xargs)
    [[ -z $line ]] && continue

    if [[ $line =~ ^[A-Z]+$ ]]; then
        current_directory=$(tr '[:upper:]' '[:lower:]' <<< "$line")
        continue
    fi

    if [[ ! $line =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Skipping unrecognized line: $line" >> "$ERROR_LOG"
        continue
    fi

    if (( ${#SELECTED_BENCHMARKS[@]} > 0 )); then
        printf '%s\n' "${SELECTED_BENCHMARKS[@]}" | grep -qx "$line" || continue
    fi

    total_count=$((total_count + 1))
    echo "Compiling $line..."
    if build_benchmark "$line" "./${current_directory}/${line}"; then
        success_count=$((success_count + 1))
    else
        failures+=("$line")
        echo "  FAILED (see $ERROR_LOG)"
    fi
done < "$BENCHMARK_FILE"

{
    echo "Compilation Report:"
    echo "-------------------"
    echo "Jailhouse build:  $JAILHOUSE_BUILD"
    echo "System counter:   $SYSTEM_COUNTER_ADDR"
    echo "Shared memory:    $SHARED_MEMORY_ADDR"
    echo "Binaries:         $BIN_DIR"
    echo
    echo "Total benchmarks: $total_count"
    echo "Successful compilations: $success_count"
    echo "Failed compilations: ${#failures[@]}"
    if (( ${#failures[@]} > 0 )); then
        echo "Benchmarks that failed to compile:"
        printf '  - %s\n' "${failures[@]}"
    fi
} | tee "$REPORT_FILE"

echo
echo "Report saved to $REPORT_FILE"
echo "Compiler diagnostics in $ERROR_LOG"

(( ${#failures[@]} == 0 ))
