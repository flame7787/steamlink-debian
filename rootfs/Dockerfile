ARG DEBIAN_VERSION=trixie
FROM docker.io/arm32v7/debian:$DEBIAN_VERSION-slim

ARG DEBIAN_VERSION=trixie
ARG DEBIAN_FRONTEND=noninteractive

# Keep the expensive emulated package installation independent of the kernel
# artifact and local rootfs files so it remains cached during kernel iteration.
RUN set -eux; \
    components="main non-free non-free-firmware"; \
    if [ "$DEBIAN_VERSION" = "bullseye" ]; then components="main non-free"; fi; \
    rm -rf /etc/apt/sources.list.d/*; \
    printf '%s\n' \
        "deb http://deb.debian.org/debian $DEBIAN_VERSION $components" \
        "deb http://security.debian.org/debian-security $DEBIAN_VERSION-security $components" \
        "deb http://deb.debian.org/debian $DEBIAN_VERSION-updates $components" \
        > /etc/apt/sources.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        systemd systemd-timesyncd dbus ca-certificates dhcpcd5 nano vim \
        openssh-server sudo ifupdown net-tools iproute2 iptables nftables \
        kmod udev iputils-ping wget dosfstools unzip binutils libatomic1 \
        initramfs-tools e2fsprogs parted firmware-libertas wireless-regdb \
        docker.io locales; \
    sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen; \
    locale-gen; \
    update-locale LANG=en_US.UTF-8; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8

COPY ./rootfs/boot/* /boot/
COPY ./rootfs/etc/ /etc/
COPY ./rootfs/usr/bin/* /usr/bin/
COPY ./rootfs/steamlink/ /steamlink/

RUN set -eux; \
    useradd -s /bin/bash -m debian; \
    echo "debian:steamlink" | chpasswd; \
    usermod -a -G sudo debian; \
    systemctl enable ssh dbus networking systemd-timesyncd docker; \
    printf '%s\n' \
        "allow-hotplug eth0" \
        "auto eth0" \
        "iface eth0 inet dhcp" \
        > /etc/network/interfaces

# Install the frequently changing kernel last. Only this layer and initramfs
# generation need to rerun for a new kernel build.
ARG KERNEL_VERSION=6.1.115
COPY ./kernel-$KERNEL_VERSION/ /boot/
RUN set -eux; \
    mkdir -p /lib/modules; \
    mv "/boot/$KERNEL_VERSION-steam" "/lib/modules/$KERNEL_VERSION-steam"; \
    mkinitramfs -o /boot/initramfs-linux-steam.img "$KERNEL_VERSION-steam"
