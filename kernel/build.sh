#!/usr/bin/env bash

set -e

REPO_ROOT=$(pwd)
export ARCH=arm; export LOCALVERSION="-steam"

mkdir -p boot
cd steamlink-sdk
source setenv.sh
cd ../linux-$KERNEL_VERSION

MAKE_ARGS=()
if command -v ccache >/dev/null 2>&1; then
	MAKE_ARGS+=("CC=ccache ${CROSS_COMPILE}gcc")
	echo "Using ccache for kernel compilation"
fi

PATCH_DIR="$REPO_ROOT/kernel/patches/$KERNEL_VERSION"
if [[ -d "$PATCH_DIR" ]]; then
	shopt -s nullglob
	for kernel_patch in "$PATCH_DIR"/*.patch; do
		echo "Applying $(basename "$kernel_patch")"
		if patch --batch --forward --dry-run -p1 < "$kernel_patch" >/dev/null; then
			patch --batch --forward -p1 < "$kernel_patch"
		elif patch --batch --reverse --dry-run -p1 < "$kernel_patch" >/dev/null; then
			echo "Already applied: $(basename "$kernel_patch")"
		else
			echo "Patch does not apply cleanly: $kernel_patch" >&2
			exit 1
		fi
	done
fi

make "${MAKE_ARGS[@]}" olddefconfig
make "${MAKE_ARGS[@]}" -j"$(nproc)"
make "${MAKE_ARGS[@]}" modules
rm -rf /tmp/build-modules
mkdir -p /tmp/build-modules
INSTALL_MOD_PATH=/tmp/build-modules make "${MAKE_ARGS[@]}" modules_install

if command -v ccache >/dev/null 2>&1; then
	ccache --show-stats
fi
