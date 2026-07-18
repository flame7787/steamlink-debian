ARG DEBIAN_VERSION=trixie
FROM docker.io/arm32v7/debian:$DEBIAN_VERSION-slim

ARG KERNEL_VERSION=6.1.115
ARG DEBIAN_VERSION=trixie

COPY ./kernel-$KERNEL_VERSION/ /boot/
RUN mkdir -p /lib/modules && mv /boot/$KERNEL_VERSION-steam /lib/modules/$KERNEL_VERSION-steam

COPY ./rootfs/boot/* /boot/
COPY ./rootfs/etc/ /etc/
COPY ./rootfs/usr/bin/* /usr/bin/
COPY ./rootfs/steamlink/ /steamlink/

# Add repositories
RUN rm -rf /etc/apt/sources.list.d/* || true
RUN echo "deb http://deb.debian.org/debian $DEBIAN_VERSION main non-free non-free-firmware" > /etc/apt/sources.list
RUN echo "deb http://security.debian.org/debian-security $DEBIAN_VERSION-security main non-free non-free-firmware" >> /etc/apt/sources.list
RUN echo "deb http://deb.debian.org/debian $DEBIAN_VERSION-updates main non-free non-free-firmware" >> /etc/apt/sources.list

# Remove non-free-firmware if DEBIAN_VERSION is bullseye
RUN if [ "$DEBIAN_VERSION" = "bullseye" ]; then sed -i 's/non-free-firmware//g' /etc/apt/sources.list; fi

# Install basic system components
RUN apt-get update && apt-get install -y --no-install-recommends systemd systemd-timesyncd dbus ca-certificates dhcpcd5 nano vim openssh-server sudo ifupdown net-tools iproute2 iptables nftables kmod udev iputils-ping wget dosfstools unzip binutils libatomic1 initramfs-tools e2fsprogs parted firmware-libertas wireless-regdb docker.io

# Create initramfs
RUN mkinitramfs -o /boot/initramfs-linux-steam.img $KERNEL_VERSION-steam

RUN useradd -s /bin/bash -m debian
RUN echo "debian:steamlink" | chpasswd

# Add debian user to sudoers
RUN usermod -a -G sudo debian

# Enable basic services
RUN systemctl enable ssh
RUN systemctl enable dbus
RUN systemctl enable networking
RUN systemctl enable systemd-timesyncd
RUN systemctl enable docker

# /etc/network/interfaces setup
RUN echo "allow-hotplug eth0" > /etc/network/interfaces
RUN echo "auto eth0" >> /etc/network/interfaces
RUN echo "iface eth0 inet dhcp" >> /etc/network/interfaces

RUN apt-get --yes clean
