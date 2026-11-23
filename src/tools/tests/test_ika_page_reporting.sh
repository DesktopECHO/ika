#!/usr/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

export HOME="${TEST_ROOT}/home"
export CVD_HOME_DIR="${TEST_ROOT}/ika"
export CVD_PRODUCT_OUT="${TEST_ROOT}/product"
export IKA_SHMEM_THP_FILE="${TEST_ROOT}/shmem_enabled"
mkdir -p "${HOME}" "${CVD_HOME_DIR}" "${CVD_PRODUCT_OUT}"

source "${ROOT}/tools/ika"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

host_timezone() { return 0; }
is_user_build() { return 1; }

bootconfig_for() {
  local -a args=()
  append_bootconfig_args args
  printf '%s\n' "${args[*]:-}"
}

# No huge pages behind Android's memory: every free page is reported.
printf 'always within_size advise [never] deny force\n' > "${IKA_SHMEM_THP_FILE}"
[[ "$(bootconfig_for)" == "--extra_bootconfig_args=androidboot.ika.page_reporting_order=0" ]] || \
  fail "shmem THP off did not ask Android to report every free page: $(bootconfig_for)"

printf 'always within_size advise never [deny] force\n' > "${IKA_SHMEM_THP_FILE}"
[[ "$(bootconfig_for)" == *"androidboot.ika.page_reporting_order=0"* ]] || \
  fail "shmem THP deny did not ask Android to report every free page"

# A kernel without transparent huge pages has no shmem_enabled file.
rm -f "${IKA_SHMEM_THP_FILE}"
[[ "$(bootconfig_for)" == *"androidboot.ika.page_reporting_order=0"* ]] || \
  fail "a host without THP did not ask Android to report every free page"

# Huge pages behind Android's memory (WSL2, where ika-base sets advise): the
# kernel's pageblock-sized reports stay.
for setting in '[always]' '[within_size]' '[advise]' '[force]' '[inherit]'; do
  printf 'always within_size %s never deny\n' "${setting}" > "${IKA_SHMEM_THP_FILE}"
  [[ "$(bootconfig_for)" != *page_reporting_order* ]] || \
    fail "shmem THP ${setting} still asked for small page reports"
done

# The guest applies the property it is given.
rc="${ROOT}/lineageos/prebuilts/memory/ika_memory.rc"
grep -Fqx 'on init && property:ro.boot.ika.page_reporting_order=*' "${rc}" || \
  fail "guest init does not trigger on ro.boot.ika.page_reporting_order"
grep -Fqx '    write /sys/module/page_reporting/parameters/page_reporting_order ${ro.boot.ika.page_reporting_order}' "${rc}" || \
  fail "guest init does not write the page reporting order"
grep -Fq '/module/page_reporting/parameters/page_reporting_order u:object_r:sysfs_ika_page_reporting:s0' \
  "${ROOT}/lineageos/sepolicy/private/genfs_contexts" || \
  fail "the page reporting order has no SELinux label init may write"

printf 'PASS: free page reporting order follows the host huge pages\n'
