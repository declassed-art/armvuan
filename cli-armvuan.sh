#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Experimental Devuan on Armbian using only debootstrap+apt+tweaks without any compilation parties.
# In the bright future if it ever comes: drop all this shit in favor of native support
# either in Armbian Linux Build Framework or in Devuan’s Simple Distro Kit.
#
# Resulting images are primarily intended for headless boards, root password is disabled,
# so a few manual tweaks are required before inserting your SD card in:
# * add public key to /root/.ssh/authorized_keys
# * configure /etc/network/interfaces
#
# After successful boot:
# * convert necessary systemd services to ones of init system of your flavor
#   (e.g. hardware optimizations - you can dissect armbian-bsp package for clues)
#
# -- Axy, declassed.art@gmail.com

# armvuan does not resize filesystem, thus it needs some extra space for logs and other stuff
# XXX use command line options instead?
EXTRA_ROOTFS_MIB_SIZE=128

COMPRESS_OUTPUTIMAGE=sha,xz

# XXX use command line options instead
NAMESERVER=1.1.1.1

# set for release candidate
RC_SUFFIX=-rc1

# XXX move to config?
DEVUAN_MIRROR=http://us.deb.devuan.org/merged/
DEVUAN_KEY_IDS=(0022D0AB5275F140 94532124541922FB)

FLAVOR_INCLUDE=runit,runit-init,nano

# notes:
# * sysv-rc,sysvinit-utils are installed anyway, not sure if I should struggle to drop them
# * sorry, vim fans, I'm tired to read manpage each time for how to exit when I involuntarily get in
# * I don't use dynamic IPs, all my boards serve specific purposes and have static addresses
# -- axy
FLAVOR_EXCLUDE=sysvinit-core,vim-common,vim-tiny,isc-dhcp-client,isc-dhcp-common

# notes:
# * apt-utils, dialog are needed to avoid debconf errors
# * initramfs-tools is needed to properly install linux-image later on
# * procps is needed because it provides /etc/sysctl.conf
# * udev is needed, otherwise Armbian's udev wil be installed,
#   it's a transitional package in Devuan, but eudev is explicitly specified just in case
REQUIRED_PACKAGES=apt-utils,console-setup,cron,dialog,fping,initramfs-tools-core,initramfs-tools,\
iw,libc-l10n,locales,lsb-release,netbase,procps,tzdata,udev,eudev,u-boot-tools,zstd

DISTRO_INCLUDE=bsdextrautils,cpufrequtils,chrony,dosfstools,ethtool,fdisk,findutils,less,ifupdown,\
inetutils-ping,logrotate,lsof,man-db,mmc-utils,mtd-utils,openssh-server,openssh-sftp-server,\
parted,psutils,rsync,rsyslog,screen,sysfsutils,tmux,usbutils,wireless-tools,wpasupplicant


DEBOOTSTRAP_INCLUDE=${FLAVOR_INCLUDE},${DISTRO_INCLUDE},${REQUIRED_PACKAGES}

# XXX on which boards dmidecode can run? (neither of mine -- axy)
DEBOOTSTRAP_EXCLUDE=${FLAVOR_EXCLUDE},dmidecode


# for debugging and/or running functions separately
# XXX use command line options instead
#PRESERVE_SDCARD_MOUNT=yes
#PRESERVE_WORKDIR=yes
#ARMBIAN_BUILD_UUID=840e2ed5-473b-453c-b050-10f2cbdbe976


# Devuan-Armbian release map
declare -A ARMBIAN_RELEASE=(
	["daedalus"]="bookworm"
)

function cli_armvuan_run() {

	prepare_armvuan_env

	local functions
	case "${ARMBIAN_COMMAND}" in
		armvuan-build)
			# the whole build process
			functions=(
				armvuan_prebuild
				armvuan_stage1
				armvuan_stage2
				armvuan_add_armbian_repos
				armvuan_tweaks
				armvuan_blend
				armvuan_final_tweaks
				armvuan_make_image
			)
			;;
		*)
			# invoke specific function only
			# XXX armvuan_tweaks has side effects, don't run subsequent functions separately
			functions=("${ARMBIAN_COMMAND//-/_}")
			;;
	esac

	local fn
	for fn in ${functions[@]}; do
		LOG_SECTION=${fn} $fn
	done
}

function prepare_armvuan_env() {

	# XXX what is correct way to init minimal environment to build a simple bsp deb?
	skip_host_config=yes use_board=yes prep_conf_main_minimal_ni

	# use cache directory for tools and keyring
	declare -g DEBOOTSTRAP_DIR="${SRC}/cache/tools/devuan/debootstrap"
	declare -g DEVUAN_CACHE_DIR="${SRC}/cache/devuan"
	declare -g DEVUAN_KEYRING="${DEVUAN_CACHE_DIR}/devuan-keyring.gpg"

	mkdir -p ${DEVUAN_CACHE_DIR}

	# XXX not cleaned on exit, add to traps somehow
	mkdir -p "${WORKDIR}"  # this is normally done in prepare_host_init but it depends
							# on obtain_and_check_host_release_and_arch and pulls too much crap

	if [[ -n ${RC_SUFFIX} ]] ; then
		EXTRA_IMAGE_SUFFIXES+=${RC_SUFFIX}
	fi
}

function armvuan_prebuild() {

	# get debootstrap from Devuan
	if [[ ! -d ${DEBOOTSTRAP_DIR} ]] ; then
		mkdir -p ${DEBOOTSTRAP_DIR}
		pushd `dirname ${DEBOOTSTRAP_DIR}`
		git clone https://git.devuan.org/devuan/debootstrap.git
		popd
	fi

	# get keys
	gpg --no-default-keyring --keyserver keyring.devuan.org --keyring ${DEVUAN_KEYRING} --recv-keys ${DEVUAN_KEY_IDS[@]}
}

function armvuan_stage1() {
	# Devuan debootstrap stage 1

	export DEBOOTSTRAP_DIR
	mkdir -p ${DEVUAN_CACHE_DIR}/apt
	do_with_retries 3 run_host_command_logged_raw debootstrap --foreign --arch=${ARCH} \
		--variant=minbase \
		--keyring=${DEVUAN_KEYRING} \
		--include=${DEBOOTSTRAP_INCLUDE} \
		--exclude=${DEBOOTSTRAP_EXCLUDE} \
		--cache-dir=${DEVUAN_CACHE_DIR}/apt \
    ${RELEASE} ${SDCARD} ${DEVUAN_MIRROR}
}

function armvuan_stage2() {
	# Devuan debootstrap stage 2

	unset DEBOOTSTRAP_DIR
	chroot_sdcard /debootstrap/debootstrap --second-stage
}

function armvuan_add_armbian_repos() {
	# Add Armbian repos

	# add armbian key
	mkdir -p ${SDCARD}/usr/share/keyrings
	# change to binary form
	gpg --dearmor < "${SRC}"/config/armbian.key > ${SDCARD}/usr/share/keyrings/armbian.gpg

	SIGNED_BY="[signed-by=/usr/share/keyrings/armbian.gpg] "

	declare -a components=()
	components+=("main")
	components+=("${ARMBIAN_RELEASE[$RELEASE]}-utils")   # utils contains packages Igor picks from other repos
	components+=("${ARMBIAN_RELEASE[$RELEASE]}-desktop") # desktop contains packages Igor picks from other repos

	# stage: add armbian repository and install key
	if [[ $DOWNLOAD_MIRROR == "china" ]]; then
		echo "deb ${SIGNED_BY}https://mirrors.tuna.tsinghua.edu.cn/armbian $RELEASE ${components[*]}" > "${SDCARD}"/etc/apt/sources.list.d/armbian.list
	elif [[ $DOWNLOAD_MIRROR == "bfsu" ]]; then
		echo "deb ${SIGNED_BY}http://mirrors.bfsu.edu.cn/armbian $RELEASE ${components[*]}" > "${SDCARD}"/etc/apt/sources.list.d/armbian.list
	else
		echo "deb ${SIGNED_BY}http://$([[ $BETA == yes ]] && echo "beta" || echo "apt").armbian.com ${ARMBIAN_RELEASE[$RELEASE]} ${components[*]}" > "${SDCARD}"/etc/apt/sources.list.d/armbian.list
	fi

	# optionally add armhf arhitecture to arm64, if asked to do so.
	if [[ "a${ARMHF_ARCH}" == "ayes" ]]; then
		[[ $ARCH == arm64 ]] && chroot_sdcard LC_ALL=C LANG=C dpkg --add-architecture armhf
	fi

	# Add external / PPAs to apt sources; decides internally based on minimal/cli/desktop dir/file structure
	add_apt_sources

	# stage: update packages list
	display_alert "Updating package list" "$RELEASE" "info"
	do_with_retries 3 chroot_sdcard_apt_get_update
}

function armvuan_tweaks() {

	# Armbian is locked to systemd, we need fake systemctl
	cat <<- EOF > "${SDCARD}"/usr/bin/systemctl
		#!/bin/sh
		exit 0
	EOF
	chmod +x "${SDCARD}"/usr/bin/systemctl

	# from function create_new_rootfs_cache_via_debootstrap:

	# stage: configure language and locales.
	# this _requires_ DEST_LANG, otherwise, bomb: if it's not here _all_ locales will be generated which is very slow.
	display_alert "Configuring locales" "DEST_LANG: ${DEST_LANG}" "info"
	[[ "x${DEST_LANG}x" == "xx" ]] && exit_with_error "Bug: got to config locales without DEST_LANG set"

	[[ -f ${SDCARD}/etc/locale.gen ]] && sed -i "s/^# ${DEST_LANG}/${DEST_LANG}/" ${SDCARD}/etc/locale.gen
	chroot_sdcard LC_ALL=C LANG=C locale-gen "${DEST_LANG}"
	chroot_sdcard LC_ALL=C LANG=C update-locale "LANG=${DEST_LANG}" "LANGUAGE=${DEST_LANG}" "LC_MESSAGES=${DEST_LANG}"

	if [[ -f ${SDCARD}/etc/default/console-setup ]]; then
		# @TODO: Should be configurable.
		sed -e 's/CHARMAP=.*/CHARMAP="UTF-8"/' -e 's/FONTSIZE=.*/FONTSIZE="8x16"/' \
			-e 's/CODESET=.*/CODESET="guess"/' -i "${SDCARD}/etc/default/console-setup"
		chroot_sdcard LC_ALL=C LANG=C setupcon --save --force
	fi

	####################################################

	# from function install_distribution_specific:

	# remove doubled uname from motd
	[[ -f "${SDCARD}"/etc/update-motd.d/10-uname ]] && rm "${SDCARD}"/etc/update-motd.d/10-uname

	# use list modules INITRAMFS
	if [ -f "${SRC}"/config/modules/"${MODULES_INITRD}" ]; then
		display_alert "Use file list modules MODULES_INITRD" "${MODULES_INITRD}"
		sed -i "s/^MODULES=.*/MODULES=list/" "${SDCARD}"/etc/initramfs-tools/initramfs.conf
		cat "${SRC}"/config/modules/"${MODULES_INITRD}" >> "${SDCARD}"/etc/initramfs-tools/modules
	fi

	####################################################

	# from function install_distribution_agnostic:

	# Bail if $ROOTFS_TYPE not set
	[[ -z $ROOTFS_TYPE ]] && exit_with_error "ROOTFS_TYPE not set" "install_distribution_agnostic"

	# get linux-image deb file and get kernel version from it
	chroot_sdcard_apt_get_install_download_only linux-image-${BRANCH}-${LINUXFAMILY}
	IMAGE_INSTALLED_KERNEL_VERSION=$(dpkg --info ${SDCARD}/var/cache/apt/archives/linux-image-${BRANCH}-${LINUXFAMILY}* | grep "^ Source:" | sed -e 's/ Source: linux-//')
	display_alert "Parsed kernel version from local package" "${IMAGE_INSTALLED_KERNEL_VERSION}" "debug"

	# add dummy fstab entry to make mkinitramfs happy
	echo "/dev/mmcblk0p1 / $ROOTFS_TYPE defaults 0 1" >> "${SDCARD}"/etc/fstab
	# required for initramfs-tools-core on Stretch since it ignores the / fstab entry
	echo "/dev/mmcblk0p2 /usr $ROOTFS_TYPE defaults 0 2" >> "${SDCARD}"/etc/fstab

	# remove default interfaces file if present
	# before installing board support package
	rm -f "${SDCARD}"/etc/network/interfaces

	# create modules file
	local modules=MODULES_${BRANCH^^}
	if [[ -n "${!modules}" ]]; then
		tr ' ' '\n' <<< "${!modules}" > "${SDCARD}"/etc/modules
	elif [[ -n "${MODULES}" ]]; then
		tr ' ' '\n' <<< "${MODULES}" > "${SDCARD}"/etc/modules
	fi

	# create blacklist files
	local blacklist=MODULES_BLACKLIST_${BRANCH^^}
	if [[ -n "${!blacklist}" ]]; then
		tr ' ' '\n' <<< "${!blacklist}" | sed -e 's/^/blacklist /' > "${SDCARD}/etc/modprobe.d/blacklist-${BOARD}.conf"
	elif [[ -n "${MODULES_BLACKLIST}" ]]; then
		tr ' ' '\n' <<< "${MODULES_BLACKLIST}" | sed -e 's/^/blacklist /' > "${SDCARD}/etc/modprobe.d/blacklist-${BOARD}.conf"
	fi

	# configure MIN / MAX speed for cpufrequtils
	cat <<- EOF > "${SDCARD}"/etc/default/cpufrequtils
		ENABLE=${CPUFREQUTILS_ENABLE:-false}
		MIN_SPEED=$CPUMIN
		MAX_SPEED=$CPUMAX
		GOVERNOR=$GOVERNOR
	EOF

	# disable selinux by default
	mkdir -p "${SDCARD}"/selinux
	[[ -f "${SDCARD}"/etc/selinux/config ]] && sed "s/^SELINUX=.*/SELINUX=disabled/" -i "${SDCARD}"/etc/selinux/config

	# Prevent loading paralel printer port drivers which we don't need here.
	# Suppress boot error if kernel modules are absent
	if [[ -f "${SDCARD}"/etc/modules-load.d/cups-filters.conf ]]; then
		sed "s/^lp/#lp/" -i "${SDCARD}"/etc/modules-load.d/cups-filters.conf
		sed "s/^ppdev/#ppdev/" -i "${SDCARD}"/etc/modules-load.d/cups-filters.conf
		sed "s/^parport_pc/#parport_pc/" -i "${SDCARD}"/etc/modules-load.d/cups-filters.conf
	fi

	# console fix due to Debian bug # @TODO: rpardini: still needed?
	sed -e 's/CHARMAP=".*"/CHARMAP="'$CONSOLE_CHAR'"/g' -i "${SDCARD}"/etc/default/console-setup

	# add the /dev/urandom path to the rng config file
	echo "HRNGDEVICE=/dev/urandom" >> "${SDCARD}"/etc/default/rng-tools

	# @TODO: security problem?
	# ping needs privileged action to be able to create raw network socket
	# this is working properly but not with (at least) Debian Buster
	chroot_sdcard chmod u+s /bin/ping

	# change time zone data
	echo "${TZDATA}" > "${SDCARD}"/etc/timezone
	chroot_sdcard dpkg-reconfigure -f noninteractive tzdata

	# change console welcome text
	echo -e "${VENDOR} ${IMAGE_VERSION:-"${REVISION}"} ${RELEASE^} \\l \n" > "${SDCARD}"/etc/issue
	echo "${VENDOR} ${IMAGE_VERSION:-"${REVISION}"} ${RELEASE^}" > "${SDCARD}"/etc/issue.net

	# root user is already there. Copy bashrc there as well
	cp "${SDCARD}"/etc/skel/.bashrc "${SDCARD}"/root

	if [[ ${DESKTOP_AUTOLOGIN} == yes ]]; then
		# set desktop autologin
		touch "${SDCARD}"/root/.desktop_autologin
	fi

	# NOTE: this needs to be executed before family_tweaks
	local bootscript_src=${BOOTSCRIPT%%:*}
	local bootscript_dst=${BOOTSCRIPT##*:}

	# create extlinux config file @TODO: refactor into extensions u-boot, extlinux
	if [[ $SRC_EXTLINUX == yes ]]; then
		display_alert "Using extlinux, SRC_EXTLINUX: ${SRC_EXTLINUX}" "$NAME_KERNEL - $NAME_INITRD" "info"
		mkdir -p "$SDCARD"/boot/extlinux
		local bootpart_prefix
		if [[ -n $BOOTFS_TYPE ]]; then
			bootpart_prefix=/
		else
			bootpart_prefix=/boot/
		fi
		cat <<- EOF > "$SDCARD/boot/extlinux/extlinux.conf"
			label ${VENDOR}
			  kernel ${bootpart_prefix}$NAME_KERNEL
			  initrd ${bootpart_prefix}$NAME_INITRD
		EOF
		if [[ -n $BOOT_FDT_FILE ]]; then
			if [[ $BOOT_FDT_FILE != "none" ]]; then
				echo "  fdt ${bootpart_prefix}dtb/$BOOT_FDT_FILE" >> "$SDCARD/boot/extlinux/extlinux.conf"
			fi
		else
			echo "  fdtdir ${bootpart_prefix}dtb/" >> "$SDCARD/boot/extlinux/extlinux.conf"
		fi
	else # ... not extlinux ...

		if [[ -n "${BOOTSCRIPT}" ]]; then # @TODO: && "${BOOTCONFIG}" != "none"
			display_alert "Deploying boot script" "$bootscript_src" "info"
			if [ -f "${USERPATCHES_PATH}/bootscripts/${bootscript_src}" ]; then
				run_host_command_logged cp -pv "${USERPATCHES_PATH}/bootscripts/${bootscript_src}" "${SDCARD}/boot/${bootscript_dst}"
			else
				run_host_command_logged cp -pv "${SRC}/config/bootscripts/${bootscript_src}" "${SDCARD}/boot/${bootscript_dst}"
			fi
		fi

		if [[ -n $BOOTENV_FILE ]]; then
			if [[ -f $USERPATCHES_PATH/bootenv/$BOOTENV_FILE ]]; then
				run_host_command_logged cp -pv "$USERPATCHES_PATH/bootenv/${BOOTENV_FILE}" "${SDCARD}"/boot/armbianEnv.txt
			elif [[ -f $SRC/config/bootenv/$BOOTENV_FILE ]]; then
				run_host_command_logged cp -pv "${SRC}/config/bootenv/${BOOTENV_FILE}" "${SDCARD}"/boot/armbianEnv.txt
			fi
		fi

		# TODO: modify $bootscript_dst or armbianEnv.txt to make NFS boot universal
		# instead of copying sunxi-specific template
		if [[ $ROOTFS_TYPE == nfs ]]; then
			display_alert "Copying NFS boot script template"
			if [[ -f $USERPATCHES_PATH/nfs-boot.cmd ]]; then
				run_host_command_logged cp -pv "$USERPATCHES_PATH"/nfs-boot.cmd "${SDCARD}"/boot/boot.cmd
			else
				run_host_command_logged cp -pv "${SRC}"/config/templates/nfs-boot.cmd.template "${SDCARD}"/boot/boot.cmd
			fi
		fi

		if [[ -n $OVERLAY_PREFIX && -f "${SDCARD}"/boot/armbianEnv.txt ]]; then
			display_alert "Adding to armbianEnv.txt" "overlay_prefix=$OVERLAY_PREFIX" "debug"
			run_host_command_logged echo "overlay_prefix=$OVERLAY_PREFIX" ">>" "${SDCARD}"/boot/armbianEnv.txt
		fi

		if [[ -n $DEFAULT_OVERLAYS && -f "${SDCARD}"/boot/armbianEnv.txt ]]; then
			display_alert "Adding to armbianEnv.txt" "overlays=${DEFAULT_OVERLAYS//,/ }" "debug"
			run_host_command_logged echo "overlays=${DEFAULT_OVERLAYS//,/ }" ">>" "${SDCARD}"/boot/armbianEnv.txt
		fi

		if [[ -n $BOOT_FDT_FILE && -f "${SDCARD}"/boot/armbianEnv.txt ]]; then
			display_alert "Adding to armbianEnv.txt" "fdtfile=${BOOT_FDT_FILE}" "debug"
			run_host_command_logged echo "fdtfile=${BOOT_FDT_FILE}" ">>" "${SDCARD}/boot/armbianEnv.txt"
		fi

	fi

	# initial date for fake-hwclock
	date -u '+%Y-%m-%d %H:%M:%S' > "${SDCARD}"/etc/fake-hwclock.data

	echo "${HOST}" > "${SDCARD}"/etc/hostname

	# set hostname in hosts file
	cat <<- EOF > "${SDCARD}"/etc/hosts
		127.0.0.1   localhost
		127.0.1.1   $HOST
		::1         localhost $HOST ip6-localhost ip6-loopback
		fe00::0     ip6-localnet
		ff00::0     ip6-mcastprefix
		ff02::1     ip6-allnodes
		ff02::2     ip6-allrouters
	EOF

	cd "${SRC}" || exit_with_error "cray-cray about ${SRC}"

	# LOGGING: we're running under the logger framework here.
	# LOGGING: so we just log directly to stdout and let it handle it.
	# LOGGING: redirect commands' stderr to stdout so it goes into the log, not screen.

	# XXX for what exactly need this? family_tweaks? to avoid re-building initrd when installing linux-u-boot? anything else?
	# BTW chroot_sdcard looks too much for simple chmod
	display_alert "Temporarily disabling" "initramfs-tools hook for kernel"
	chroot_sdcard chmod -v -x /etc/kernel/postinst.d/initramfs-tools

	# execute $LINUXFAMILY-specific tweaks
	if [[ $(type -t family_tweaks) == function ]]; then
		display_alert "Applying family" " tweaks: $BOARD :: $LINUXFAMILY"
		family_tweaks
		display_alert "Done with family_tweaks" "$BOARD :: $LINUXFAMILY" "debug"
	fi

	# disable repeated messages due to xconsole not being installed.
	[[ -f "${SDCARD}"/etc/rsyslog.d/50-default.conf ]] &&
		sed '/daemon\.\*\;mail.*/,/xconsole/ s/.*/#&/' -i "${SDCARD}"/etc/rsyslog.d/50-default.conf

	[[ $LINUXFAMILY == sun*i ]] && mkdir -p "${SDCARD}"/boot/overlay-user

	if [ -n "$NAMESERVER" ]; then
		if [ -d "${SDCARD}"/etc/resolvconf/resolv.conf.d ] ; then
			# DNS fix. package resolvconf is not available everywhere
			echo "nameserver $NAMESERVER" > "${SDCARD}"/etc/resolvconf/resolv.conf.d/head
		else
			# debootstrap takes resolv.conf from the host system, replace it
			echo "nameserver $NAMESERVER" > "${SDCARD}"/etc/resolv.conf
		fi
	fi

	# permit root login via SSH
	sed -i 's/#\?PermitRootLogin .*/PermitRootLogin yes/' "${SDCARD}"/etc/ssh/sshd_config

	# enable PubkeyAuthentication
	sed -i 's/#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' "${SDCARD}"/etc/ssh/sshd_config

	# disable password authentication
	sed -i 's/#\?PasswordAuthentication .*/PasswordAuthentication no/' "${SDCARD}"/etc/ssh/sshd_config
	mkdir -p "${SDCARD}"/root/.ssh
	chmod 700 "${SDCARD}"/root/.ssh
	touch "${SDCARD}"/root/.ssh/authorized_keys
}

function armvuan_blend() {
	# Blend with Armbian

	# stage: upgrade base packages from xxx-updates and xxx-backports repository branches
	display_alert "Upgrading base packages" "Armbian" "info"
	do_with_retries 3 chroot_sdcard_apt_get upgrade

	do_with_retries 3 chroot_sdcard_apt_get_install \
		armbian-firmware \
		armbian-bsp-cli-${BOARD}-${BRANCH} \
		linux-dtb-${BRANCH}-${LINUXFAMILY} \
		linux-image-${BRANCH}-${LINUXFAMILY} \
		linux-u-boot-${BOARD}-${BRANCH}

	# no need for fake systemctl anymore
	rm -f "${SDCARD}"/usr/bin/systemctl

	display_alert "Re-enabling" "initramfs-tools hook for kernel"
	chroot_sdcard chmod -v +x "/etc/kernel/postinst.d/initramfs-tools"
}

function armvuan_final_tweaks() {

	# sans systemctl version
	cat <<- EOF > "${SDCARD}"/etc/cron.daily/armbian-ram-logging
		#!/bin/sh
		# Only run on systems where logrotate is a cron job
		/usr/lib/armbian/armbian-ramlog write >/dev/null 2>&1
	EOF

	# networking defaults
	cat <<- EOF > "${SDCARD}"/etc/network/interfaces
		auto lo
		iface lo inet loopback

		auto eth0
		iface eth0 inet static
		    address 192.168.0.100
		    netmask 255.255.255.0
		    gateway 192.168.0.1
	EOF

	# armbian-hardware-optimization service
	cat <<- EOF > "${SDCARD}"/etc/init.d/armbian-hardware-optimization
		#!/bin/sh

		### BEGIN INIT INFO
		# Provides:          armbian-hardware-optimization
		# Required-Start:    \$local_fs
		# Required-Stop:
		# Default-Start:     S
		# Default-Stop:
		# Short-Description: Armbian hardware optimization
		# Description:       Armbian hardware optimization
		### END INIT INFO

		case "\$1" in
		start)
		    /usr/lib/armbian/armbian-hardware-optimization start
		    ;;
		*)
		    ;;
		esac
	EOF
	chmod +x "${SDCARD}"/etc/init.d/armbian-hardware-optimization
	chroot_sdcard update-rc.d armbian-hardware-optimization defaults

	# armbian-ramlog service
	cat <<- EOF > "${SDCARD}"/etc/init.d/armbian-ramlog
		#!/bin/sh

		### BEGIN INIT INFO
		# Provides:          armbian-ramlog
		# Required-Start:    \$local_fs
		# Required-Stop:
		# X-Start-Before:    rsyslog
		# X-Stop-After:      rsyslog
		# Default-Start:     S
		# Default-Stop:
		# Short-Description: Armbian memory supported logging
		# Description:       Armbian memory supported logging
		### END INIT INFO

		. /lib/lsb/init-functions

		case "\$1" in
		start)
		    /usr/lib/armbian/armbian-ramlog start
		    ;;
		stop)
		    /usr/lib/armbian/armbian-ramlog stop
		    ;;
		reload)
		    /usr/lib/armbian/armbian-ramlog write
		    ;;
		*)
		    log_failure_msg "Usage: $0 {start|stop|reload}"
		    exit 1
		    ;;
		esac
	EOF
	chmod +x "${SDCARD}"/etc/init.d/armbian-ramlog
	chroot_sdcard update-rc.d armbian-ramlog defaults
}

function armvuan_make_image() {

	# XXX what is the right way?
	mkdir -p ${MOUNT}

	# Only clean if not using local cache. Otherwise it would be cleaning the cache, not the chroot.
	if [[ "${USE_LOCAL_APT_DEB_CACHE}" != "yes" ]]; then
		display_alert "Cleaning" "package lists and apt cache" "warn"
		chroot_sdcard_apt_get clean
	fi

	# from function build_rootfs_and_image:
	LOG_SECTION="prepare_partitions" do_with_logging prepare_partitions

	LOG_SECTION="create_image_from_sdcard_rootfs" do_with_logging armvuan_create_image_from_sdcard_rootfs
}

function armvuan_create_image_from_sdcard_rootfs() {
	# based on function create_image_from_sdcard_rootfs

	# create DESTIMG, hooks might put stuff there early.
	mkdir -p "${DESTIMG}"

	# add a cleanup trap hook do make sure we don't leak it if stuff fails
	add_cleanup_handler trap_handler_cleanup_destimg

	# calculate image filename, and store it in readonly global variable "version", for legacy reasons.
	declare calculated_image_version="undetermined"
	calculate_image_version
	declare -r -g version="${calculated_image_version}" # global readonly from here
	declare rsync_ea=" -X "
	# nilfs2 fs does not have extended attributes support, and have to be ignored on copy
	if [[ $ROOTFS_TYPE == nilfs2 ]]; then rsync_ea=""; fi
	if [[ $ROOTFS_TYPE != nfs ]]; then
		display_alert "Copying files via rsync to" "/ (MOUNT root)"
		run_host_command_logged rsync -aHWh $rsync_ea \
			--exclude="/boot" \
			--exclude="/dev/*" \
			--exclude="/proc/*" \
			--exclude="/run/*" \
			--exclude="/tmp/*" \
			--exclude="/sys/*" \
			--info=progress0,stats1 $SDCARD/ $MOUNT/
	else
		display_alert "Creating rootfs archive" "rootfs.tgz" "info"
		tar cp --xattrs --directory=$SDCARD/ --exclude='./boot/*' --exclude='./dev/*' --exclude='./proc/*' --exclude='./run/*' --exclude='./tmp/*' \
			--exclude='./sys/*' . |
			pv -p -b -r -s "$(du -sb "$SDCARD"/ | cut -f1)" \
				-N "$(logging_echo_prefix_for_pv "create_rootfs_archive") rootfs.tgz" |
			gzip -c > "$DEST/images/${version}-rootfs.tgz"
	fi

	# stage: rsync /boot
	display_alert "Copying files to" "/boot (MOUNT /boot)"
	if [[ $(findmnt --noheadings --output FSTYPE --target "$MOUNT/boot" --uniq) == vfat ]]; then
		# FAT filesystems can't have symlinks; rsync, below, will replace them with copies (-L)...
		# ... unless they're dangling symlinks, in which case rsync will fail.
		# Find dangling symlinks in "$MOUNT/boot", warn, and remove them.
		display_alert "Checking for dangling symlinks" "in FAT32 /boot" "info"
		declare -a dangling_symlinks=()
		while IFS= read -r -d '' symlink; do
			dangling_symlinks+=("$symlink")
		done < <(find "$SDCARD/boot" -xtype l -print0)
		if [[ ${#dangling_symlinks[@]} -gt 0 ]]; then
			display_alert "Dangling symlinks in /boot" "$(printf '%s ' "${dangling_symlinks[@]}")" "warning"
			run_host_command_logged rm -fv "${dangling_symlinks[@]}"
		fi
		run_host_command_logged rsync -rLtWh --info=progress0,stats1 "$SDCARD/boot" "$MOUNT" # fat32
	else
		run_host_command_logged rsync -aHWXh --info=progress0,stats1 "$SDCARD/boot" "$MOUNT" # ext4
	fi

	call_extension_method "pre_update_initramfs" "config_pre_update_initramfs" <<- 'PRE_UPDATE_INITRAMFS'
		*allow config to hack into the initramfs create process*
		Called after rsync has synced both `/root` and `/root` on the target, but before calling `update_initramfs`.
	PRE_UPDATE_INITRAMFS

	# stage: create final initramfs
	[[ -n $KERNELSOURCE ]] && {
		update_initramfs "$MOUNT"
	}

	# DEBUG: print free space @TODO this needs work, grepping might not be ideal here
	local freespace
	freespace=$(LC_ALL=C df -h || true) # don't break on failures
	display_alert "Free SD cache" "$(echo -e "$freespace" | awk -v mp="${SDCARD}" '$6==mp {print $5}')" "info"
	display_alert "Mount point" "$(echo -e "$freespace" | awk -v mp="${MOUNT}" '$6==mp {print $5}')" "info"

	# stage: write u-boot, unless BOOTCONFIG=none
	declare -g -A image_artifacts_debs_reversioned
	if [[ "${BOOTCONFIG}" != "none" ]]; then
		armvuan_write_uboot_to_loop_image
	fi

	# fix wrong / permissions
	chmod 755 "${MOUNT}"

	call_extension_method "pre_umount_final_image" "config_pre_umount_final_image" <<- 'PRE_UMOUNT_FINAL_IMAGE'
		*allow config to hack into the image before the unmount*
		Called before unmounting both `/root` and `/boot`.
	PRE_UMOUNT_FINAL_IMAGE

	if [[ "${SHOW_DEBUG}" == "yes" ]]; then
		# Check the partition table after the uboot code has been written
		display_alert "Partition table after write_uboot" "$LOOP" "debug"
		run_host_command_logged sfdisk -l "${LOOP}" # @TODO: use asset..
	fi

	wait_for_disk_sync "before umount MOUNT"

	umount_chroot_recursive "${MOUNT}" "MOUNT"
	[[ $CRYPTROOT_ENABLE == yes ]] && cryptsetup luksClose "$ROOT_MAPPER"

	call_extension_method "post_umount_final_image" "config_post_umount_final_image" <<- 'POST_UMOUNT_FINAL_IMAGE'
		*allow config to hack into the image after the unmount*
		Called after unmounting both `/root` and `/boot`.
	POST_UMOUNT_FINAL_IMAGE

	free_loop_device_insistent "${LOOP}"
	unset LOOP # unset so cleanup handler does not try it again

	# We're done with ${MOUNT} by now, remove it.
	rm -rf --one-file-system "${MOUNT}"
	# unset MOUNT # don't unset, it's readonly now

	mkdir -p "${DESTIMG}"
	# @TODO: misterious cwd, who sets it?

	run_host_command_logged mv -v "${SDCARD}.raw" "${DESTIMG}/${version}.img"

	# custom post_build_image_modify hook to run before fingerprinting and compression
	[[ $(type -t post_build_image_modify) == function ]] && display_alert "Custom Hook Detected" "post_build_image_modify" "info" && post_build_image_modify "${DESTIMG}/${version}.img"

	# Previously, post_build_image passed the .img path as an argument to the hook. Now its an ENV var.
	declare -g FINAL_IMAGE_FILE="${DESTIMG}/${version}.img"
	call_extension_method "post_build_image" <<- 'POST_BUILD_IMAGE'
		*custom post build hook*
		Called after the final .img file is built, before it is (possibly) written to an SD writer.
		- *NOTE*: this hook used to take an argument ($1) for the final image produced.
		  - Now it is passed as an environment variable `${FINAL_IMAGE_FILE}`
		It is the last possible chance to modify `$CARD_DEVICE`.
	POST_BUILD_IMAGE

	# Before compressing or moving, write it to SD card if such was requested and image was produced.
	if [[ -f "${DESTIMG}/${version}.img" ]]; then
		display_alert "Done building" "${version}.img" "info"
		fingerprint_image "${DESTIMG}/${version}.img.txt" "${version}"

		write_image_to_device_and_run_hooks "${DESTIMG}/${version}.img"
	fi

	declare compression_type                                    # set by image_compress_and_checksum
	output_images_compress_and_checksum "${DESTIMG}/${version}" # this compressed on-disk, and removes the originals.

	# XXX normally they do this somewhere, go try to find
	mkdir -p "${FINALDEST}"

	# Move all files matching the prefix from source to dest. Custom hooks might generate more than one img.
	declare source_dir="${DESTIMG}"
	declare destination_dir="${FINALDEST}"
	declare source_files_prefix="${version}"
	move_images_to_final_destination
}

function armvuan_write_uboot_to_loop_image() {
	# uboot_deb is already in, here's a simplified version of write_uboot_to_loop_image which makes changes in place:

	if [[ ! -f "${MOUNT}/usr/lib/u-boot/platform_install.sh" ]]; then
		exit_with_error "Missing ${MOUNT}/usr/lib/u-boot/platform_install.sh"
	fi

	display_alert "Sourcing u-boot install functions" "${MOUNT}" "info"
	source "${MOUNT}"/usr/lib/u-boot/platform_install.sh
	set -e # make sure, we just included something that might disable it

	display_alert "Writing u-boot bootloader" "${LOOP}" "info"
	write_uboot_platform "${MOUNT}${DIR}" "${LOOP}" # important: DIR is set in platform_install.sh sourced above.
}
