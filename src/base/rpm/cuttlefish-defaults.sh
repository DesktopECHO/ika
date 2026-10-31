#!/usr/bin/env bash

set -euo pipefail

if [ -f /etc/sysconfig/cuttlefish-integration ]; then
  . /etc/sysconfig/cuttlefish-integration
fi

flags=()
if [ -n "${static_defaults_when:-}" ]; then
  flags+=("--static_defaults_when=${static_defaults_when}")
fi

exec /usr/bin/cf_defaults "${flags[@]}"