#!/usr/bin/env bash

set -euo pipefail

require_system_nodejs() {
  if ! command -v node >/dev/null 2>&1; then
    echo "node not found in PATH; install the distro-supplied nodejs package." >&2
    exit 1
  fi
  if ! command -v npm >/dev/null 2>&1; then
    echo "npm not found in PATH; install the distro-supplied npm package." >&2
    exit 1
  fi
}

export NODE_BIN="$(command -v node 2>/dev/null || true)"
export NPM_BIN="$(command -v npm 2>/dev/null || true)"
export NODE_VERSION="$("${NODE_BIN:-node}" --version 2>/dev/null || true)"
