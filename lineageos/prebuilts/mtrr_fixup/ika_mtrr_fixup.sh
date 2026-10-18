#!/vendor/bin/sh
#
# Copyright (C) 2026 LineageOS Desktop Project
# SPDX-License-Identifier: Apache-2.0
#
# Removes the write-combining variable MTRRs the x86_64 bootloader leaves.
# U-Boot (bootloader.crosvm) programs one with a mask for fewer physical address
# bits than the vCPU has; Linux widens the mask, so it covers all of memory.
# Linux then maps device memory it is asked to map write-back (virtio-media's
# decoder buffers, for one) uncached-minus, and AMD hosts honour that, so CPU
# access to it runs about 100 times slower. Linux sets write-combining through
# PAT, never through MTRRs, so nothing depends on these entries.

[ -e /proc/mtrr ] || exit 0

# Shell builtins only: a vendor domain may not run /system/bin tools. Read every
# entry before changing any.
regs=
while read -r line; do
  case "$line" in
    reg*write-combining*)
      reg=${line%%:*}
      regs="$regs $((10#${reg#reg}))"
      ;;
  esac
done < /proc/mtrr

for reg in $regs; do
  echo "disable=$reg" > /proc/mtrr
done
exit 0
