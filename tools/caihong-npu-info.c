// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
/* Report Qualcomm CDSP/FastRPC readiness without starting an NPU workload. */

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define FASTRPC_MAX_DSP_ATTRIBUTES 256U

struct fastrpc_ioctl_capability {
	uint32_t unused;
	uint32_t attribute_id;
	uint32_t capability;
	uint32_t reserved[4];
};

#define FASTRPC_IOCTL_GET_DSP_INFO \
	_IOWR('R', 13, struct fastrpc_ioctl_capability)

#define CDSP_DOMAIN_ID 3
#define NPU_TEST_VECTOR_LENGTH 1000

typedef int (*npu_test_fn)(int domain_id, bool unsigned_pd);

static int read_line(const char *path, char *buffer, size_t size)
{
	FILE *file;

	file = fopen(path, "re");
	if (!file)
		return -1;
	if (!fgets(buffer, size, file)) {
		fclose(file);
		return -1;
	}
	fclose(file);
	buffer[strcspn(buffer, "\r\n")] = '\0';
	return 0;
}

static bool remoteproc_path(char *path, size_t size, const char *remoteproc,
			    const char *attribute)
{
	int length;

	length = snprintf(path, size, "/sys/class/remoteproc/%s/%s",
			  remoteproc, attribute);
	return length >= 0 && (size_t)length < size;
}

static void show_remoteprocs(void)
{
	struct dirent *entry;
	char firmware[PATH_MAX];
	char path[PATH_MAX];
	char state[64];
	char name[64];
	DIR *directory;

	directory = opendir("/sys/class/remoteproc");
	if (!directory) {
		printf("remoteproc: unavailable (%s)\n", strerror(errno));
		return;
	}

	while ((entry = readdir(directory))) {
		if (strncmp(entry->d_name, "remoteproc", 10))
			continue;

		if (!remoteproc_path(path, sizeof(path), entry->d_name, "name"))
			continue;
		if (read_line(path, name, sizeof(name)))
			continue;
		if (strcmp(name, "cdsp") && strcmp(name, "adsp"))
			continue;

		if (!remoteproc_path(path, sizeof(path), entry->d_name, "state"))
			continue;
		if (read_line(path, state, sizeof(state)))
			strcpy(state, "unknown");
		if (!remoteproc_path(path, sizeof(path), entry->d_name,
				     "firmware"))
			continue;
		if (read_line(path, firmware, sizeof(firmware)))
			strcpy(firmware, "unknown");

		printf("remoteproc %s: state=%s firmware=%s\n",
		       name, state, firmware);
	}
	closedir(directory);
}

static const char *capability_name(unsigned int attribute)
{
	switch (attribute) {
	case 9:
		return "async-fastrpc";
	case 129:
		return "dma-handle-reverse-rpc";
	default:
		return NULL;
	}
}

static int probe_device(const char *path)
{
	struct fastrpc_ioctl_capability capability = { 0 };
	unsigned int attribute;
	bool found = false;
	int fd;

	fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		printf("%s: unavailable (%s)\n", path, strerror(errno));
		return -1;
	}

	printf("%s capabilities:", path);
	for (attribute = 0; attribute < FASTRPC_MAX_DSP_ATTRIBUTES;
	     attribute++) {
		const char *name;

		memset(&capability, 0, sizeof(capability));
		capability.attribute_id = attribute;
		if (ioctl(fd, FASTRPC_IOCTL_GET_DSP_INFO, &capability)) {
			printf(" query-failed=%s\n", strerror(errno));
			close(fd);
			return -1;
		}
		if (!capability.capability)
			continue;

		name = capability_name(attribute);
		if (name)
			printf(" %u=%u(%s)", attribute, capability.capability,
			       name);
		else
			printf(" %u=%u", attribute, capability.capability);
		found = true;
	}
	printf("%s\n", found ? "" : " none");
	close(fd);
	return 0;
}

static const char *first_readable(const char *const *paths, size_t count)
{
	size_t i;

	for (i = 0; i < count; i++)
		if (!access(paths[i], R_OK))
			return paths[i];
	return NULL;
}

static int prepend_dsp_path(const char *path)
{
	const char *current = getenv("DSP_LIBRARY_PATH");
	char paths[PATH_MAX * 2];
	int length;

	if (current && current[0])
		length = snprintf(paths, sizeof(paths), "%s;%s", path, current);
	else
		length = snprintf(paths, sizeof(paths), "%s", path);
	if (length < 0 || (size_t)length >= sizeof(paths)) {
		fprintf(stderr, "DSP library path is too long\n");
		return -1;
	}
	if (setenv("DSP_LIBRARY_PATH", paths, 1)) {
		fprintf(stderr, "cannot set DSP_LIBRARY_PATH: %s\n",
			strerror(errno));
		return -1;
	}
	return 0;
}

static int run_self_test(void)
{
	static const char *const default_libraries[] = {
		"/usr/lib/caihong-npu/libcalculator.so",
		"/usr/lib64/caihong-npu/libcalculator.so",
	};
	static const char *const default_dsp_paths[] = {
		"/usr/share/caihong-npu/dsp/v75",
	};
	const char *library = getenv("CAIHONG_NPU_TEST_LIBRARY");
	const char *dsp_path = getenv("CAIHONG_NPU_DSP_PATH");
	npu_test_fn test = NULL;
	void *handle;
	int result;

	if (!library || !library[0])
		library = first_readable(default_libraries,
					 sizeof(default_libraries) /
					 sizeof(default_libraries[0]));
	if (!dsp_path || !dsp_path[0])
		dsp_path = first_readable(default_dsp_paths,
					 sizeof(default_dsp_paths) /
					 sizeof(default_dsp_paths[0]));
	if (!library || !dsp_path) {
		fprintf(stderr,
			"self-test assets are missing; reinstall the Caihong FastRPC runtime\n");
		return 1;
	}
	if (geteuid()) {
		fprintf(stderr,
			"self-test requires root access to /dev/fastrpc-cdsp\n");
		return 1;
	}
	if (prepend_dsp_path(dsp_path))
		return 1;

	handle = dlopen(library, RTLD_NOW | RTLD_LOCAL);
	if (!handle) {
		fprintf(stderr, "cannot load %s: %s\n", library, dlerror());
		return 1;
	}
	*(void **)(&test) = dlsym(handle, "run_test");
	if (!test) {
		fprintf(stderr, "run_test is missing from %s: %s\n", library,
			dlerror());
		dlclose(handle);
		return 1;
	}

	printf("self-test: CDSP unsigned PD, Hexagon v75, vector=0..%d\n",
	       NPU_TEST_VECTOR_LENGTH - 1);
	fflush(stdout);
	result = test(CDSP_DOMAIN_ID, true);
	if (result) {
		fprintf(stderr, "self-test: FAIL (FastRPC error %#x)\n",
			(unsigned int)result);
		dlclose(handle);
		return 1;
	}
	printf("self-test: PASS (sum=499500, max=999, DSP result verified)\n");
	dlclose(handle);
	return 0;
}

static void usage(const char *program)
{
	printf("usage: %s [--self-test]\n", program);
	printf("  no arguments  show CDSP firmware state and FastRPC capabilities\n");
	printf("  --self-test   execute and verify the v75 DSP calculator test\n");
}

int main(int argc, char **argv)
{
	static const char *const devices[] = {
		"/dev/fastrpc-cdsp",
		"/dev/fastrpc-cdsp-secure",
		"/dev/fastrpc-adsp",
	};
	bool queried = false;
	size_t i;

	if (argc == 2 && !strcmp(argv[1], "--self-test"))
		return run_self_test();
	if (argc == 2 && (!strcmp(argv[1], "--help") ||
			  !strcmp(argv[1], "-h"))) {
		usage(argv[0]);
		return 0;
	}
	if (argc != 1) {
		usage(argv[0]);
		return 2;
	}

	show_remoteprocs();
	for (i = 0; i < sizeof(devices) / sizeof(devices[0]); i++)
		if (!probe_device(devices[i]))
			queried = true;

	if (!queried) {
		fprintf(stderr,
			"no FastRPC device could be queried; run as root and check CDSP\n");
		return 1;
	}
	return 0;
}
