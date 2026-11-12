#!/usr/bin/env bash
#
# Ika's quick checks, which need no VM, KVM or GPU: the shell syntax of Ika's
# scripts, then the launcher's tests in src/tools/tests. Prints a line per
# test and a summary, and exits 1 if anything failed.
#
#   ./check.sh                 everything
#   ./check.sh session gpu     only the tests whose names contain a word given
#
# A failed test's output is kept in the folder the summary names.

set -uo pipefail

# The launcher is for Linux: its tests use /proc, flock and GNU tools.
if [[ "$(uname -s)" != Linux ]]; then
  echo "check.sh needs Linux; on $(uname -s), run it in a Linux VM or container" >&2
  exit 2
fi
if ((BASH_VERSINFO[0] < 4)); then
  echo "check.sh needs Bash 4 or newer (this is ${BASH_VERSION})" >&2
  exit 2
fi

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2
export LANG=C.UTF-8 LC_ALL=C.UTF-8

# Seconds a test may take before it counts as failed.
CHECK_TEST_TIMEOUT_SEC="${CHECK_TEST_TIMEOUT_SEC:-300}"

log_dir="$(mktemp -d "${TMPDIR:-/tmp}/ika-check.XXXXXX")"
failed=()
passed=0

# Under GitHub Actions, a failure is also an annotation, which the run's page
# and the pull request show without opening the log.
annotate_failure() {
  local title="$1" log="$2" message
  [[ "${GITHUB_ACTIONS:-}" == true ]] || return 0
  message="$(tail -n 10 "${log}")"
  message="${message//'%'/'%25'}"
  message="${message//$'\r'/'%0D'}"
  message="${message//$'\n'/'%0A'}"
  printf '::error title=%s::%s\n' "${title}" "${message}"
}

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "${CHECK_TEST_TIMEOUT_SEC}" "$@"
  else
    "$@"
  fi
}

# Shell syntax: Ika's own scripts, not the upstream ones.
syntax_errors=0
while IFS= read -r script; do
  if ! bash -n "${script}" 2>>"${log_dir}/syntax.log"; then
    syntax_errors=$((syntax_errors + 1))
  fi
done < <(
  printf '%s\n' ika-build src/tools/ika src/tools/ika-root src/tools/ika-wsl-setup
  git ls-files -- 'src/tools/*.sh' 'src/lineageos/scripts/*.sh' 2>/dev/null
)
if ((syntax_errors == 0)); then
  printf 'ok    shell syntax\n'
  passed=$((passed + 1))
else
  printf 'FAIL  shell syntax: %d scripts\n' "${syntax_errors}"
  sed 's/^/      /' "${log_dir}/syntax.log"
  annotate_failure "shell syntax" "${log_dir}/syntax.log"
  failed+=("shell syntax")
fi

# The launcher's tests.
for test in src/tools/tests/test_ika_*.sh; do
  name="$(basename "${test}" .sh)"
  if (($# > 0)); then
    wanted=false
    for word in "$@"; do
      [[ "${name}" == *"${word}"* ]] && wanted=true
    done
    [[ "${wanted}" == true ]] || continue
  fi
  start="${SECONDS}"
  if run_with_timeout bash "${test}" >"${log_dir}/${name}.log" 2>&1 </dev/null; then
    printf 'ok    %s (%ds)\n' "${name}" "$((SECONDS - start))"
    passed=$((passed + 1))
    rm -f "${log_dir}/${name}.log"
  else
    status=$?
    reason="exit ${status}"
    ((status == 124)) && reason="no result in ${CHECK_TEST_TIMEOUT_SEC}s"
    printf 'FAIL  %s (%s)\n' "${name}" "${reason}"
    tail -n 5 "${log_dir}/${name}.log" | sed 's/^/      /'
    annotate_failure "${name}" "${log_dir}/${name}.log"
    failed+=("${name}")
  fi
done

printf '\n%d passed, %d failed\n' "${passed}" "${#failed[@]}"
if ((${#failed[@]} > 0)); then
  printf 'Failed: %s\nTheir output: %s\n' "${failed[*]}" "${log_dir}"
  exit 1
fi
rm -rf "${log_dir}"
