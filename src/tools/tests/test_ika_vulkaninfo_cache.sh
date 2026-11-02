#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
export HOME="${T}/home"
export CVD_HOME_DIR="${T}/ika"
mkdir -p "${HOME}"
source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# A vulkaninfo that lists a Dozen GPU of Vulkan 1.2 and Lavapipe, or the GPU
# alone under MESA_VK_DEVICE_SELECT, as Mesa's device selection layer does on
# WSL2; each run adds a line to runs.
CVD_TMP_DIR="${T}/tmp"
mkdir -p "${CVD_TMP_DIR}" "${T}/bin"
cat >"${T}/bin/vulkaninfo" <<STUB
#!/usr/bin/env bash
echo run >>"${T}/runs"
printf 'Devices:\n========\nGPU0:\n\tapiVersion = 1.2.363\n\tdeviceType = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU\n'
printf '\tdeviceName = Microsoft Direct3D12 (Intel(R) Iris(R) Plus Graphics 650)\n\tdriverID = DRIVER_ID_MESA_DOZEN\n'
[[ -n "\${MESA_VK_DEVICE_SELECT:-}" ]] && exit 0
printf 'GPU1:\n\tapiVersion = 1.4.354\n\tdeviceType = PHYSICAL_DEVICE_TYPE_CPU\n'
printf '\tdeviceName = llvmpipe (LLVM 16.0.0, 256 bits)\n\tdriverID = DRIVER_ID_MESA_LLVMPIPE\n'
STUB
chmod +x "${T}/bin/vulkaninfo"
PATH="${T}/bin:${PATH}"
unset MESA_VK_DEVICE_SELECT MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE DRI_PRIME IKA_DZN_FIX
runs() { wc -l <"${T}/runs" | tr -d ' '; }

# setup_wsl_gpu_env's first probe, before the device selection
probe_vulkaninfo_summary | command grep -q llvmpipe || fail "the first probe did not list Lavapipe"
probe_vulkaninfo_summary >/dev/null
[[ "$(runs)" == 1 ]] || fail "the same environment ran vulkaninfo again instead of reading the cache"

# What the GPU mode is chosen from, with the device selection in place
export MESA_VK_DEVICE_SELECT='8086:5927!' IKA_DZN_FIX=1
summary="$(probe_vulkaninfo_summary)"
[[ "$(runs)" == 2 ]] || fail "MESA_VK_DEVICE_SELECT reused the summary from before it"
if command grep -q llvmpipe <<<"${summary}"; then
  fail "the summary under MESA_VK_DEVICE_SELECT lists Lavapipe"
fi
if vulkan_summary_gfxstream_passes_over_hardware "${summary}" >/dev/null; then
  fail "gfxstream was taken to pass over the only device, the Dozen GPU"
fi
echo "ok: the device selection gets a summary of its own"
