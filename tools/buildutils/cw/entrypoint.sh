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

if [[ "$(id -u)" -eq 0 ]]; then
  build_uid="${HOST_UID:-$(stat -c '%u' "${PWD}")}"
  build_gid="${HOST_GID:-$(stat -c '%g' "${PWD}")}"

  if [[ "${build_uid}" != "0" ]]; then
    build_group="$(getent group "${build_gid}" | cut -d: -f1 || true)"
    if [[ -z "${build_group}" ]]; then
      build_group="cuttlefish-build"
      groupadd -g "${build_gid}" "${build_group}"
    fi

    build_user="$(getent passwd "${build_uid}" | cut -d: -f1 || true)"
    if [[ -z "${build_user}" ]]; then
      build_user="cuttlefish-build"
      useradd -u "${build_uid}" -g "${build_gid}" -m "${build_user}"
    fi

    build_home="$(getent passwd "${build_uid}" | cut -d: -f6)"
    exec sudo -E -u "${build_user}" -g "${build_group}" \
      env HOME="${build_home}" "$0" "$@"
  fi
fi

# This configuration setting is required for building frontend package on the
# docker instance.
git config --global --add safe.directory "${PWD}"

exec tools/buildutils/build_package.sh "$@"
