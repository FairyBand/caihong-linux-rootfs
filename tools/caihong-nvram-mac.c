// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2026 Osilvfe <osilvfe@gmail.com>
/* Read the device-specific WLAN and Bluetooth addresses from Oplus NVRAM. */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <openssl/evp.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define NVRAM_DATA_SIZE 0x1ff000U
#define NVRAM_STATUS_SIZE 48U
#define NVRAM_UNIT_SIZE 0x1000U
#define NVRAM_HEADER_SIZE 0x1c0U
#define NVRAM_HASH_SIZE 32U
#define NVRAM_AUTH_SIZE 64U
#define WLAN_MAC_OFFSET 0x3e0U
#define BT_MAC_OFFSET 0x3e6U

static const unsigned char nvram_magic[8] = {
	'O', 'E', 'M', '~', '~', 'O', 'E', 'M'
};

struct nvram_copy {
	unsigned char *data;
	uint32_t generation;
	bool valid;
};

static uint32_t get_le32(const unsigned char *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int sha256(const void *data, size_t size,
		  unsigned char digest[NVRAM_HASH_SIZE])
{
	unsigned int digest_size = 0;

	if (EVP_Digest(data, size, digest, &digest_size, EVP_sha256(), NULL) != 1)
		return -1;
	return digest_size == NVRAM_HASH_SIZE ? 0 : -1;
}

static int pread_all(int fd, void *buffer, size_t size, off_t offset)
{
	unsigned char *p = buffer;

	while (size) {
		ssize_t count = pread(fd, p, size, offset);

		if (count < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (!count) {
			errno = EIO;
			return -1;
		}
		p += count;
		offset += count;
		size -= count;
	}
	return 0;
}

static int read_nvram_copy(const char *path, struct nvram_copy *copy)
{
	unsigned char status[NVRAM_STATUS_SIZE];
	unsigned char digest[NVRAM_HASH_SIZE];
	int fd;

	memset(copy, 0, sizeof(*copy));
	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) {
		fprintf(stderr, "%s: %s\n", path, strerror(errno));
		return -1;
	}

	copy->data = malloc(NVRAM_DATA_SIZE);
	if (!copy->data) {
		fprintf(stderr, "allocating NVRAM buffer: %s\n", strerror(errno));
		close(fd);
		return -1;
	}
	if (pread_all(fd, copy->data, NVRAM_DATA_SIZE, 0) ||
	    pread_all(fd, status, sizeof(status), NVRAM_DATA_SIZE)) {
		fprintf(stderr, "%s: %s\n", path, strerror(errno));
		close(fd);
		return -1;
	}
	close(fd);

	copy->generation = get_le32(status + 8);
	copy->valid = !memcmp(status, nvram_magic, sizeof(nvram_magic)) &&
			!sha256(copy->data, NVRAM_DATA_SIZE, digest) &&
			!memcmp(digest, status + 12, NVRAM_HASH_SIZE) &&
			get_le32(status + 44) == 0;
	if (!copy->valid)
		fprintf(stderr, "%s: invalid NVRAM status or checksum\n", path);
	return 0;
}

static const struct nvram_copy *select_nvram_copy(const struct nvram_copy *a,
						  const struct nvram_copy *b)
{
	if (a->valid && !b->valid)
		return a;
	if (b->valid && !a->valid)
		return b;
	if (!a->valid && !b->valid)
		return NULL;

	/* Oplus marks the current redundant copy with generation value 2. */
	if (a->generation == 2 && b->generation != 2)
		return a;
	if (b->generation == 2 && a->generation != 2)
		return b;
	return a;
}

static int read_serial(uint32_t *serial)
{
	const char prefix[] = "oplusboot.serialno=";
	char cmdline[8192];
	char *token, *saveptr = NULL;
	const char *override;
	unsigned long value;
	char *end;
	FILE *file;

	override = getenv("CAIHONG_SERIALNO");
	if (override && *override) {
		value = strtoul(override, &end, 16);
		if (!*end && value <= UINT32_MAX) {
			*serial = value;
			return 0;
		}
		fprintf(stderr, "invalid CAIHONG_SERIALNO: %s\n", override);
		return -1;
	}

	file = fopen("/proc/cmdline", "re");
	if (!file) {
		fprintf(stderr, "/proc/cmdline: %s\n", strerror(errno));
		return -1;
	}
	if (!fgets(cmdline, sizeof(cmdline), file)) {
		fprintf(stderr, "/proc/cmdline: %s\n",
			ferror(file) ? strerror(errno) : "empty file");
		fclose(file);
		return -1;
	}
	fclose(file);

	for (token = strtok_r(cmdline, " \n", &saveptr); token;
	     token = strtok_r(NULL, " \n", &saveptr)) {
		if (strncmp(token, prefix, sizeof(prefix) - 1))
			continue;
		value = strtoul(token + sizeof(prefix) - 1, &end, 16);
		if (*end || value > UINT32_MAX)
			break;
		*serial = value;
		return 0;
	}

	fprintf(stderr, "missing or invalid oplusboot.serialno in /proc/cmdline\n");
	return -1;
}

static unsigned char rotate_left_2(unsigned char value)
{
	return (unsigned char)((value << 2) | (value >> 6));
}

static unsigned char rotate_right_2(unsigned char value)
{
	return (unsigned char)((value >> 2) | (value << 6));
}

static void transform_digest(unsigned char digest[NVRAM_HASH_SIZE])
{
	unsigned char transformed[NVRAM_HASH_SIZE];
	size_t i, output = 0;

	for (i = 0; i < NVRAM_HASH_SIZE; i += 2)
		transformed[output++] = rotate_left_2(digest[i]);
	for (i = 1; i < NVRAM_HASH_SIZE; i += 2)
		transformed[output++] = rotate_right_2(digest[i]);
	memcpy(digest, transformed, sizeof(transformed));
}

static int derive_key(uint32_t serial, unsigned char material[NVRAM_HASH_SIZE])
{
	char serial_text[16];
	int i;

	if (snprintf(serial_text, sizeof(serial_text), "%015X", serial) != 15)
		return -1;
	/* The stock implementation hashes all 16 bytes, including the NUL. */
	if (sha256(serial_text, sizeof(serial_text), material))
		return -1;
	for (i = 0; i < 3; i++)
		transform_digest(material);
	return 0;
}

static int decrypt_record(const unsigned char *record, uint32_t serial,
			  unsigned char **payload, size_t *payload_size)
{
	unsigned char header_digest[NVRAM_HASH_SIZE];
	unsigned char payload_digest[NVRAM_HASH_SIZE];
	unsigned char key_material[NVRAM_HASH_SIZE];
	unsigned char *plain = NULL;
	EVP_CIPHER_CTX *ctx = NULL;
	uint32_t data_size, auth_size;
	size_t encrypted_size;
	int first_size = 0, final_size = 0;
	int ret = -1;

	if (memcmp(record, nvram_magic, sizeof(nvram_magic))) {
		fprintf(stderr, "NVRAM item 0 has an invalid header\n");
		return -1;
	}
	data_size = get_le32(record + 12);
	auth_size = get_le32(record + 16);
	encrypted_size = (size_t)data_size + auth_size;
	if (auth_size != NVRAM_AUTH_SIZE || data_size < BT_MAC_OFFSET + 6 ||
	    encrypted_size > NVRAM_UNIT_SIZE - NVRAM_HEADER_SIZE ||
	    encrypted_size % 16) {
		fprintf(stderr, "NVRAM item 0 has invalid lengths: data=%u auth=%u\n",
			data_size, auth_size);
		return -1;
	}
	if (derive_key(serial, key_material)) {
		fprintf(stderr, "failed to derive the NVRAM key\n");
		return -1;
	}

	plain = malloc(encrypted_size);
	ctx = EVP_CIPHER_CTX_new();
	if (!plain || !ctx) {
		fprintf(stderr, "allocating decrypt state failed\n");
		goto out;
	}
	if (EVP_DecryptInit_ex(ctx, EVP_aes_128_cbc(), NULL, key_material,
			       key_material + 16) != 1 ||
	    EVP_CIPHER_CTX_set_padding(ctx, 0) != 1 ||
	    EVP_DecryptUpdate(ctx, plain, &first_size,
			      record + NVRAM_HEADER_SIZE, encrypted_size) != 1 ||
	    EVP_DecryptFinal_ex(ctx, plain + first_size, &final_size) != 1 ||
	    (size_t)(first_size + final_size) != encrypted_size) {
		fprintf(stderr, "decrypting NVRAM item 0 failed\n");
		goto out;
	}

	if (sha256(record, NVRAM_HEADER_SIZE, header_digest) ||
	    memcmp(header_digest, plain, NVRAM_HASH_SIZE)) {
		fprintf(stderr, "NVRAM item 0 header authentication failed\n");
		goto out;
	}
	if (sha256(plain + NVRAM_AUTH_SIZE, data_size, payload_digest) ||
	    memcmp(payload_digest, plain + NVRAM_HASH_SIZE, NVRAM_HASH_SIZE)) {
		fprintf(stderr, "NVRAM item 0 payload authentication failed\n");
		goto out;
	}

	memmove(plain, plain + NVRAM_AUTH_SIZE, data_size);
	*payload = plain;
	*payload_size = data_size;
	plain = NULL;
	ret = 0;
out:
	EVP_CIPHER_CTX_free(ctx);
	free(plain);
	return ret;
}

static void decode_address(const unsigned char *raw, unsigned char address[6])
{
	int i;

	for (i = 0; i < 6; i++)
		address[i] = raw[5 - i];
}

static bool address_valid(const unsigned char address[6])
{
	static const unsigned char zero[6];
	static const unsigned char broadcast[6] = {
		0xff, 0xff, 0xff, 0xff, 0xff, 0xff
	};
	static const unsigned char placeholder[6] = {
		0x55, 0x44, 0x33, 0x22, 0x11, 0x00
	};

	return !(address[0] & 1) && memcmp(address, zero, 6) &&
	       memcmp(address, broadcast, 6) && memcmp(address, placeholder, 6);
}

static void print_address(const char *name, const unsigned char address[6])
{
	printf("%s=%02x:%02x:%02x:%02x:%02x:%02x\n", name,
	       address[0], address[1], address[2], address[3],
	       address[4], address[5]);
}

int main(int argc, char **argv)
{
	const char *path1 = "/dev/disk/by-partlabel/nonmodemst1";
	const char *path2 = "/dev/disk/by-partlabel/nonmodemst2";
	struct nvram_copy copy1, copy2;
	const struct nvram_copy *selected;
	unsigned char *payload = NULL;
	unsigned char wlan[6], bluetooth[6];
	size_t payload_size = 0;
	uint32_t serial;
	int ret = EXIT_FAILURE;

	if (argc == 3) {
		path1 = argv[1];
		path2 = argv[2];
	} else if (argc != 1) {
		fprintf(stderr, "usage: %s [nonmodemst1 nonmodemst2]\n", argv[0]);
		return EXIT_FAILURE;
	}

	if (read_serial(&serial))
		return EXIT_FAILURE;
	read_nvram_copy(path1, &copy1);
	read_nvram_copy(path2, &copy2);
	selected = select_nvram_copy(&copy1, &copy2);
	if (!selected) {
		fprintf(stderr, "no valid nonmodemst NVRAM copy found\n");
		goto out;
	}
	if (decrypt_record(selected->data, serial, &payload, &payload_size))
		goto out;
	if (payload_size < BT_MAC_OFFSET + 6) {
		fprintf(stderr, "NVRAM item 0 is too short for MAC addresses\n");
		goto out;
	}

	decode_address(payload + WLAN_MAC_OFFSET, wlan);
	decode_address(payload + BT_MAC_OFFSET, bluetooth);
	if (!address_valid(wlan) || !address_valid(bluetooth)) {
		fprintf(stderr, "NVRAM contains an invalid WLAN or Bluetooth address\n");
		goto out;
	}
	if (!memcmp(wlan, bluetooth, sizeof(wlan))) {
		fprintf(stderr, "NVRAM WLAN and Bluetooth addresses are identical\n");
		goto out;
	}

	print_address("WLAN_MAC", wlan);
	print_address("BLUETOOTH_MAC", bluetooth);
	ret = EXIT_SUCCESS;
out:
	free(payload);
	free(copy1.data);
	free(copy2.data);
	return ret;
}
