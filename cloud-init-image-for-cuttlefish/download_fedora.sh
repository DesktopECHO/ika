#!/bin/sh

FEDORA_DOWNLOAD_URL_DEFAULT="https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/aarch64/images"
if [ x"${FEDORA_DOWNLOAD_URL}" = x"" ]; then
    FEDORA_DOWNLOAD_URL="${FEDORA_DOWNLOAD_URL_DEFAULT}"
fi

FEDORA_DOWNLOAD_FILE_DEFAULT="Fedora-Cloud-Base-Generic-42-1.1.aarch64.qcow2"
if [ x"${FEDORA_DOWNLOAD_FILE}" = x"" ]; then
    FEDORA_DOWNLOAD_FILE="${FEDORA_DOWNLOAD_FILE_DEFAULT}"
fi

wget -nv -c "${FEDORA_DOWNLOAD_URL}/${FEDORA_DOWNLOAD_FILE}"
