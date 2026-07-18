## fork

The build uses Debian 13 and Linux 6.1.115. Docker is included in the generated image. The kernel config adds Linux namespaces, cgroups, seccomp, overlayfs, veth/bridge networking, nftables, and iptables, required for Docker.


# steamlink-debian

This repository provides a way to run Debian GNU/Linux on a Valve Steam Link device using a USB stick.

```
debian@steamlink:~$ fastfetch
       _,met$$$$$gg.           debian@steamlink
    ,g$$$$$$$$$$$$$$$P.        ----------------
  ,g$$P"         """Y$$.".     OS: Debian GNU/Linux bookworm 12.7 armv7l
 ,$$P'               `$$$.     Host: Valve Steam Link
',$$P       ,ggs.     `$$b:    Kernel: Linux 6.1.115-steam
`d$$'     ,$P"'   .    $$$     Uptime: 9 mins
 $$P      d$'     ,    $$$P    Packages: 191 (dpkg)
 $$:      $.   -    ,d$$'      Shell: bash 5.2.15
 $$;      Y$b._   _,d$P'       Terminal: /dev/pts/0
 Y$$.    `.`"Y$$$$P"'          CPU: Marvell Berlin
 `$$b      "-.__               Memory: 29.66 MiB / 498.16 MiB (6%)
  `Y$$                         Swap: Disabled
   `Y$$.                       Disk (/): 325.80 MiB / 989.67 MiB (33%) - ext3 [External]
     `$$b.                     Local IP (eth0): 192.168.1.7/24
       `Y$$b.                  Locale: C
          `"Y$b._
             `"""
```

## How to use

Download an image of Debian version of your choice from the [Releases](https://github.com/djmuted/steamlink-debian/releases) page and flash it on a 2GB (or bigger) USB stick using [balenaEtcher](https://etcher.balena.io/) or any other USB flasher. SD cards paired with a USB SD Reader work as well.

> :warning: **Warning**: Flashing the image on the USB stick will wipe all data stored on the device!

Plug the USB stick into the Steam Link and power it on. The device will boot from the USB stick and appear on your network soon.

## Default passwords

> :warning: **Recommended**: Consider changing your passwords with `passwd` after first login.

### Default user

User: `debian`
password: `steamlink`

## First boot

For the first boot a LAN connection is required. Once the new kernel starts booting, there will be no HDMI output anymore. Connect to the Steam Link via SSH. Local IP address can be found in your router's DHCP table.

### Change hostname

This the first thing you should do after logging in, some commands might not work without a proper hostname.

```bash
sudo hostnamectl set-hostname steamlink
echo '127.0.0.1 steamlink' | sudo tee -a /etc/hosts
```

### Resize root partition to full disk size

Resize the partition to take the entire space:

```bash
sudo parted /dev/sda resizepart 1 100%
```

Confirm with `Yes` and press enter, then resize the filesystem:

```
sudo resize2fs /dev/sda1
```

This might take a while, depending on your disk size.

## What does not work

- NAND driver
- DMA controller
- video/audio output
- suspend/resume/halt/reboot
- RTC

## Credits

- [Getting Linux on Valve Steam Link from heap.ovh](https://heap.ovh/getting-linux-on-valve-steam-link.html)
- [Docker Debian bootstrap script from v86 project](https://github.com/copy/v86)
- [regmibijay/steamlink-archlinux GitHub repository](https://github.com/regmibijay/steamlink-archlinux)
