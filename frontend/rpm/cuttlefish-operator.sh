#!/usr/bin/env bash

set -euo pipefail

RUN_DIR=/run/cuttlefish
LOGFILE=${RUN_DIR}/operator.log
args=(--log_file="${LOGFILE}" --socket_path="${RUN_DIR}/operator")

if [ -n "${operator_http_port:-}" ]; then
  args+=(--http_port="${operator_http_port}")
fi
if [ -n "${operator_https_port:-}" ]; then
  args+=(--https_port="${operator_https_port}")
fi
if [ -n "${operator_tls_cert_dir:-}" ]; then
  args+=(--tls_cert_dir="${operator_tls_cert_dir}")
fi
if [ -n "${operator_webui_url:-}" ]; then
  args+=(--webui_url="${operator_webui_url}")
fi
if [ -n "${operator_listen_address:-}" ]; then
  args+=(--listen_addr="${operator_listen_address}")
fi

exec /usr/lib/cuttlefish-common/bin/operator "${args[@]}"