/* rt_shim.c - timestamping wrapper installed as /usr/bin/runc
 *
 * Records CLOCK_MONOTONIC the moment "create" is seen on the command line,
 * then execs the real runtime. The log file is opened *before* the timestamp
 * so path resolution stays outside the measured window; only a single
 * write() sits between the timestamp and the exec.
 *
 * OPTIONAL "start" timestamp: if START_MARKER exists, the shim *also* records a
 * timestamp when the OCI "start" command arrives (logged as START). This is
 * opt-in because "start" sits inside the create->booted window, so the extra
 * open+write would perturb the baseline boot time. When the marker is absent
 * the only added cost on a "start" invocation is a single access() syscall.
 * boot_bench.sh -s on/off manages the marker.
 *
 * build:  gcc -O2 -static -o runc rt_shim.c
 */

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define LOGFILE      "/root/container_volume/times.txt"
#define RUNTIME      "/usr/bin/runphi"
#define START_MARKER "/run/rt_measure_start"
/* #define RUNTIME "/usr/bin/runc_vanilla" */

/* Append "<label> <id12> <ns>" to LOGFILE. The container's full id is the last
 * positional argument; its first 12 chars are the hostname we join on. The file
 * is opened *before* the timestamp so path resolution stays out of the measured
 * window; a single write() sits between the timestamp and return. */
static void log_event(const char *label, int argc, char **argv)
{
    struct timespec ts;
    char id[13];
    char line[96];
    int fd, n;

    memset(id, 0, sizeof(id));
    if (argc > 1) strncpy(id, argv[argc - 1], sizeof(id) - 1);

    fd = open(LOGFILE, O_WRONLY | O_CREAT | O_APPEND, 0644);

    clock_gettime(CLOCK_MONOTONIC, &ts);           /* ---- T ---- */

    if (fd >= 0) {
        n = snprintf(line, sizeof(line), "%s %s %lld\n", label, id,
                     (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec);
        if (n > 0) (void)write(fd, line, (size_t)n);
        close(fd);
    }
}

int main(int argc, char **argv)
{
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "create") == 0) {
            log_event("CREATE", argc, argv);
            break;
        }
        if (strcmp(argv[i], "start") == 0) {
            if (access(START_MARKER, F_OK) == 0)
                log_event("START", argc, argv);
            break;
        }
    }

    execv(RUNTIME, argv);
    perror("execv " RUNTIME);
    return 127;
}
