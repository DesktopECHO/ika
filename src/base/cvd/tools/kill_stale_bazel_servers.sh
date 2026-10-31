#!/usr/bin/env bash
#
# Shut down stale Bazel servers before starting a build.
#
# Every ika package build runs Bazel with a shared
# --output_user_root (default <repo>/ika-work) so the disk cache, repository
# cache, distdir and git mirrors are reused across runs. When a server from an
# earlier or concurrent build is still alive under that same root, two servers
# end up racing on the shared caches and on the in-tree sources. That trips
# Bazel's --guard_against_concurrent_changes guard ("config.h was modified
# during execution") and shows up as transient, irreproducible failures such as
# a header that plainly exists reporting "file not found".
#
# A build only ever needs the server for its own workspace, so before starting
# we shut down every other Bazel server that shares our --output_user_root. The
# server for the current workspace (e.g. one left from a previous retry attempt)
# is left running so it can be reused.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly WORK_ROOT="${IKA_WORK_ROOT:-${REPO_ROOT}/ika-work}"
readonly OUTPUT_USER_ROOT="${CUTTLEFISH_BAZEL_OUTPUT_USER_ROOT:-${WORK_ROOT}}"

if [[ "${CUTTLEFISH_SKIP_BAZEL_SERVER_CLEANUP:-}" == "1" ]]; then
  exit 0
fi

# Workspace the about-to-start build will use. The packaging scripts invoke this
# from base/cvd (the same directory they run `bazel build` from), so default to
# the current directory; allow an explicit override as the first argument. The
# current workspace is matched against each server below to spare its own
# server, so if we cannot resolve it (e.g. the build dir was removed out from
# under us) we skip cleanup rather than risk shutting down our own server.
if ! CURRENT_WORKSPACE="$(cd "${1:-$PWD}" 2>/dev/null && pwd -P)"; then
  echo "kill_stale_bazel_servers: cannot resolve current workspace; skipping cleanup." >&2
  exit 0
fi
readonly CURRENT_WORKSPACE

# Print the value of a `--flag=value` token from a NUL-separated /proc cmdline.
# Prints nothing (and still succeeds) when the flag is absent or the process
# vanished mid-scan.
arg_value() {
  local flag="$1" file="$2" tok
  local -a args=()
  mapfile -d '' -t args < "$file" 2>/dev/null || return 0
  for tok in "${args[@]}"; do
    [[ "$tok" == "${flag}="* ]] && { printf '%s' "${tok#"${flag}="}"; return 0; }
  done
}

# SIGTERM the server, give it a moment to release its locks, then SIGKILL. The
# output_base lock is an flock held by the process, so it is freed either way;
# the grace period just lets the JVM run its shutdown hooks first.
terminate() {
  local pid="$1"
  kill -TERM "$pid" 2>/dev/null || return 0
  local i
  for i in $(seq 1 10); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  kill -KILL "$pid" 2>/dev/null || true
}

uid="$(id -u)"
killed=0

for cmdline in /proc/[0-9]*/cmdline; do
  pid="${cmdline#/proc/}"
  pid="${pid%/cmdline}"

  # Only our own Bazel server processes.
  [[ "$(stat -c %u "/proc/$pid" 2>/dev/null || true)" == "$uid" ]] || continue
  grep -qa 'A-server.jar' "$cmdline" 2>/dev/null || continue

  # Only servers that share our output_user_root; leave unrelated Bazel
  # projects alone.
  [[ "$(arg_value --output_user_root "$cmdline")" == "$OUTPUT_USER_ROOT" ]] || continue

  workspace="$(arg_value --workspace_directory "$cmdline")"
  output_base="$(arg_value --output_base "$cmdline")"

  # Keep the server for the workspace we are about to (re)use; reusing it is
  # fine and avoids a needless restart. `-ef` also treats a workspace whose
  # directory no longer exists as stale, so those get shut down too.
  [[ -n "$workspace" && "$workspace" -ef "$CURRENT_WORKSPACE" ]] && continue

  echo "Shutting down stale Bazel server pid=${pid} (workspace=${workspace:-?}, output_base=${output_base:-?})" >&2
  terminate "$pid"
  killed=$((killed + 1))
done

if [[ "$killed" -gt 0 ]]; then
  echo "Shut down ${killed} stale Bazel server(s) under ${OUTPUT_USER_ROOT}." >&2
fi
