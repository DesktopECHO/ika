#!/usr/bin/env bash

set -euo pipefail

RUN_DIR=/run/cuttlefish
operator_tls_cert_dir=${operator_tls_cert_dir:-/etc/cuttlefish-common/operator/cert}
CERT_FILE=${operator_tls_cert_dir}/cert.pem
KEY_FILE=${operator_tls_cert_dir}/key.pem

mkdir -p "${RUN_DIR}" "${operator_tls_cert_dir}"
chown _cutf-operator:cvdnetwork "${RUN_DIR}"
chmod 775 "${RUN_DIR}"

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
  chown _cutf-operator:cvdnetwork "${CERT_FILE}" "${KEY_FILE}"
fi