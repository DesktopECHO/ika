#!/usr/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

export HOME="${TEST_ROOT}/home"
export CVD_HOME_DIR="${TEST_ROOT}/ika"
export CVD_PRODUCT_OUT="${TEST_ROOT}/product"
mkdir -p "${HOME}" "${CVD_HOME_DIR}" "${CVD_PRODUCT_OUT}"

source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

inst="${CVD_INSTANCE_DIR}"
mkdir -p "${inst}"
# Cuttlefish names the disk's files through links, as /var/tmp/cvd/<id>/artifacts/0
# and /var/tmp/cvd/<id>/home do.
artifacts="${TEST_ROOT}/cvd/artifacts/0"
mkdir -p "${artifacts}"
ln -s "${CVD_HOME_DIR}" "${TEST_ROOT}/cvd/home"
home_inst="${TEST_ROOT}/cvd/home/cuttlefish/instances/cvd-1"

old='2026-11-01 00:00'
disk_time='2026-11-02 00:00'
new='2026-11-03 00:00'

# A disk with boot (64 KiB partition), metadata, super (1 MiB partition) and userdata.
setup_disk() {
  rm -rf "${inst:?}"/* "${CVD_PRODUCT_OUT:?}"/* "${artifacts:?}"/*
  head -c 65536 /dev/zero > "${CVD_PRODUCT_OUT}/boot.img"
  head -c 700000 /dev/zero > "${CVD_PRODUCT_OUT}/super.img"
  head -c 8192 /dev/zero > "${inst}/metadata"
  head -c 8192 /dev/zero > "${inst}/userdata.img"
  ln -s "${CVD_PRODUCT_OUT}/boot.img" "${artifacts}/boot.img"
  ln -s "${CVD_PRODUCT_OUT}/super.img" "${artifacts}/super.img"
  printf '%s\n' crosvm "${artifacts}/boot.img" "${home_inst}/metadata" \
    "${artifacts}/super.img" "${home_inst}/userdata.img" > "${inst}/os_composite_disk_config.txt"
  python3 - "${inst}/os_composite_gpt_header.img" <<'PY'
import struct, sys
spans = [65536, 8192, 1048576, 8192]
h = bytearray(20480)
h[512:520] = b"EFI PART"
struct.pack_into("<II", h, 512 + 0x50, 128, 128)
lba = 40
for i, span in enumerate(spans):
    e = 1024 + i * 128
    h[e:e + 16] = bytes([i + 1]) * 16
    struct.pack_into("<QQ", h, e + 32, lba, lba + span // 512 - 1)
    lba += span // 512
open(sys.argv[1], "wb").write(h)
PY
  head -c 20480 /dev/zero > "${inst}/os_composite_gpt_footer.img"
  printf 'composite_disk' > "${inst}/os_composite.img"
  printf 'qcow' > "${inst}/overlay.img"
  touch -h -d "${old}" "${CVD_PRODUCT_OUT}"/*.img "${inst}/metadata" "${inst}/userdata.img"
  touch -d "${disk_time}" "${inst}"/os_composite*.img "${inst}/overlay.img"
}

starts() { ! composite_disk_rebuild_reason os_composite >/dev/null; }

# The GPT reader returns the partition sizes in table order.
setup_disk
[[ "$(composite_partition_sizes "${inst}/os_composite_gpt_header.img" | tr '\n' ' ')" == "65536 8192 1048576 8192 " ]] || \
  fail "partition sizes: $(composite_partition_sizes "${inst}/os_composite_gpt_header.img" | tr '\n' ' ')"

# Nothing newer than the disk: it is left alone.
setup_disk
refresh_composite_disk_mtimes os_composite
starts || fail "an unchanged disk would be rebuilt"
[[ ! "${inst}/os_composite.img" -nt "${inst}/os_composite_gpt_footer.img" ]] || fail "an unchanged disk was touched"

# A ROM update whose images fit their partitions keeps the disk and the data.
setup_disk
head -c 900000 /dev/zero > "${CVD_PRODUCT_OUT}/super.img"
touch -d "${new}" "${CVD_PRODUCT_OUT}/boot.img" "${CVD_PRODUCT_OUT}/super.img" "${inst}/metadata"
starts && fail "the test setup did not make the disk stale"
refresh_composite_disk_mtimes os_composite
starts || fail "a ROM update that fits the disk would still rebuild it: $(composite_disk_rebuild_reason os_composite)"
[[ ! "${inst}/os_composite.img" -nt "${inst}/overlay.img" ]] || fail "overlay.img was left older than the disk"

# An image that outgrew its partition leaves the disk stale: ika start refuses.
setup_disk
head -c 1048577 /dev/zero > "${CVD_PRODUCT_OUT}/super.img"
touch -d "${new}" "${CVD_PRODUCT_OUT}/super.img"
refresh_composite_disk_mtimes os_composite
[[ "$(composite_disk_rebuild_reason os_composite)" == *super.img* ]] || \
  fail "an image larger than its partition was accepted"

# A newer file that is not an installed ROM image is not covered.
setup_disk
touch -d "${new}" "${inst}/userdata.img"
refresh_composite_disk_mtimes os_composite
starts && fail "a newer userdata.img was accepted"

# Without a readable partition table, a newer ROM image is not accepted.
setup_disk
touch -d "${new}" "${CVD_PRODUCT_OUT}/boot.img"
head -c 20480 /dev/zero > "${inst}/os_composite_gpt_header.img"
touch -d "${disk_time}" "${inst}/os_composite_gpt_header.img"
refresh_composite_disk_mtimes os_composite
starts && fail "a ROM image was accepted without a partition table"

# metadata rewritten at boot, named through the link, is still recognised.
setup_disk
touch -d "${new}" "${inst}/metadata"
refresh_composite_disk_mtimes os_composite
starts || fail "a newer metadata named through a link stopped the start"

printf 'PASS: a ROM update keeps Android'"'"'s disk when its images fit\n'
