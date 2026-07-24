/* booted.c - PID 1 inside the container; records CLOCK_MONOTONIC.
 *
 * MUST be statically linked: it runs inside the alpine rootfs (musl) but is
 * built with the Buildroot toolchain.
 *
 * build:  gcc -O2 -static -o booted booted.c
 */

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define LOGFILE "/home/times.txt"

int main(void)
{
    struct timespec ts;
    char host[64];
    char line[96];
    int fd, n;

    clock_gettime(CLOCK_MONOTONIC, &ts);               /* ---- T1, first thing ---- */

    memset(host, 0, sizeof(host));
    gethostname(host, sizeof(host) - 1);

    fd = open(LOGFILE, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return 1;

    n = snprintf(line, sizeof(line), "BOOTED %s %lld\n", host,
                 (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec);
    if (n > 0) (void)write(fd, line, (size_t)n);
    close(fd);
    return 0;
}
