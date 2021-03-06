#!/usr/bin/env bash

# Simple script to setup the Nvidia Nano for desktop use.

# Inspired by - https://syonyk.blogspot.com/2019/04/nvidia-jetson-nano-desktop-use-kernel-builds.html?m=1

# TODO 
# - Create usage help such as
# ./nano_desktop.sh for interactive and automated
# ./nano_desktop.sh setup_partition_table /dev/sda (for a single function)
# ./nano_desktop.sh migrate /dev/sda (for a set of operations)

# - Enforce environment variables or arguments or add prompts so options are confirmed / safe and desired by the user.
# - Improve output
# - Check after the rsync is complete (basic check of du etc) or consider doing a SHA check on source and dest.
# - Support Raspberry Pi (ODroid too possibly).

DEV=/dev/sda

# Downloads the Nvidia kernel sources to the specified directory.
function download_kernel_sources()
{
	if [ -z "${1}" ]; then
		echo "No target specified to download to."
		return 1
	fi

	pushd "${1}"
	echo "Downloading kernel sources from Nvidia to ${1}"
	wget -O public_sources.tbz2 https://developer.nvidia.com/embedded/dlc/public_sources_Nano 
	tar -xf public_sources.tbz2
	tar -xf public_sources/kernel_src.tbz2
	pushd kernel/kernel-4.9
}

# Performs kernel patching and configuration.
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

	# https://www.kernel.org/doc/Documentation/timers/NO_HZ.txt

	# TODO consider altering the CONFIG_HZ from 250 to 1000 for lower latency (we don't care about throughput as much)
	# Default - CONFIG_PREEMPT=y is already set for  a full pre-emptive kernel.
	# TODO confirm optimal timer interrupt configuration and tweak.
       	# Default - CONFIG_NO_HZ_IDLE=y (when the processor is idling, stop sending scheduling-clock interrupts to reduce power (no advantage).
	# Default - CONFIG_NO_HZ=y 
	# Default - CONFIG_NO_HZ_COMMON=y	
	
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
	if [ ! -f arch/arm64/boot/Imge ]; then
		printf "\nKernel not built or in the wrong directory. Please change to the kernel source directory.\n"
		return 1
	fi

	# Back up the old kernel.
	sudo cp /boot/Image /boot/Image.backup

	# Copy the new kernel into the boot directory.
	sudo cp arch/arm64/boot/Image /boot

	# Replace the default /boot/extlinux.conf file with the one in this repository that allows booting from the stock or custom kernel.
	# TODO - generate the stock kernel line dynamically should Nvidia change their kernel version.
	sudo cp boot/Nvidia/extlinux.conf.custom /boot/extlinux/extlinux.conf
}

# Sets up the partition table.
function setup_partition_table()
{
	if [ -z "${1}" ]; then
		printf "No target device specified.\n"
		return 1
	fi

	DEV="${1}"
	
	if ! stat "${DEV}" 1>/dev/null 2>&1 ; then
		printf "\nSpecified device %s doesn't exist !\n" "${DEV}"
		return 1
	fi
	
	MIN_DISK_SIZE_GB=32

	# The size in percentage to allocate to the swap partition.
	# The root partition will use the remaining space.
	ALLOC_SWAP_SIZE_PERCENT=20

	# The maximum swap size to allocate if the percentage specified of the above exceeds this amount to constrain it to.
	MAX_SWAP_SIZE_GB=8
	
	# TODO handle the case where the device is less than 1GB (G not found). Bail.
	printf "\nCalculating partition sizes ...\n"
	DISK_SIZE_GB=$(lsblk "${DEV}" --output SIZE | grep -v SIZE -m1 | cut -d'G' -f1)
	DISK_SIZE_GB=$(printf "%.0f" "${DISK_SIZE_GB}")


	# Ensure the specified device is large enough to support being a root + swap target.
	if (( DISK_SIZE_GB < MIN_DISK_SIZE_GB )); then
		printf "\nThe specified device is too small.%dG is the minimium size supported.\n" "${MIN_DISK_SIZE_GB}"
		return 1
	fi

	# Calculate swap size.
	SWAP_SIZE_GB=$(echo "${DISK_SIZE_GB}*${ALLOC_SWAP_SIZE_PERCENT}/100" | bc --mathlib)

	# Convert to integers (note - there should be a nicer way of doing this.
	SWAP_SIZE_GB=$(printf "%.0f" "${SWAP_SIZE_GB}")
	ROOT_SIZE_GB=$(printf "%.0f" "${ROOT_SIZE_GB}")


	# Limit the swap size to 8GB maximum.
	if (( SWAP_SIZE_GB > ROOT_SIZE_GB )); then
		printf  "\nUsing %d%% of the disk capacity (%dGB) for swap exceeds the swap size maximum of %dGB.\n" \
			"${ALLOC_SWAP_SIZE_PERCENT}" "${DISK_SIZE_GB}" "${MAX_SWAP_SIZE_GB}"

		printf "%dGB limit for swap size applied.\n" "${MAX_SWAP_SIZE_GB}"
		SWAP_SIZE_GB=${MAX_SWAP_SIZE_GB}
		ROOT_SIZE_GB=$((DISK_SIZE_GB-MAX_SWAP_SIZE_GB))
	else
		ROOT_SIZE_GB=$(echo "${DISK_SIZE_GB}*(1-(${ALLOC_SWAP_SIZE_PERCENT})/100)" | bc --mathlib)
	fi

	SWAP_SIZE_GB=$(printf "%.0f" "${SWAP_SIZE_GB}")
	ROOT_SIZE_GB=$(printf "%.0f" "${ROOT_SIZE_GB}")


	# TODO align column output.
	printf "\nDetails"
	printf "\n************\n"
	printf "\nDevice = %s" "${DEV}"
	printf "\nDisk capacity = %dGB" "${DISK_SIZE_GB}"
	printf "\nUsing root size = %dGB\nUsing  swap size = %dGB\n\n" "${ROOT_SIZE_GB}" "${SWAP_SIZE_GB}"

	if ! prompt_for_verification "Would you like to proceed (all contents will be destroyed !) ?" ;then
		printf "\nCancelled.\n"
		# TODO - Go through abort function.
		# Restore original environment value.
		set +x
		return 1
	fi


	# Nuke the current contents.
	printf "\nErasing contents of %s\n" "${DEV}"
	sudo dd if=/dev/zero of="${DEV}" bs=1M count=100 1>/dev/null 2>&1

	# Notify the kernel of partition removal.
	sudo partprobe

	# Create GPT partition table.
	printf "\nCreating GPT partition scheme."
	sudo parted --script "${DEV}" mklabel gpt 1>/dev/null

	# Create the swap partition (aligned - using 0% as the start makes parted calculate the aligned start sector).
	printf "\nCreating swap partition."
	sudo parted --script --align=optimal "${DEV}" mkpart SWAP linux-swap 0% "${SWAP_SIZE_GB}G"

	# Create the root partition (aligned).
	printf "\nCreating root partition."
	sudo parted --script --align=optimal "${DEV}" mkpart ROOT ext4 "${SWAP_SIZE_GB}G" 100%

	# Notify the kernel of partition table change.
	printf "\nNotifying kernel of new partition table layout.\n"
	sudo partprobe
}


# Creates filesystems + sets up root filesystem and swap.
function setup_filesystem()
{
	if [ -z "${1}" ]; then
		printf "No target device specified.\n"
		return  1
	fi

	DEV="${1}"

	if ! stat "${DEV}" 1>/dev/null 2>&1 ; then
		printf "\nSpecified device %s doesn't exist !\n" "${DEV}"
		return 1
	fi

	# Make and mount swap if not already mounted.
	if ! mount | grep "${DEV}1" 1>/dev/null ;then
		printf "Making and mounting swap ...\n"
		sudo mkswap "${DEV}1"
		sudo swapon "${DEV}1"
	else
		printf "Swap is already mounted for %s. Skipping ...\n" "${DEV}1"
	fi

	# Make and mount root filesystem if not already mounted.
	if ! mount | grep "${DEV}2}" 1> /dev/null 2>&1 ; then
		printf "Making and mounting root filesystem ...\n"
		# TODO confirm if ext4 is the best for this ARM SOC (Check XFS / JFS etc).
		sudo mkfs.ext4 "${DEV}2" \
			&& sudo mkdir -p /mnt/root \
			&& sudo mount -t ext4 "${DEV}2" /mnt/root

		# Create the proc directory ready for pseudo filesystem. We are excluding it in the rsync.
		sudo mkdir -p /mnt/root/proc
	else
		printf "Root is already mounted for %s. Skipping ...\n" "${DEV}2"
	fi
}

function sync_root()
{
	# Sync the current root file system onto the new device.
	if ! which rsync; then
		sudo apt -y install rsync 1>/dev/null
	fi

	if ! mount | grep /mnt/root ;then
		printf "The target root filesystem doesn't appear to be mounted. Cannot rsync.\n"
		return 1
	fi

	# Get the absolute path to this Git repo.
	GIT_ROOT="$(git rev-parse --show-toplevel)"

	# TODO - determine other places to exclude or include
	# Rsync the current root (excluding the pseudo filesystem + the current Git root.
	printf "\nSyncing the root from MMC to %s ...\n" "${DEV}2"
	sudo rsync \
		--recursive \
		--executability \
		--acls \
		--archive \
		--xattrs \
		--quiet \
		--exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found","${GIT_ROOT}"} \
		/ \
		/mnt/root
}

# Setups up which root device to boot from and updates the filesystem table to mount zswap.
function setup_boot_swap()
{
	if [ -z "${1}" ]; then
		printf "No target device specified.\n"
		return 1
	fi

	DEV="${1}"

	if ! stat "${DEV}" 1>/dev/null 2>&1 ; then
		printf "\nSpecified device %s doesn't exist !\n" "${DEV}"
		return 1
	fi

	# Note triple check everything before enabling this as future booting will not work if I break it.
	#sudo sed -i "s/mmcblk0p1/${DEV}2/" /boot/extlinux/extlinux.conf
	#sudo sed -i "s/rootwait/rootwait zswap.enabled=1/" /boot/extlinux/extlinux.conf
	printf "\nUpdated boot config to boot from %s." "${DEV}2"

	echo "/dev/${DEV}1            none                  swap           \
		defaults                                     0 1" | sudo tee -a /etc/fstab

	printf "\nUpdated /etc/fstab to mount swap at %s." "${DEV}1"
}


# A simple helper to setup the target device.
function migrate() {
	DEV="${1}"

	if ! stat "${DEV}" 1>/dev/null 2>&1 ; then
		printf "\nSpecified device %s doesn't exist !\n" "${DEV}"
		exit 0
	fi

	# TODO - detect if the current kernel is the custom one (or at least check the on-disk one
	# and inform the user they should build the kernel first that supports Zswap.
	
	if ! setup_partition_table "${DEV}" ; then
		echo "Couldn't set up partition table. Cancelled."
		exit 1
	fi

	if ! setup_filesystem "${DEV}" ; then
		echo "Couldn't set up filesystems. Cancelled."
		exit 1
	fi

	if ! sync_root ; then
		echo "Couldn't sync root filesystem. Cancelled."
		exit 1
	fi


	if ! setup_boot_swap "${DEV}" ; then
		echo "Couldn't set up boot and mount configuration. Cancelled."
		exit 1
	fi

}

# A simple helper to setup the custom kernel.
function setup_kernel() {

	KERNEL_SOURCE_PATH="${KERNEL_SOURCE_PATH:-/tmp}"
	download_kernel_sources "${KERNEL_SOURCE_PATH}"
	
	configure_patch_kernel
	build_kernel
	
	install_kernel
}

# Provides an interactive prompt to the user
# arg1 = The message to display
# arg2 = The prompt to use
prompt_for_verification()
{
  local default_message
  local default_prompt

  default_message="Are you sure?"
  default_prompt="[y/n] >"

  # Use the provided message or default to Are you sure ?
  message="${1:-$default_message}"
  printf "\\n%s \\n" "${message}"

  # Use the provided prompt or default to [y/n]
  prompt="${2:-$default_prompt}"

  for (( ; ; ))
  do
    read -p "${prompt}" -r

    if [[ ${REPLY} =~ ^[Yy]$ ]]
    then
      return 0
    elif [[ ${REPLY} =~ ^[Nn]$ ]]
    then
      return 1
    else
      printf "\nInvalid input. Please enter only n/N or y/Y\n"
    fi
  # Keep looping while input is invalid.
  done
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

	# TODO sigterm all child processes so we don't leave mess.
	sudo kill "$(ps -s $$ -o pid=)"

	# Attempt to cleanly kill any stray rsync processes
	# TODO - ensure that we are the parent of them so we don't kill rsync started by another app.
	sudo kill -s SIGTERM "$(sudo pidof rsync)"
	sleep 1
	# Kill any remaining.
	sudo kill -s SIGKILL "$(sudo pidof rsync)"


	# TODO get the original state of the error option and don't just assume this script knows best.
	set +e
	echo "Aborted."
}


# Regardless of the parts of this script that are executed, we want to ensure that we cleanup stray processes such as rsync.
trap abort SIGHUP SIGINT SIGTERM

# Check if the script is being executed with arguments or not.

# If the user has specified arguments then they desire more granular control, otherwise automate the process.
if [ -n "${1}" ]; then
	# https://stackoverflow.com/a/16159057 - credit.

	# Example usage - ./nano_desktop.sh setup_partition_table /dev/sda
	# Exand the arguments of the command line to try to call the function specified.

	# Check if the function exists (Bash specific).
	if declare -f "$1" > /dev/null; then
		# call arguments verbatim
		"${@}"
	else
		# Show error message as the function doesn't exist.
		echo "'${1}' is not a known function name" >&2
		exit 1
	fi
else
	# TODO get the current shell state off error opt to restore on completion.

	set -e

	CUSTOM_KERNEL=0
	
	# Check if the current kernel that is running is the custom kernel or that a compiled custom one exists in /boot.
	# If either is true, we can setup the target device as the kernel supports the requisite functionality.
	if ! uname -r | grep tegra ; then
		# The current running kernel is already custom.
		# Assume the running kernel supports the features we need - TODO check features are enabled.
		printf "\nThe current kernel is already custom. You don't need to re-compile (assuming it meets the requirements).\n"
		CUSTOM_KERNEL=1
	else
		# Attempt to find the version from the kernel image on disk.

		# (No tools such as mk-image or 'file' returned the kernel version from the image. Find it using grep).
		KERNEL_VERSION=$(grep -a 'Linux version' -m1 /boot/Image | cut -d' ' -f3)
	        printf "\nThe on-disk kernel image shows version %s.\n" "${KERNEL_VERSION}"
		if ! echo "${KERNEL_VERSION}" | grep 'tegra' ; then
			printf "\nThe on-disk kernel is already custom. You don't need to re-compile (assuming it meets the requirements).\n"
			CUSTOM_KERNEL=1
		fi

	fi

	if [ ${CUSTOM_KERNEL} -eq 1 ]; then
		if prompt_for_verification "Would you like to proceed setting up ${DEV} ?" ; then
			migrate "${DEV}"
			exit 0
		fi

		if ! prompt_for_verification "Would you like to re-compile anyway ?" ; then
			printf "\nCancelled.\n"
			exit 0
		fi
	fi


	# Download source, patch, configure, compile and install the kernel.
	setup_kernel

	# If the user is starting off from the stock kernel proceed to migration after compliation has completed.
	if [ ${CUSTOM_KERNEL} -eq 0 ]; then
		if prompt_for_verification "Would you like to proceed setting up ${DEV} ?" ; then
			migrate "${DEV}"
			exit 0
		fi
	fi

	echo "Done - reboot !"
	
	# TODO restore the original value. Don't assume the script knows best.
	set +e
fi

