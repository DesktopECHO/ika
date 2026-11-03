#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE="${ROOT}/tools/mesa/release.env"
MANIFEST="${ROOT}/lineageos/manifests/lineageos-desktop.xml"
ANDROID_PATCH="${ROOT}/lineageos/patches/external-mesa3d.patch"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

source "${RELEASE}"
[[ "${MESA_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]] || fail "MESA_VERSION is not a Mesa release: ${MESA_VERSION}"
[[ "${MESA_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || fail "MESA_COMMIT is not a full commit hash: ${MESA_COMMIT}"
[[ "${MESA_SHA256}" =~ ^[0-9a-f]{64}$ ]] || fail "MESA_SHA256 is not a sha256: ${MESA_SHA256}"

# The ROM's external/mesa3d is the release's commit.
pin="$(python3 -I - "${MANIFEST}" <<'PY'
import sys
import xml.etree.ElementTree as ET

for project in ET.parse(sys.argv[1]).getroot().iter("project"):
    if project.get("path") == "external/mesa3d":
        print(project.get("revision", ""))
PY
)"
[[ "${pin}" == "${MESA_COMMIT}" ]] ||
  fail "the manifest pins external/mesa3d to ${pin:-nothing}, release.env says ${MESA_COMMIT}; rerun src/lineageos/scripts/mesa3d/regenerate.sh"

# The generated Android build is for the same release.
grep -Fq "Android build integration for Mesa ${MESA_VERSION} (${MESA_COMMIT:0:12})," "${ANDROID_PATCH}" ||
  fail "external-mesa3d.patch is not generated for Mesa ${MESA_VERSION} (${MESA_COMMIT:0:12}); rerun src/lineageos/scripts/mesa3d/regenerate.sh"
grep -Fq -- "-DPACKAGE_VERSION=\\\"${MESA_VERSION}\\\"" "${ANDROID_PATCH}" ||
  fail "external-mesa3d.patch's Android.bp does not build Mesa ${MESA_VERSION}"

# No build sets a Mesa release of its own.
others="$(git -C "${ROOT}" grep -lE '^[[:space:]]*(MESA_VERSION|MESA_SHA256|MESA_COMMIT)[[:space:]]*[:?]?=' \
  -- tools base lineageos/scripts | grep -vxF tools/mesa/release.env || true)"
[[ -z "${others}" ]] || fail "these files set a Mesa release besides release.env: ${others}"

echo "ok: one Mesa release, ${MESA_VERSION}"
