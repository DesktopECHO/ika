#!/usr/bin/env bash

set -euo pipefail

RUN_DIR=/run/cuttlefish
LOG_FILE=${RUN_DIR}/host_orchestrator.log
DIR=/etc/cuttlefish-orchestration/ssl/cert
CERT_FILE=${DIR}/cert.pem
KEY_FILE=${DIR}/key.pem
ARTIFACT_DIR=${orchestrator_cvd_artifacts_dir:-/var/lib/cuttlefish-common}

mkdir -p "${RUN_DIR}" "${DIR}" "${ARTIFACT_DIR}"
chown httpcvd:httpcvd "${RUN_DIR}" "${ARTIFACT_DIR}"
touch "${LOG_FILE}"
chown httpcvd:httpcvd "${LOG_FILE}"

if [ ! -f "${CERT_FILE}" ] || [ ! -f "${KEY_FILE}" ]; then
  openssl req \
    -newkey rsa:4096 \
    -x509 \
    -sha256 \
    -days 36000 \
    -nodes \
    -out "${CERT_FILE}" \
    -keyout "${KEY_FILE}" \
    -subj "/C=US"
fi

systemctl start systemd-journal-gatewayd.service nginx.service >/dev/null 2>&1 || true
systemctl reload nginx.service >/dev/null 2>&1 || true
