#!/bin/sh

find_uboot() {
    for candidate in \
        /usr/lib/u-boot/qemu_arm64/u-boot.bin \
        /usr/share/uboot/qemu_arm64/u-boot.bin \
        /usr/share/uboot/qemu-arm64/u-boot.bin; do
        if [ -f "${candidate}" ]; then
            echo "${candidate}"
            return 0
        fi
    done
    find /usr -type f \( -path '*/qemu_arm64/u-boot.bin' -o -path '*/qemu-arm64/u-boot.bin' \) 2>/dev/null | head -n 1
}

IMG_ORIG="${FEDORA_IMAGE:-Fedora-Cloud-Base-Generic-42-1.1.aarch64.qcow2}"
uboot="$(find_uboot)"
tmpflash="uboot_qemu_flash.img"
CIDATA="gigabyte-cidata.iso"

if [ -z "${uboot}" ]; then
    echo "failed to find qemu arm64 u-boot image" >&2
    exit 1
fi

# Make a copy if qcow2 file.
IMG_NEW="$(basename -s .qcow2 ${IMG_ORIG})-instance-1.qcow2"
cp -f "${IMG_ORIG}" "${IMG_NEW}"

# Enlarge disk size
qemu-img resize "${IMG_NEW}" +20G

# create Flash image for storing U-boot variables.
if [ ! -e "${tmpflash}" ]; then
    qemu-img create -f raw "${tmpflash}" 64M
fi

# Run qemu
qemu-system-aarch64 \
    -machine virt \
    -cpu cortex-a57 \
    -nographic \
    -netdev user,id=net0,hostfwd=tcp::35555-:5555,hostfwd=tcp::33322-:22 \
    -device virtio-net-pci,mac=50:54:00:00:00:56,netdev=net0,id=net0-dev \
    -object rng-builtin,id=objrng0 \
    -device virtio-rng-pci-non-transitional,rng=objrng0,id=rng0,max-bytes=1024,period=2000 \
    -drive if=virtio,format=raw,file="${CIDATA}" \
    -drive if=pflash,format=raw,index=1,file="${tmpflash}" \
    -drive file="${IMG_NEW}",format=qcow2,if=none,aio=threads,id=drive-virtio-disk0 -device virtio-blk-pci,drive=drive-virtio-disk0,iommu_platform=true,disable-legacy=on \
    -object cryptodev-backend-builtin,id=cryptodev0 \
    -device virtio-crypto-pci,id=crypto0,cryptodev=cryptodev0 \
    -device virtio-iommu-pci \
    -device virtio-gpu-pci \
    -m 1G \
    -bios "${uboot}"
