#!/usr/bin/bash

# enable_gpu_udmabuf on a kernel without udmabuf (Microsoft's WSL2 kernel):
# the start goes on with it off; with the device, or with it off already,
# the arguments stay as they are.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
export CVD_PRODUCT_OUT="${T}/product"
mkdir -p "${HOME}" "${CVD_PRODUCT_OUT}"

source "${ROOT}/tools/ika"
log() { :; }

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

UDMABUF_DEVICE="${T}/no-udmabuf"
args=(--cpus=4 --enable_gpu_udmabuf=true)
drop_udmabuf_without_device args
[[ "${args[*]}" == "--cpus=4 --enable_gpu_udmabuf=false" ]] || fail "without the device: ${args[*]}"
args=(--cpus=4 --enable_gpu_udmabuf false)
drop_udmabuf_without_device args
[[ "${args[*]}" == "--cpus=4 --enable_gpu_udmabuf false" ]] || fail "already off: ${args[*]}"
echo "ok: without udmabuf the start goes on with it off"

: >"${T}/udmabuf"
UDMABUF_DEVICE="${T}/udmabuf"
args=(--enable_gpu_udmabuf=true)
drop_udmabuf_without_device args
[[ "${args[*]}" == "--enable_gpu_udmabuf=true" ]] || fail "with the device: ${args[*]}"
echo "ok: with udmabuf it stays on"
