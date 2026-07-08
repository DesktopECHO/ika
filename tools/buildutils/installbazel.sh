#!/usr/bin/env bash

# Copyright (C) 2024 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Install Bazel (via Bazelisk) into the user's local bin directory.
#
# Prerequisites (curl, unzip, zip) are installed by ./ika-build via
# tools/buildutils/lib/dependencies.sh.

set -e

BAZELISK_VERSION=v1.25.0
BAZEL_INSTALL_PATH="${BAZEL_INSTALL_PATH:-${HOME}/.local/bin/bazel}"

function install_bazel_binary() {
  local url="$1"
  local tmpdir

  tmpdir="$(mktemp -d -t bazel_installer_XXXXXX)"
  trap 'rm -rf "$tmpdir"' EXIT
  pushd "${tmpdir}"
  curl -fsSLo bazel "$url"
  mkdir -p "$(dirname "${BAZEL_INSTALL_PATH}")"
  install -m 0755 bazel "${BAZEL_INSTALL_PATH}"
  popd
}

function install_bazel_x86_64() {
  install_bazel_binary "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-amd64"
}

function install_bazel_aarch64() {
  install_bazel_binary "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-arm64"
}

install_bazel_$(uname -m)
