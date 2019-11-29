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

DEV=/dev/sda

# Downloads the Nvidia kernel sources to the specified directory.
function download_kernel_sources()
{
	if [ -z "${1}" ]; then
		echo "No target specified to download to."
		exit 1
	fi

	pushd "${1}"
	echo "Downloading kernel sources from Nvidia to ${1}"
	wget -O public_sources.tbz2 https://developer.nvidia.com/embedded/dlc/public_sources_Nano 
	tar -xf public_sources.tbz2
	tar -xf public_sources/kernel_src.tbz2
	pushd kernel/kernel-4.9
}

function configure_patch_kernel()
{
	# Get the current kernel configuration to use as a basis for customization.
	echo "Applying current running kernel config"
	zcat /proc/config.gz > .config

	# Copy the Nvidia firmware blobs into the build environment path.
	echo "Copying current Tegra firmware into new kernel build env"
	cp /lib/firmware/tegra21x_xusb_firmware ./firmware/

	echo "Updating kernel configuration to support zswap"

	# Select: Enable frontswap to cache swap pages if tmem is present.
	sed -i '/CONFIG_FRONTSWAP/c\CONFIG_FRONTSWAP=y' .config

	# Select: Compressed cache for swap pages (EXPERIMENTAL) (NEW).
	sed -i '/CONFIG_ZPOOL/c\CONFIG_ZPOOL=y' .config

	# Select: Low (Up to 2x) density storage for compressed pages.
	sed -i '/CONFIG_ZBUD/c\CONFIG_ZBUD=y' .config

	# Enable the extra firmware blobs.
	sed -i '/CONFIG_EXTRA_FIRMWARE/c\CONFIG_EXTRA_FIRMWARE=tegra21x_xusb_firmware' .config

	# This wasn't part of the default config. Enabling the extra firmware adds this.
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

# Compiles the custom kernel.
function build_kernel()
{
	echo "Building custom kernel .."

	NPROC=$(grep -c processor < /proc/cpuinfo )
	NPROC=$((++NPROC))
	printf "\nUsing %d cores.\n" "${NPROC}"
	
	# This uses the current config but sets all the answers to the default value (so we don't get prompted).
	make olddefconfig

	# Build using all cores + 1 (recommended).
	make -j${NPROC}

	# Install the modules.
	sudo make modules_install
}

# Install the kernel + makes a backup of the current kernel.
function install_kernel()
{
	# Back up the old kernel.
	sudo cp /boot/Image /boot/Image.dist

	# Copy the new kernel into the boot directory.
	sudo cp arch/arm64/boot/Image /boot
}

# Handles various interrupts to safely cleanup.
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


# Sets up the partition table.
function setup_partition_table()
{
	if [ -n "${1}" ]; then
		printf "No target device specified.\n"
		exit 1
	fi

	DEV="${1}"
	MIN_DISK_SIZE_GB=32

	# The size in percentage to allocate to the swap partition.
	# The root partition will use the remaining space.
	ALLOC_SWAP_SIZE_PERCENT=20

	# The maximum swap size to allocate if the percentage specified of the above exceeds this amount to constrain it to.
	MAX_SWAP_SIZE_GB=8
	
	if [ -f "${DEV}" ]; then
		# TODO handle the case where the device is less than 1GB (G not found). Bail.
		echo "Calculating partition sizes ..."
		DISK_SIZE=$(lsblk "${DEV}" --output SIZE | grep -v SIZE | cut -d'G' -f1)
		
		# Ensure the specified device is large enough to support being a root + swap target.
		if (( DISK_SIZE < MIN_DISK_SIZE_GB )); then
			printf "\nThe specified device is too small.%dG is the minimium size supported.\n" "${MIN_DISK_SIZE_GB}"
			exit 1
		fi
	else
		printf "Couldn't find %s.\nAuto-detection not done. Please update script manually for now.\n" "${DEV}"
		exit 1
	fi


	# Nuke the current contents.
	printf "\nErasing contents of %s\n" "${DEV}"
	sudo dd if=/dev/zero of="${DEV}" bs=1M count=1

	SWAP_SIZE=$(echo "${DISK_SIZE}*${ALLOC_SWAP_SIZE_PERCENT}/100" | bc --mathlib)

	# Limit the swap size to 8GB maximum.
	if (( $(echo "SWAP_SIZE > SWAP_SIZE_MAX_GB" | bc --mathlib) )); then
		printf "\nSwap size maxium is %.2fGB. Limit applied.\n" "${MAX_SWAP_SIZE_GB}"
		SWAP_SIZE=${MAX_SWAP_SIZE_GB}
		ROOT_SIZE=$((DISK_SIZE-MAX_SWAP_SIZE_GB))
	else
		ROOT_SIZE=$(echo "${DISK_SIZE}*(1-(${ALLOC_SWAP_SIZE_PERCENT})/100)" | bc --mathlib)
	fi

	printf "\nDisk size is %.2fGB\n" "${DISK_SIZE}"
	printf "\nUsing %.2fGB for root and %.2fGB for swap.\n" "${ROOT_SIZE}" "${SWAP_SIZE}"	

	# Create GPT partition table.
	sudo parted --script "${DEV}" mklabel gpt

	# Create the root partition.
	sudo parted --script "${DEV}" mkpart primary 0 "${ROOT_SIZE}"

	# Create swap.
	sudo parted --script "${DEV}" "${ROOT_SIZE}" 100%
}


# Creates filesystems + sets up root filesystem and swap.
function setup_filesystem()
{
	if [ -n "${1}" ]; then
		printf "No target device specified.\n"
		exit 1
	fi

	DEV="${1}"
	
	# TODO confirm if ext4 is the best for this ARM SOC (Check XFS / JFS etc).
	printf "Making root filesystem ...\n"
	sudo mkfs.ext4 "${DEV}1"

	printf "Making swap filesystem ...\n"
	sudo mkswap "${DEV}2"
	
	printf "Mounting filesystems ready for copy ...\n"
	sudo mkdir /mnt/root
	sudo mount "${DEV}1" /mnt/root
	sudo mkdir /mnt/root/proc

	# Sync the current root file system onto the new device.
	sudo apt -y install rsync
	sudo rsync -axHAWX --numeric-ids --info=progress2 --exclude=/proc / /mnt/root
}

# Setups up which root device to boot from and updates the filesystem table to mount zswap.
function setup_boot_swap()
{
	if [ -n "${1}" ]; then
		printf "No target device specified.\n"
		exit 1
	fi

	DEV="${1}"

	sudo sed -i "s/mmcblk0p1/${DEV}1/" /boot/extlinux/extlinux.conf
	sudo sed -i "s/rootwait/rootwait zswap.enabled=1/" /boot/extlinux/extlinux.conf
	printf "\nUpdated boot config to boot from %s." "${DEV}1"

	echo "/dev/${DEV}2            none                  swap           \
		defaults                                     0 1" | sudo tee -a /etc/fstab

	printf "\nUpdated /etc/fstab to mount swap at %s." "${DEV}2"
}


# A simple helper to setup the target device.
function migrate() {
	# TODO - detect if the current kernel is the custom one (or at least check the on-disk one
	# and inform the user they should build the kernel first that supports Zswap.
	setup_partition_table "${DEV}"
	setup_filesystem "${DEV}"
	setup_boot_swap "${DEV}"
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

