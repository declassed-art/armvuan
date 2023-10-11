# Armvuan

This distro is based on two prominent projects: [Armbian](https://www.armbian.com) and [Devuan](https://www.devuan.org).
It is built in the simplest way, using Devuan debootstrapped system with kernel, dtb,
u-boot, and board support packages from Armbian, thus avoiding compilation parties as much as possible.

Armvuan builder uses Armbian's toolkit but it's not a part of it as it may seem.
Actually I don't know how this pet project should evolve.
Both Armbian and Devuan have their own toolchains for ARM boards and both have fatal flaws:
the former is locked to systemd-based distros, the latter has poor support for ARM boards.

Pre-built images for boards I have:
* [Armbian_23.11.0-trunk_Nanopi-r2s_daedalus_current_6.1.50.img.xz](https://github.com/declassed-art/armvuan/releases/download/daedalus/Armbian_23.11.0-trunk_Nanopi-r2s_daedalus_current_6.1.50.img.xz)
* [Armbian_23.11.0-trunk_Nanopim4v2_daedalus_current_6.1.50.img.xz](https://github.com/declassed-art/armvuan/releases/download/daedalus/Armbian_23.11.0-trunk_Nanopim4v2_daedalus_current_6.1.50.img.xz) Caveat: USB problems
* [Armbian_23.11.0-trunk_Nanopineo3_daedalus_current_6.1.50.img.xz](https://github.com/declassed-art/armvuan/releases/download/daedalus/Armbian_23.11.0-trunk_Nanopineo3_daedalus_current_6.1.50.img.xz)
* [Armbian_23.11.0-trunk_Orangepipc_daedalus_current_6.1.53.img.xz](https://github.com/declassed-art/armvuan/releases/download/daedalus/Armbian_23.11.0-trunk_Orangepipc_daedalus_current_6.1.53.img.xz)
* [Armbian_23.11.0-trunk_Orangepi-r1_daedalus_current_6.1.53.img.xz](https://github.com/declassed-art/armvuan/releases/download/daedalus/Armbian_23.11.0-trunk_Orangepi-r1_daedalus_current_6.1.53.img.xz)
* [Armbian_23.11.0-trunk_Orangepizero_daedalus_current_6.1.53.img.xz](https://github.com/declassed-art/armvuan/releases/download/daedalus/Armbian_23.11.0-trunk_Orangepizero_daedalus_current_6.1.53.img.xz)

Planned:
* OrangePI 3

Possibly in future (these boards are [already supported by Devuan](https://arm-files.devuan.org/)):
* RaspberryPI

Targetted primarily to headless boards, this distro is very minimalistic
and does not run any configuration script at first boot.
After flashing your microSD card you need to make tweaks to `/etc/network/interfaces`
and write your SSH public key to `/root/.ssh/authorized_keys`.

## Tweaks

Armvuan is shipped with the following services enabled:
* armbian-hardware-optimization
* armbian-ramlog

All the rest is up to you. You can convert necessary services
from board support package located in `/lib/systemd/system/`.
Their names start from`armbian-`.

## Troubleshooting hints

If you cannot connect to a headless board, try the following:

1. Reduce commit to a reasonable value, i.e. 6 in `/etc/fstab`
2. Disable ramlog by unlinking `/etc/rcS.d/S??armbian-ramlog`
3. Insert microSD card in and power on your board
4. Wait a couple of minutes
5. Power off, pull microSD card out and examine `/var/log`

## How to use the toolkit

* clone this repository with --recurse-submodules option
* revise `cli-armvuan.sh`
* run `prepare.sh` script to patch Armbian toolchain
* look into `armbian/config/boards` for board names
* make an image for your board:
``` bash
sudo ./armbian/compile.sh armvuan-build BOARD=orangepi-r1 BRANCH=current RELEASE=daedalus
```

Your image is here: `armbian/output/images`
