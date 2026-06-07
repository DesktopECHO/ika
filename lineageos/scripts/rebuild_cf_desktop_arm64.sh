#!/usr/bin/env bash
# Thin wrapper over the canonical build engine: rebuild the arm64 Cuttlefish ROM
# from the existing (already synced + patched) source tree. REBUILD=1 makes the
# engine skip repo sync and source patching; everything else -- overlay,
# prebuilts, build, sign, and bundling into lineageos-arm64/ -- is identical to a
# full build_lineageos_desktop.sh run.
#
# Re-enable either skipped step with SKIP_SYNC=0 / SKIP_PATCH=0. The host/target
# matrix is enforced by the engine (arm64 ROMs build on x86_64 and arm64 hosts).
# Pass-through env (WORKSPACE, OUTPUT_DIR, JOBS, ...) is honored by the engine.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec env REBUILD=1 "$script_dir/build_lineageos_desktop.sh" arm64
