#!/usr/bin/env bash

set -e

# Inspired by - https://syonyk.blogspot.com/2019/04/nvidia-jetson-nano-desktop-use-kernel-builds.html?m=1

# TODO 
# Shellcheck
# Refactor with functions etc
# Setup the filesystem and partitions


pushd /tmp
echo "Downloading kernel sources from Nvidia"
wget -O public_sources.tbz2 https://developer.nvidia.com/embedded/dlc/public_sources_Nano 
tar -xf public_sources.tbz2
tar -xf public_sources/kernel_src.tbz2
pushd kernel/kernel-4.9

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
if [ ! grep 'CONFIG_EXTRA_FIRMWARE_DIR' .config ]; then
  echo 'CONFIG_EXTRA_FIRMWARE_DIR=firmware' >> .config
else
  sed -i '/CONFIG_EXTRA_FIRMWARE_DIR/c\CONFIG_EXTRA_FIRMWARE_DIR=firmware' .config
fi

echo "Patching zswap ..."
PATCH_SRC=a85f878b443f8d2b91ba76f09da21ac0af22e07f.patch
wget "https://github.com/torvalds/linux/commit/${PATCH_SRC}"
patch -p1 < "${PATCH_SRC}"


sed -i 's/memset_l(page, value, PAGE_SIZE \/ sizeof(unsigned long));/memset(page, value, PAGE_SIZE);/g' mm/zswap.c

echo "Building custom kernel"

# This uses the current config but sets all the answers to the default value (so we don't get prompted)
make olddefconfig

# Build using all cores + 1 (recommended)
make -j5

# Install the modules
sudo make modules_install

# Backing up the old boot image ?
sudo cp /boot/Image /boot/Image.dist

# Copy the new kernel into the boot directory
sudo cp arch/arm64/boot/Image /boot

popd
popd
echo "Done - reboot !"

# TODO setting up the file system and copying over the root filesystem
