#!/usr/bin/env bash

# Simple script to setup the Nvidia Nano for desktop use.

# Inspired by - https://syonyk.blogspot.com/2019/04/nvidia-jetson-nano-desktop-use-kernel-builds.html?m=1

# TODO 
# - Setup the filesystem and partitions - mostly done
# - Auto-detect if kernel part is done and run setup_root
# - Enforce environment variables or arguments or add prompts so options are confirmed / safe and desired by the user.
# - Improve output
# - Check after the rsync is complete (basic check of du etc) or consider doing a SHA check on source and dest.
# - Prompts / confirmations for dangerous actions.

function download_kernel_sources()
{
	pushd "${1}"
	echo "Downloading kernel sources from Nvidia to ${1}"
	wget -O public_sources.tbz2 https://developer.nvidia.com/embedded/dlc/public_sources_Nano 
	tar -xf public_sources.tbz2
	tar -xf public_sources/kernel_src.tbz2
	pushd kernel/kernel-4.9
}

function configure_patch_kernel()
{
	echo "Applying current running kernel config"
	zcat /proc/config.gz > .config

	echo "Copying current Tegra firmware into new kernel build env"
	cp /lib/firmware/tegra21x_xusb_firmware ./firmware/

	echo "Updating kernel configuration to support zswap"

	#Select: Enable frontswap to cache swap pages if tmem is present
	sed -i '/CONFIG_FRONTSWAP/c\CONFIG_FRONTSWAP=y' .config

	#Select: Compressed cache for swap pages (EXPERIMENTAL) (NEW)
	sed -i '/CONFIG_ZPOOL/c\CONFIG_ZPOOL=y' .config

	#Select: Low (Up to 2x) density storage for compressed pages
	sed -i '/CONFIG_ZBUD/c\CONFIG_ZBUD=y' .config

	# Enable the extra firmware blobs
	sed -i '/CONFIG_EXTRA_FIRMWARE/c\CONFIG_EXTRA_FIRMWARE=tegra21x_xusb_firmware' .config

	# This wasn't part of the default config. Enabling the extra firmware adds this.
	# TODO - make a function to add or update keys and values
	if ! grep "CONFIG_EXTRA_FIRMWARE_DIR" ".config" ; then
	  echo 'CONFIG_EXTRA_FIRMWARE_DIR=firmware' >> .config
	else
	  sed -i '/CONFIG_EXTRA_FIRMWARE_DIR/c\CONFIG_EXTRA_FIRMWARE_DIR=firmware' .config
	fi

	echo "Patching zswap ..."
	PATCH_SRC=a85f878b443f8d2b91ba76f09da21ac0af22e07f.patch
	wget "https://github.com/torvalds/linux/commit/${PATCH_SRC}"
	patch -p1 < "${PATCH_SRC}"

	sed -i 's/memset_l(page, value, PAGE_SIZE \/ sizeof(unsigned long));/memset(page, value, PAGE_SIZE);/g' mm/zswap.c
}

function build_kernel()
{
	echo "Building custom kernel .."

	NPROC=$(grep -c processor < /proc/cpuinfo )
	NPROC=$((++NPROC))
	printf "\nUsing %d cores.\n" "${NPROC}"
	
	# This uses the current config but sets all the answers to the default value (so we don't get prompted)
	make olddefconfig

	# Build using all cores + 1 (recommended)
	make -j${NPROC}

	# Install the modules
	sudo make modules_install
}

function install_kernel()
{
    # Back up the old kernel.
	sudo cp /boot/Image /boot/Image.dist

	# Copy the new kernel into the boot directory
	sudo cp arch/arm64/boot/Image /boot
}

function abort()
{
	echo "Caught signal."
	if [ -n "${KERNEL_SOURCE_NO_DELETE}" ]; then
		echo "KERNEL_SOURCE_NO_DELETE specified. Not cleaning up source."
	else
		echo "KERNEL_SOURCE_NO_DELETE not specified. Removing kernel source ..."
		rm -rf "{KERNEL_SOURCE_PATH}"
	fi

	echo "Aborted."
}

function setup_partition_table()
{
	# The size in percentage to allocate to the swap partition.
	# The root partition will use the remaining space.
	ALLOC_SWAP_SIZE_PERCENT=20

	# The maximum swaw size to allocate if the percentage specified of the above exceeds this amount to constrain it to.
	MAX_SWAP_SIZE_GB=8
	# TODO autodetect /dev/sda.
	#if [ -f /dev/sda ]; then
	#	sudo dd if=/dev/zero of=/dev/sda bs=1M count=1
	#else
	#	echo "Couldn't find /dev/sda. Auto-detection not done. Please update script manually for now."
	#fi

	# TODO handle the case where the device is less than 1GB (G not found). Bail.
	echo "Calculating disk size."
	DISK_SIZE=$(lsblk /dev/sda --output SIZE | grep -v SIZE | cut -d'G' -f1)

	SWAP_SIZE=$(echo ${DISK_SIZE}*${ALLOC_SWAP_SIZE_PERCENT}/100 | bc)

	# Limit the swap size to 8GB maximum.
	if (( SWAP_SIZE > SWAP_SIZE_MAX_GB )); then
		printf "\nSwap size maxium is %.2fGB. Limit applied.\n" "${MAX_SWAP_SIZE_GB}"
		SWAP_SIZE=${MAX_SWAP_SIZE_GB}
		# FIX THIS
		ROOT_SIZE=$((DISK_SIZE-MAX_SWAP_SIZE_GB))
	else
		ROOT_SIZE=$(echo "${DISK_SIZE}*(1-(${ALLOC_SWAP_SIZE_PERCENT})/100)" | bc)
	fi


	printf "\nDisk size is %.2fGB\n" "${DISK_SIZE}"
	printf "\nUsing %.2fGB for root and %.2fGB for swap.\n" "${ROOT_SIZE}" "${SWAP_SIZE}"	
	
	# TODO create partition table and create root and swap partitions.
	# parted --script /dev/sda
}


function setup_root()
{
	sudo mkfs.ext4 /dev/sda1
	sudo mkswap /dev/sda2
	sudo mkdir /mnt/root
	sudo mount /dev/sda1 /mnt/root
	sudo mkdir /mnt/root/proc
	sudo apt -y install rsync
	sudo rsync -axHAWX --numeric-ids --info=progress2 --exclude=/proc / /mnt/root
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	set -e

	trap abort SIGHUP SIGINT SIGTERM

	KERNEL_SOURCE_PATH="${KERNEL_SOURCE_PATH:-/tmp}"
	download_kernel_sources "${KERNEL_SOURCE_PATH}"
	
	configure_patch_kernel
	build_kernel
	
	install_kernel

	popd
	popd
	echo "Done - reboot !"

	# TODO - detect if the custom kernel is installed and run setup root automatically.
	# Add an environment variable to enforce skipping the scheck to force kernel re-compile and install.
	echo "After rebooting source this script and run setup_partion_table && setup_root"
	set +e
else
	echo "Script sourced. Call functions manually."
fi

