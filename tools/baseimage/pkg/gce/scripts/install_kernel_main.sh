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
  echo "usage: $0 <kernel-package-name>"
  exit 1
fi
kernel_package=$1

start_kernel=$(sudo chroot /mnt/image /usr/bin/rpm -q kernel-core --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | tail -1)
echo "START VERSION: ${start_kernel}"

sudo chroot /mnt/image /usr/bin/dnf install -y "${kernel_package}"

end_kernel=$(sudo chroot /mnt/image /usr/bin/rpm -q kernel-core --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | tail -1)
echo "END VERSION: ${end_kernel}"

if ! sudo chroot /mnt/image /usr/bin/rpm -q "${kernel_package}" >/dev/null 2>&1; then
  echo "CREATE IMAGE FAILED!!!"
  echo "Expected installed kernel package ${kernel_package}"
  exit 1
fi

# Skip unmounting:
#  Sometimes systemd starts, making it hard to unmount
#  In any case we'll unmount cleanly when the instance shuts down
