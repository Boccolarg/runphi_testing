#!/usr/bin/env bash
# ==============================================================================
# M4 Benchmark Suite: Automated Reboot Orchestrator (Ubuntu / GRUB)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.bench_state"
LOG_FILE="$SCRIPT_DIR/orchestrator.log"

log() {
    echo -e "\033[1;36m[ORCHESTRATOR]\033[0m $(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

reboot_rt() {
    log "Sincronizzazione filesystem e riavvio su kernel RT (GRUB entry 0)..."
    sudo grub-reboot 0 2>/dev/null || true
    sync
    sleep 2
    systemctl reboot
}

# 1. Lettura o inizializzazione dello stato
if [ ! -f "$STATE_FILE" ]; then
    echo "STEADY" > "$STATE_FILE"
fi
CURRENT_STEP=$(cat "$STATE_FILE")

log "Fase corrente rilevata: $CURRENT_STEP"

# 2. Esecuzione del tuning hardware
log "Preparazione host..."
bash "$SCRIPT_DIR/prepare_host.sh"

# 3. Stabilizzazione termica post-boot
log "Attesa di 30s per la stabilizzazione dei servizi di background e delle ventole..."
sleep 30

# 4. Macchina a stati (Riavvio dedicato tra ogni singolo esperimento)
case "$CURRENT_STEP" in
    "STEADY")
        log ">>> AVVIO ESPERIMENTO 1/12: STEADY-STATE BASELINE <<<"
        "$SCRIPT_DIR/run_no_interference.sh"
        echo "LIFECYCLE_COLD" > "$STATE_FILE"
        sync
        log "Test Steady completato. Riavvio programmato tra 5 secondi..."
        sleep 5
        reboot_rt
        ;;

    "LIFECYCLE"|"LIFECYCLE_COLD")
        log ">>> AVVIO ESPERIMENTO 2/9: LIFECYCLE LATENCY (COLD CACHE) <<<"
        "$SCRIPT_DIR/run_latency_start_stop.sh" cold
        echo "LIFECYCLE_WARM" > "$STATE_FILE"
        sync
        log "Test Lifecycle Cold completato. Riavvio programmato tra 5 secondi..."
        sleep 5
        reboot_rt
        ;;

    "LIFECYCLE_WARM")
        log ">>> AVVIO ESPERIMENTO 3/9: LIFECYCLE LATENCY (WARM CACHE) <<<"
        "$SCRIPT_DIR/run_latency_start_stop.sh" warm
        echo "CPU_MATRIXPROD" > "$STATE_FILE"
        sync
        log "Test Lifecycle Warm completato. Riavvio programmato tra 5 secondi..."
        sleep 5
        reboot_rt
        ;;

    "CPU"|"CPU_MATRIXPROD")
        log ">>> AVVIO ESPERIMENTO 4/9: NOISY NEIGHBOR - CPU STRESS (MATRIXPROD) <<<"
        "$SCRIPT_DIR/run_cpu_stress.sh" matrixprod
        echo "CPU_CALLFUNC" > "$STATE_FILE"
        sync
        log "Test CPU Matrixprod completato. Riavvio programmato tra 5 secondi..."
        sleep 5
        reboot_rt
        ;;

    "CPU_CALLFUNC")
        log ">>> AVVIO ESPERIMENTO 5/9: NOISY NEIGHBOR - CPU STRESS (CALLFUNC) <<<"
        "$SCRIPT_DIR/run_cpu_stress.sh" callfunc
        echo "CPU_IRQ" > "$STATE_FILE"
        sync
        log "Test CPU Callfunc completato. Riavvio programmato tra 5 secondi..."
        sleep 5
        reboot_rt
        ;;

    "CPU_IRQ")
        log ">>> AVVIO ESPERIMENTO 6/10: NOISY NEIGHBOR - CPU STRESS (IRQ) <<<"
        "$SCRIPT_DIR/run_cpu_stress.sh" irq
        echo "MEM_MEMCPY" > "$STATE_FILE"
        sync
        log "Test CPU IRQ completato. Riavvio programmato tra 5 secondi..."
        sleep 5
        reboot_rt
        ;;

    "MEM"|"MEM_MEMCPY")
        log ">>> AVVIO ESPERIMENTO 7/10: NOISY NEIGHBOR - MEMORY STRESS (MEMCPY) <<<"
        "$SCRIPT_DIR/run_mem_stress.sh" memcpy
        echo "MEM_TLB_SHOOTDOWN" > "$STATE_FILE"
        sync
        log "Test Mem Memcpy completato. Riavvio programmato tra 5 secondi..."
        sleep 5
        reboot_rt
        ;;

    "MEM_TLB_SHOOTDOWN")
        log ">>> AVVIO ESPERIMENTO 8/10: NOISY NEIGHBOR - MEMORY STRESS (TLB SHOOTDOWN) <<<"
        "$SCRIPT_DIR/run_mem_stress.sh" tlb_shootdown
        echo "MEM_STREAM" > "$STATE_FILE"
        sync
        log "Test Mem TLB-Shootdown completato. Riavvio programmato tra 5 secondi..."
        sleep 5
        reboot_rt
        ;;

    "MEM_STREAM")
        log ">>> AVVIO ESPERIMENTO 8/10: NOISY NEIGHBOR - MEMORY STRESS (STREAM) <<<"
        "$SCRIPT_DIR/run_mem_stress.sh" stream
        echo "IO_HDD_SYNC" > "$STATE_FILE"
        sync
        log "Test Mem Stream completato. Riavvio programmato tra 5 secondi..."
        sleep 5
        reboot_rt
        ;;

    "IO"|"IO_HDD_SYNC")
        log ">>> AVVIO ESPERIMENTO 9/10: NOISY NEIGHBOR - I/O STRESS (HDD SYNC) <<<"
        "$SCRIPT_DIR/run_io_stress.sh" hdd_sync
        echo "IO_IO_URING" > "$STATE_FILE"
        sync
        log "Test I/O HDD Sync completato. Riavvio programmato tra 5 secondi..."
        sleep 5
        reboot_rt
        ;;

    "IO_IO_URING")
        log ">>> AVVIO ESPERIMENTO 10/10: NOISY NEIGHBOR - I/O STRESS (IO_URING) <<<"
        "$SCRIPT_DIR/run_io_stress.sh" io_uring
        echo "IO_SOCKET" > "$STATE_FILE"
        sync
        log "Test I/O io_uring completato. Riavvio programmato tra 5 secondi..."
        sleep 5
        reboot_rt
        ;;

    "IO_SOCKET")
        log ">>> AVVIO ESPERIMENTO 10/10: NOISY NEIGHBOR - I/O STRESS (SOCKET) <<<"
        "$SCRIPT_DIR/run_io_stress.sh" socket
        echo "DONE" > "$STATE_FILE"
        sync
        log "Test I/O socket completato. TUTTI I BENCHMARK SONO STATI COMPLETATI CON SUCCESSO!"
        systemctl disable m4-bench.service || true
        log "Servizio m4-bench disabilitato con successo."
        sync
        log "Spegnimento..."
        shutdown -h now
        ;;

    "DONE")
        log "Tutte le campagne sono già state completate. Nessuna azione da eseguire."
        ;;

    *)
        log "Stato sconosciuto: $CURRENT_STEP. Arresto precauzionale."
        exit 1
        ;;
esac