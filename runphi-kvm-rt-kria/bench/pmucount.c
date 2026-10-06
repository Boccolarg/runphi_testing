/*
 * pmucount - count Cortex-A53 PMU events on every CPU, kernel and user,
 * from start until SIGTERM/SIGINT, then print one JSON object
 * {"cpu0": {"enabled_ns": ..., "running_ns": ..., "<event>": n, ...}, ...}.
 * Counting only: no sampling, no interrupts on the measured CPUs. Used by
 * order_probe.py around each runc run (the board has no perf).
 *
 * Build on the workstation (static, the board has no libc headers):
 *   aarch64-linux-gnu-gcc -O2 -static -o pmucount bench/pmucount.c
 * and copy it to /root/rtbench/bin/pmucount on the board.
 */
#include <linux/perf_event.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

static const struct {
	const char *name;
	unsigned config;
} EV[] = {
	/* group leader: the A53's dedicated cycle counter, then its 6 counters */
	{"cpu_cycles", 0x11},
	{"inst_retired", 0x08},
	{"l1d_tlb_refill", 0x05},
	{"l1i_tlb_refill", 0x02},
	{"l2d_cache_refill", 0x17},
	{"exc_taken", 0x09},
	{"stall_load_miss", 0xe7}, /* A53 IMPDEF: Wr-stage stall cycles, load miss */
};
#define NEV (sizeof(EV) / sizeof(EV[0]))
#define NCPU 4

static volatile sig_atomic_t stop;

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

static int open_event(int type, unsigned config, int cpu, int leader)
{
	struct perf_event_attr a;

	memset(&a, 0, sizeof(a));
	a.size = sizeof(a);
	a.type = type;
	a.config = config;
	a.disabled = leader < 0;
	a.pinned = leader < 0;
	a.read_format = PERF_FORMAT_GROUP | PERF_FORMAT_TOTAL_TIME_ENABLED |
			PERF_FORMAT_TOTAL_TIME_RUNNING;
	return syscall(SYS_perf_event_open, &a, -1, cpu, leader, 0);
}

int main(void)
{
	struct {
		uint64_t nr, enabled, running, value[NEV];
	} r;
	int fd[NCPU][NEV], type, cpu;
	unsigned i;
	FILE *f = fopen("/sys/bus/event_source/devices/armv8_pmuv3/type", "r");

	if (!f || fscanf(f, "%d", &type) != 1) {
		perror("armv8_pmuv3 type");
		return 1;
	}
	fclose(f);
	for (cpu = 0; cpu < NCPU; cpu++)
		for (i = 0; i < NEV; i++) {
			fd[cpu][i] = open_event(type, EV[i].config, cpu, i ? fd[cpu][0] : -1);
			if (fd[cpu][i] < 0) {
				fprintf(stderr, "cpu %d %s: ", cpu, EV[i].name);
				perror("perf_event_open");
				return 1;
			}
		}
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	for (cpu = 0; cpu < NCPU; cpu++) {
		ioctl(fd[cpu][0], PERF_EVENT_IOC_RESET, PERF_IOC_FLAG_GROUP);
		ioctl(fd[cpu][0], PERF_EVENT_IOC_ENABLE, PERF_IOC_FLAG_GROUP);
	}
	while (!stop)
		sleep(1);
	for (cpu = 0; cpu < NCPU; cpu++)
		ioctl(fd[cpu][0], PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP);
	printf("{");
	for (cpu = 0; cpu < NCPU; cpu++) {
		if (read(fd[cpu][0], &r, sizeof(r)) != sizeof(r) || r.nr != NEV) {
			fprintf(stderr, "cpu %d: short read\n", cpu);
			return 1;
		}
		printf("%s\"cpu%d\": {\"enabled_ns\": %llu, \"running_ns\": %llu", cpu ? ", " : "",
		       cpu, (unsigned long long)r.enabled, (unsigned long long)r.running);
		for (i = 0; i < NEV; i++)
			printf(", \"%s\": %llu", EV[i].name, (unsigned long long)r.value[i]);
		printf("}");
	}
	printf("}\n");
	return 0;
}
