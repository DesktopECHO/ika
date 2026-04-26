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

# Install Bazel on Fedora.

set -e

BAZELISK_VERSION=v1.25.0

function install_bazel_x86_64() {
  dnf install -y curl unzip zip
  tmpdir="$(mktemp -d -t bazel_installer_XXXXXX)"
  trap 'rm -rf "$tmpdir"' EXIT
  pushd "${tmpdir}"
  curl -fsSLo bazel "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-amd64"
  install -m 0755 bazel /usr/local/bin/bazel
  popd
}

function install_bazel_aarch64() {
  dnf install -y curl unzip zip
  tmpdir="$(mktemp -d -t bazel_installer_XXXXXX)"
  trap 'rm -rf "$tmpdir"' EXIT
  pushd "${tmpdir}"
  curl -fsSLo bazel "https://github.com/bazelbuild/bazelisk/releases/download/${BAZELISK_VERSION}/bazelisk-linux-arm64"
  install -m 0755 bazel /usr/local/bin/bazel
  popd
}

install_bazel_$(uname -m)
