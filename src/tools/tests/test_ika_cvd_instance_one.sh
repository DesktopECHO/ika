#!/usr/bin/bash

# Ika's VM is Cuttlefish instance 1. A lock file left marked in use by a group
# that is gone from cvd's database made cvd start the VM as instance 2, where
# ika never found it. ika start clears a group recorded on another instance and
# releases instance 1's lock when no recorded group holds it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

export HOME="${TEST_ROOT}/home"
export CVD_HOME_DIR="${TEST_ROOT}/ika"
export CVD_PRODUCT_OUT="${TEST_ROOT}/product"
export CVD_INSTANCE_LOCK_DIR="${TEST_ROOT}/lock"
mkdir -p "${CVD_PRODUCT_OUT}" "${CVD_INSTANCE_LOCK_DIR}"

source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# A stub cvd: 'ps' prints the groups in $TEST_ROOT/ps, 'clear' empties them and
# records the call.
CVD_CLI_BIN="${TEST_ROOT}/cvd"
cat > "${CVD_CLI_BIN}" <<STUB
#!/usr/bin/bash
case "\$1" in
  ps)
    echo "GROUPS   NAMES   ID   STATUS    CREATED               ADB_SERIAL"
    cat "${TEST_ROOT}/ps" 2>/dev/null || true ;;
  clear)
    echo clear >> "${TEST_ROOT}/calls"
    : > "${TEST_ROOT}/ps"
    rm -f "${CVD_INSTANCE_LOCK_DIR}"/local-instance-[0-9]*.lock.held ;;
esac
STUB
chmod +x "${CVD_CLI_BIN}"
live="false"
has_live_cvd_processes() { [[ "${live}" == "true" ]]; }
lock1="${CVD_INSTANCE_LOCK_DIR}/local-instance-1.lock"
reset_case() {
  rm -f "${TEST_ROOT}/calls" "${TEST_ROOT}/ps" "${CVD_INSTANCE_LOCK_DIR}"/*
  live="false"
}

# mb11 on 2026-11-06: instance 1's lock left from a removed group, the VM
# recorded as instance 2.
reset_case
printf 'I' > "${lock1}"
printf 'I' > "${CVD_INSTANCE_LOCK_DIR}/local-instance-2.lock"
echo "cvd_1    2       2    Stopped   2026-11-06 00:39:21   localhost:6521" > "${TEST_ROOT}/ps"
claim_cvd_instance_one 2>/dev/null
grep -qx clear "${TEST_ROOT}/calls" 2>/dev/null || fail "a VM recorded as instance 2 was not cleared"
[[ -e "${lock1}" ]] && fail "instance 1's orphaned lock was kept"

# Only the orphaned lock: released, nothing cleared.
reset_case
printf 'I' > "${lock1}"
claim_cvd_instance_one 2>/dev/null
[[ -e "${TEST_ROOT}/calls" ]] && fail "cvd clear ran with no group recorded"
[[ -e "${lock1}" ]] && fail "instance 1's orphaned lock was kept with no group recorded"

# The normal case: a stopped VM recorded as instance 1 keeps its record and lock.
reset_case
printf 'I' > "${lock1}"
echo "cvd_1    1       1    Stopped   2026-11-06 00:39:21   vsock:3:5555" > "${TEST_ROOT}/ps"
claim_cvd_instance_one 2>/dev/null
[[ -e "${TEST_ROOT}/calls" ]] && fail "a VM recorded as instance 1 was cleared"
[[ -e "${lock1}" ]] || fail "instance 1's lock was released while its VM is recorded"

# A running VM is never touched, whatever its instance.
reset_case
live="true"
printf 'I' > "${lock1}"
echo "cvd_1    2       2    Running   2026-11-06 00:39:21   localhost:6521" > "${TEST_ROOT}/ps"
claim_cvd_instance_one 2>/dev/null
[[ -e "${TEST_ROOT}/calls" ]] && fail "a running VM was cleared"
[[ -e "${lock1}" ]] || fail "instance 1's lock was released while a VM runs"

# No lock and no record: nothing to do.
reset_case
claim_cvd_instance_one 2>/dev/null
[[ -e "${TEST_ROOT}/calls" ]] && fail "cvd clear ran on a clean host"

echo "PASS: test_ika_cvd_instance_one"
