#!/usr/bin/env bash


# Notes / TODO

# - zram supports discard - https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/drivers/block/zram/zram_drv.c?h=v4.14.152#n1114
# - Make zram use zstd as it's faster for decompressing and almost as fast as lzo for compressing and offers better compression ratio (to confirm) in general (https://github.com/facebook/zstd)
# - Find a way to update the kernel so I can use zstd or even lzo-rle (https://www.phoronix.com/scan.php?page=news_item&px=ZRAM-Linux-5.1-Better-Perform)
# - Make the Jetson desktop script I've created use this
# - Make the Jetson desktop script set the optimal values for vm.swappiness and vm.vfs_cache_pressure
# - Consider adding the zswap entries to /etc/fstab

# Determine the arguments to use for zram probing depending on the zram version available.
ARGS=$(modinfo zram | grep parm | cut -d':' -f2 | tr -d ' ')

if [ -z ${ARGS} ]; then
	echo "No zram support in your kernel!"
	exit 1
fi

CORES=$(cat /proc/cpuinfo | grep processor | wc -l)

# Load the zram module.
modprobe zram "${ARGS}=${CORES}"

set -x

# TODO read from a key value file or JSON using jq
DIVISOR=1

# Calculate memory to use for each zram device.
TOTAL_MEMORY_MB=$(cat /proc/meminfo | grep MemTotal | cut -d' ' -f9)
ZRAM_MEMORY_SIZE_KB=$(( ${TOTAL_MEMORY_MB} / ${CORES} / ${DIVISOR} * 1024 ))

# Initialise a zram device per processor core (Nvidia's official systemd script that comes with the Nano
# does this for each processor but I don't think there is any sort of "pinning" of the swap to core.
for i in $(seq "${CORES}"); do
	CORE_IDX=$((i - 1))
	SWAP_DEVICE="/dev/zram${CORE_IDX}"

	# Check if zram swap is already being used.	
	if swapon --show=NAME --noheadings | grep "${SWAP_DEVICE}"; then
		logger "Zram was already enabled for ${SWAP_DEVICE}. Removing ${SWAP_DEVICE}."
		# Flag that this swap device was previously enabled.
		SWAP_ENABLED=1
		swapoff "${SWAP_DEVICE}"	
	fi

	# Set zram size and compression algorithm.
	echo "${ZRAM_MEMORY_SIZE_KB}" > "/sys/block/zram${CORE_IDX}/disksize"
	echo lz4 > /sys/block/zram${CORE_IDX}/comp_algorithm

	# Log to system log
	logger "Creating zram swap device ${SWAP_DEVICE} ..."
	mkswap "${SWAP_DEVICE}" --label "zram${CORE_IDX}" --force --pagesize ${ZRAM_MEMORY_SIZE}
		
	# TODO read from key value file or JSON via jq.
	PRIORITY=5

	logger -s "Enabling swap device ${SWAP_DEVICE} ..."

	# If the swap device was already enabled then we need to enable it with custom arguments for subsequent enablement.
	if [[ ${SWAP_ENABLED} -eq 1 ]]; then
		# --fixpgsz - reinitialize the swap space if necessary
		swapon --discard --priority ${PRIORITY} --fixpgsz "${SWAP_DEVICE}"
	else
		swapon --discard --priority ${PRIORITY} "${SWAP_DEVICE}"
	fi

	logger -s "Swap device ${SWAP_DEVICE} enabled."

done

set +x
