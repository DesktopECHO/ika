#!/usr/bin/env bash

# Copyright (C) 2025 The Android Open Source Project
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

set -x
set -o errexit

arch=$(uname -m)
nvidia_arch=${arch}

# NVIDIA driver needs dkms which requires /dev/fd
if [ ! -d /dev/fd ]; then
  ln -s /proc/self/fd /dev/fd
fi

# Match the most recently installed Fedora kernel.
kmodver=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | tail -1 | sed 's/^kernel-core-//')

dnf install -y wget

# Dependencies for nvidia-installer
dnf install -y \
  "kernel-devel-${kmodver}" \
  dkms \
  libglvnd-dev \
  glibc-devel \
  pkgconf-pkg-config

nvidia_version=570.158.01

wget -q https://us.download.nvidia.com/tesla/${nvidia_version}/NVIDIA-Linux-${nvidia_arch}-${nvidia_version}.run
chmod a+x NVIDIA-Linux-${nvidia_arch}-${nvidia_version}.run
./NVIDIA-Linux-${nvidia_arch}-${nvidia_version}.run -x
arch_specific_flags=""
if [[ "${nvidia_arch}" = "x86_64" ]]; then
  arch_specific_flags="--no-install-compat32-libs"
fi
NVIDIA-Linux-${nvidia_arch}-${nvidia_version}/nvidia-installer \
  ${arch_specific_flags} \
  --silent \
  --no-backup \
  --no-wine-files \
  --install-libglvnd \
  --dkms \
  -k "${kmodver}"
