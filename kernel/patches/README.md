# Kernel patch stack

Version-specific patches are applied in filename order by `kernel/build.sh`
after the kernel archive is extracted and before `make olddefconfig` runs.

Keep patches scoped to the exact kernel version directory. A clean build applies
each patch once; rerunning the build against an already-patched source tree is
also supported.

Linux 6.1 is the only target for the experimental Berlin2CD NAND work. The 5.10
compatibility build is intentionally unchanged.
