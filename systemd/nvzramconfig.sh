#!/usr/bin/env bash


# Notes / TODO

# - zram supports discard - https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/tree/drivers/block/zram/zram_drv.c?h=v4.14.152#n1114
# - Make zram use zstd as it's faster for decompressing and almost as fast as lzo for compressing and offers better compression ratio (to confirm) in general (https://github.com/facebook/zstd)
# - Find a way to update the kernel so I can use zstd or even lzo-rle (https://www.phoronix.com/scan.php?page=news_item&px=ZRAM-Linux-5.1-Better-Perform)
# - Make the Jetson desktop script I've created use this
# - Make the Jetson desktop script set the optimal values for vm.swappiness and vm.vfs_cache_pressure
# - Consider adding the zswap entries to /etc/fstab
# - Do I have do do anything to use this for other stuff such as /tmp? I suppose mounting /tmp on tmpfs will work. If memory becomes low it will page in/out with zram anyway.

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

	# TODO come from key value file or JSON via jq.
	COMP_ALGO=lzo
	
	# The default (on my setup) was lzo. From what I could find lzo is much slower for decompression.
	# e.g https://catchchallenger.first-world.info/wiki/Quick_Benchmark:_Gzip_vs_Bzip2_vs_LZMA_vs_XZ_vs_LZ4_vs_LZO 0.4s (lz4) vs 1.5s (lzo)
	# On the link above, lzo did use a LOT less memory though. 0.7MB (lzo) vs 12MB (lz4).
	#
	# Why did Nvidia choose this value (or is it the default for this module)?
	# Find out the best algorithm for the Jetson Nano and put it here. In the link above, lzo-rle is up to 30% faster than lzo. Add run length encoding version to my kernel.

	# Detect available compression algorithms and ensure that the requested algorithm is supported. If not, fall back to lzo.
	# AVAILABLE_COMP_ALGO=$(</proc/kallsyms cut -d " " -f 3 | grep -xF -e gunzip -e bzip2 -e unlzma -e unxz -e unlzo -e unlz4 -e std)
	# Example output.
	# gunzip
	# unlz4
	# unlzma
	# unlzo
	# unxz

	logger "Setting zram (de)compression algorithm to ${COMP_ALGO}"
	echo "${COMP_ALGO}" > /sys/block/zram${CORE_IDX}/comp_algorithm

	logger "Creating zram swap device ${SWAP_DEVICE} ..."
	PAGE_SIZE_BYTES=$((ZRAM_MEMORY_SIZE_KB * 1024))


	mkswap "${SWAP_DEVICE}" --label "zram${CORE_IDX}" --force
	# Page size below errors out with out of range. Seems correct to me ..
	#mkswap "${SWAP_DEVICE}" --label "zram${CORE_IDX}" --force --pagesize ${PAGE_SIZE_BYTES}
		
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
