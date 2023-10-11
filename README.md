# Armvuan

This distro is based on two prominent projects: [Armbian](https://www.armbian.com) and [Devuan](https://www.devuan.org).
It is built in the simplest way, using Devuan debootstrapped system with kernel,
u-boot and all board support from Armbian, thus avoiding compilation parties as much as possible.

Armvuan builder uses Armbian's toolkit but it's not a part of it as it may seem.
Actually I don't know how this pet project should evolve.
Both Armbian and Devuan have their own toolchains for ARM boards and both have fatal flaws:
the former is locked to systemd-based distros, the latter has poor support for ARM boards.

Pre-built images:
* [Armbian_23.11.0-trunk_Orangepipc_daedalus_current_6.1.53.img.xz](https://github.com/declassed-art/armvuan/releases/download/daedalus/Armbian_23.11.0-trunk_Orangepipc_daedalus_current_6.1.53.img.xz)
* [Armbian_23.11.0-trunk_Orangepi-r1_daedalus_current_6.1.53.img.xz](https://github.com/declassed-art/armvuan/releases/download/daedalus/Armbian_23.11.0-trunk_Orangepi-r1_daedalus_current_6.1.53.img.xz)
* [Armbian_23.11.0-trunk_Orangepizero_daedalus_current_6.1.53.img.xz](https://github.com/declassed-art/armvuan/releases/download/daedalus/Armbian_23.11.0-trunk_Orangepizero_daedalus_current_6.1.53.img.xz)

Planned images (I do have these boards):
* NanoPI M4v2
* NanoPI Neo3
* NanoPI R2S
* OrangePI 3

Possibly in future (these boards are [already supported by Devuan](https://arm-files.devuan.org/)):
* RaspberryPI

Targetted primarily to headless boards, this distro is very minimalistic
and does not run any configuration script at first boot.
After flashing your microSD card you need to make tweaks to `/etc/network/interfaces`
and write your SSH public key to `/root/.ssh/authorized_keys`.

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
