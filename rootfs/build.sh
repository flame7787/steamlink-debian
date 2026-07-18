#!/usr/bin/env bash

set -euo pipefail

IMAGE=steamlink-debian.img
MOUNT_DIR=""
LOOP_DEV=""

cleanup() {
	local status=$?

	trap - EXIT
	set +e

	if [[ -n "$MOUNT_DIR" ]] && mountpoint -q "$MOUNT_DIR"; then
		umount "$MOUNT_DIR"
	fi

	if [[ -n "$LOOP_DEV" ]]; then
		losetup -d "$LOOP_DEV"
	fi

	if [[ -n "$MOUNT_DIR" ]]; then
		rmdir "$MOUNT_DIR"
	fi

	exit "$status"
}

trap cleanup EXIT

dd if=/dev/zero of="$IMAGE" bs=1M count=1024

# Create an MBR partition table with one ext3 partition.
parted --script "$IMAGE" mklabel msdos
parted --script "$IMAGE" mkpart primary ext3 1MiB 100%

sync

# Use a private mount point so concurrent or interrupted builds do not share
# persistent state under /mnt.
MOUNT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/steamlink-rootfs.XXXXXX")
LOOP_DEV=$(losetup --show -P -f "$IMAGE")

sync

mkfs.ext3 "${LOOP_DEV}p1"
mount "${LOOP_DEV}p1" "$MOUNT_DIR"
tar -xpf rootfs.tar -C "$MOUNT_DIR"
rm -f "$MOUNT_DIR/.dockerenv"
sync

umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"
MOUNT_DIR=""

losetup -d "$LOOP_DEV"
LOOP_DEV=""

# Replace an output left by an earlier run and make it artifact-readable.
xz -f "$IMAGE"
chmod 0644 "${IMAGE}.xz"
