#!/usr/bin/env bash

set -euo pipefail

DIR="$(realpath "$(dirname "$0")")"
REPO_DIR="$(git rev-parse --show-toplevel)"
TOOL="${DIR}/minimerge_tool"
METADATA_FILE="${DIR}/cuttlefish_import_metadata.txt"
CUTTLEFISH_REPO_URL="https://github.com/google/android-cuttlefish.git"

echo "Importing upstream google/android-cuttlefish project"

# Do these early to avoid doing unnecessary work when these fail
# Find last imported commit
stat "${METADATA_FILE}" >/dev/null
metadata_source_repo="$(grep '^[[:space:]]*source_repo[[:space:]]*:' "${METADATA_FILE}" | cut -d: -f2- | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' || true)"
if [[ -n "${metadata_source_repo}" && "${metadata_source_repo}" != "${CUTTLEFISH_REPO_URL}" ]]; then
  echo "Metadata source repo ${metadata_source_repo} does not match ${CUTTLEFISH_REPO_URL}" >&2
  exit 1
fi
last_imported_commit="$(grep '^[[:space:]]*last_import[[:space:]]*:' "${METADATA_FILE}" | cut -d: -f2 | grep -o -E '[^[:space:]]+')"
# Find current commit
pushd "${DIR}" >/dev/null
[[ "$(git status --porcelain)" ]] && (echo "Repository is not in clean state"; exit 1)
current_commit="$(git rev-parse HEAD)"
popd >/dev/null


echo "Compiling minimerge tool..."
pushd "${DIR}" >/dev/null
g++ main.cpp -o "${TOOL}" -lgit2 -O2
popd >/dev/null

echo "Cloning cuttlefish repo..."
CUTTLEFISH_DIR="$(mktemp -t -d cuttlefish.XXX)"
trap "rm -rf '${CUTTLEFISH_DIR}'" EXIT
git clone "${CUTTLEFISH_REPO_URL}" "${CUTTLEFISH_DIR}"

# Find commit to import
pushd "${CUTTLEFISH_DIR}" >/dev/null
current_import="$(git rev-parse HEAD)"
if ! git cat-file -e "${last_imported_commit}^{commit}" >/dev/null 2>&1; then
  echo "Last import ${last_imported_commit} is not present in ${CUTTLEFISH_REPO_URL}" >&2
  echo "Update ${METADATA_FILE} only after choosing a new upstream baseline." >&2
  exit 1
fi
if ! git merge-base --is-ancestor "${last_imported_commit}" "${current_import}"; then
  echo "Last import ${last_imported_commit} is not an ancestor of ${current_import}" >&2
  echo "Refusing to replay an unrelated upstream history." >&2
  exit 1
fi
popd >/dev/null

if [[ "${last_imported_commit}" == "${current_import}" ]]; then
  echo "Nothing to import"
  exit 0
fi

function import() {
  "${TOOL}" \
    --source="${CUTTLEFISH_DIR}" \
    --destination="${REPO_DIR}" \
    --rev_range="${last_imported_commit}..HEAD" \
    "@${DIR}/cuttlefish_args.txt"
}

import || (git reset --hard "${current_commit}"; exit 1)

pushd "${DIR}" >/dev/null
cat >"${METADATA_FILE}" <<EOF
source_repo: ${CUTTLEFISH_REPO_URL}
last_import: ${current_import}
EOF
git commit -a -m "Update import metadata file"
popd >/dev/null
