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

set -o errexit -o nounset -o pipefail

if [[ $# -eq 0 ]] ; then
  echo "usage: $0 /path/to/rpm1 /path/to/rpm2 /path/to/rpm3"
  exit 1
fi

kernel_begin=$(sudo chroot /mnt/image /usr/bin/rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | tail -1)
echo "IMAGE STARTS WITH KERNEL: ${kernel_begin}"

rm -rf /mnt/image/tmp/install
mkdir /mnt/image/tmp/install

# Install packages
for src in "$@"
do
  echo "Installing: ${src}"
  name=$(basename "${src}")
  cp "${src}" "/mnt/image/tmp/install/${name}"
  sudo chroot /mnt/image /usr/bin/dnf install -y "/tmp/install/${name}"
done

kernel_end=$(sudo chroot /mnt/image /usr/bin/rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | tail -1)
echo "IMAGE ENDS WITH KERNEL: ${kernel_end}"

if [ "${kernel_begin}" != "${kernel_end}" ]; then
  echo "KERNEL UPDATE DETECTED!!! ${kernel_begin} -> ${kernel_end}"
  echo "Use a source image with kernel ${kernel_end} installed."
  exit 1
fi

# Skip unmounting:
#  Sometimes systemd starts, making it hard to unmount
#  In any case we'll unmount cleanly when the instance shuts down
