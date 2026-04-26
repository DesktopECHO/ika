#!/usr/bin/env bash

set -euo pipefail

RUN_DIR=/run/cuttlefish
ORCHESTRATOR_LOGFILE=${RUN_DIR}/host_orchestrator.log
args=(--log_file="${ORCHESTRATOR_LOGFILE}")

if [ -n "${orchestrator_http_port:-}" ]; then
  args+=(--http_port="${orchestrator_http_port}")
fi
if [ -n "${orchestrator_android_build_url:-}" ]; then
  args+=(--android_build_url="${orchestrator_android_build_url}")
fi
if [ -n "${orchestrator_cvd_artifacts_dir:-}" ]; then
  args+=(--cvd_artifacts_dir="${orchestrator_cvd_artifacts_dir}")
fi
if [ -n "${operator_http_port:-}" ]; then
  args+=(--operator_http_port="${operator_http_port}")
fi
if [ -n "${orchestrator_listen_address:-}" ]; then
  args+=(--listen_addr="${orchestrator_listen_address}")
fi
if [ -n "${build_api_credentials_use_gce_metadata:-}" ]; then
  args+=(--build_api_credentials_use_gce_metadata=${build_api_credentials_use_gce_metadata})
fi

exec /usr/lib/cuttlefish-common/bin/host_orchestrator "${args[@]}"