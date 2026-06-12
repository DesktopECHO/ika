#!/usr/bin/env bash
set -euo pipefail

# Generate the full set of signing keys required for a signed LineageOS
# Desktop build per https://wiki.lineageos.org/signing_builds. Idempotent:
# already-generated keys are skipped.
#
# Keys land in $ANDROID_CERTS_DIR (default $HOME/.android-certs). Subject
# string is configurable via SIGNING_C / SIGNING_ST / SIGNING_L / SIGNING_O /
# SIGNING_OU / SIGNING_CN / SIGNING_EMAIL env vars.
#
# This generates *unencrypted* keys (blank passphrase, matching what an
# unattended build needs). See https://wiki.lineageos.org/signing_builds for
# the password-protected variant if you'd rather store passwords in
# ANDROID_PW_FILE.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/signing_common.sh"

check_only=0
case "${1:-}" in
  "")
    ;;
  --check)
    check_only=1
    ;;
  -h|--help|help)
    cat <<'EOF'
Usage: generate_signing_keys.sh [--check]

Generate any missing LineageOS Desktop signing keys in ANDROID_CERTS_DIR.
With --check, only verify that the required key set exists.
EOF
    exit 0
    ;;
  *)
    printf '[lineage-desktop] error: unknown argument: %s\n' "$1" >&2
    printf '[lineage-desktop] usage: generate_signing_keys.sh [--check]\n' >&2
    exit 1
    ;;
esac

# Identity source precedence: env vars > per-user config > built-in defaults.
# Per-user config is written by ./setup.sh on first run; edit that file (or
# export SIGNING_* vars) to change. The defaults produce a working,
# obviously-local set of keys.
ika_signing_conf="${XDG_CONFIG_HOME:-$HOME/.config}/ika/signing.conf"
__signing_vars=(SIGNING_C SIGNING_ST SIGNING_L SIGNING_O SIGNING_OU SIGNING_CN SIGNING_EMAIL)

# Snapshot env-supplied overrides so a later `source` of the config file
# doesn't clobber them.
declare -A __signing_env_overrides=()
for v in "${__signing_vars[@]}"; do
  [[ -n "${!v-}" ]] && __signing_env_overrides[$v]="${!v}"
done

if [[ -f "$ika_signing_conf" ]]; then
  # shellcheck source=/dev/null
  source "$ika_signing_conf"
fi

# Restore env overrides, then apply final built-in defaults.
for v in "${!__signing_env_overrides[@]}"; do
  printf -v "$v" '%s' "${__signing_env_overrides[$v]}"
done

SIGNING_C="${SIGNING_C:-CA}"
SIGNING_ST="${SIGNING_ST:-ON}"
SIGNING_L="${SIGNING_L:-Toronto}"
SIGNING_O="${SIGNING_O:-DesktopECHO}"
SIGNING_OU="${SIGNING_OU:-Ika}"
SIGNING_CN="${SIGNING_CN:-LineageOS Virtual Desktop}"
SIGNING_EMAIL="${SIGNING_EMAIL:-$(default_signing_email)}"

subject_for() {
  local cn="$1"
  printf '/C=%s/ST=%s/L=%s/O=%s/OU=%s/CN=%s/emailAddress=%s' \
    "$SIGNING_C" "$SIGNING_ST" "$SIGNING_L" "$SIGNING_O" "$SIGNING_OU" "$cn" "$SIGNING_EMAIL"
}

mkdir -p "$ANDROID_CERTS_DIR"
if [[ "$check_only" == "0" ]]; then
  command -v openssl >/dev/null 2>&1 || {
    printf '[lineage-desktop] error: openssl not found; install openssl and re-run\n' >&2
    exit 1
  }
  printf '[lineage-desktop] writing keys to %s\n' "$ANDROID_CERTS_DIR"
fi

# Generate an RSA key pair, a self-signed X.509 certificate, and a PKCS#8 DER
# private key using only openssl — no dependency on development/tools/make_key
# from a synced Android source tree.
gen_key() {
  local out_stem="$1"
  local subj="$2"
  local bits="${3:-2048}"
  local tmp_pem

  tmp_pem="$(mktemp "${out_stem}.XXXXXX")"
  openssl genrsa -out "$tmp_pem" "$bits" 2>/dev/null
  openssl req -new -x509 -sha256 -key "$tmp_pem" \
    -out "${out_stem}.x509.pem" -days 10000 -subj "$subj"
  openssl pkcs8 -in "$tmp_pem" -topk8 -outform DER -nocrypt -out "${out_stem}.pk8"
  rm -f "$tmp_pem"

  [[ -f "${out_stem}.pk8" && -f "${out_stem}.x509.pem" ]] || {
    printf '[lineage-desktop] error: key generation failed for %s\n' "$out_stem" >&2
    exit 1
  }
}

# Regular keys (RSA2048). The full set the LineageOS wiki documents; if a
# build doesn't need a particular cert sign_target_files_apks ignores it.
regular_keys=(
  bluetooth
  cyngn-app
  media
  networkstack
  nfc
  platform
  releasekey
  sdk_sandbox
  shared
  testcert
  testkey
  verity
)

for cert in "${regular_keys[@]}"; do
  if [[ -f "$ANDROID_CERTS_DIR/$cert.pk8" && -f "$ANDROID_CERTS_DIR/$cert.x509.pem" ]]; then
    printf '[lineage-desktop]   skip (exists): %s\n' "$cert"
    continue
  fi
  printf '[lineage-desktop]   gen:           %s\n' "$cert"
  gen_key "$ANDROID_CERTS_DIR/$cert" "$(subject_for "$SIGNING_CN")"
done

# APEX keys: SHA256_RSA4096 per the LineageOS signing wiki. Many of these
# don't ship in a Cuttlefish desktop build; sign_target_files.sh only passes
# flags for APEXes actually present in the target_files.zip, so extras here
# are harmless storage cost.
apex_keys=(
  com.android.adbd
  com.android.adservices
  com.android.adservices.api
  com.android.appsearch
  com.android.appsearch.apk
  com.android.art
  com.android.bluetooth
  com.android.bt
  com.android.btservices
  com.android.cellbroadcast
  com.android.compos
  com.android.configinfrastructure
  com.android.connectivity.resources
  com.android.conscrypt
  com.android.crashrecovery
  com.android.devicelock
  com.android.extservices
  com.android.graphics.pdf
  com.android.hardware.authsecret
  com.android.hardware.audio
  com.android.hardware.biometrics.face.virtual
  com.android.hardware.biometrics.fingerprint.virtual
  com.android.hardware.boot
  com.android.hardware.cas
  com.android.hardware.contexthub
  com.android.hardware.drm.clearkey
  com.android.hardware.dumpstate
  com.android.hardware.gatekeeper.cf_remote
  com.android.hardware.gatekeeper.nonsecure
  com.android.hardware.gnss
  com.android.hardware.graphics.composer.drm_hwcomposer
  com.android.hardware.graphics.composer.ranchu
  com.android.hardware.input.processor
  com.android.hardware.keymint.rust_cf_guest_trusty_nonsecure
  com.android.hardware.keymint.rust_cf_remote
  com.android.hardware.keymint.rust_nonsecure
  com.android.hardware.memtrack
  com.android.hardware.net.nlinterceptor
  com.android.hardware.neuralnetworks
  com.android.hardware.power
  com.android.hardware.rebootescrow
  com.android.hardware.secure_element
  com.android.hardware.security.authgraph
  com.android.hardware.security.secretkeeper
  com.android.hardware.sensors
  com.android.hardware.thermal
  com.android.hardware.threadnetwork
  com.android.hardware.tetheroffload
  com.android.hardware.usb
  com.android.hardware.uwb
  com.android.hardware.vibrator
  com.android.hardware.wifi
  com.android.healthfitness
  com.android.hotspot2.osulogin
  com.android.i18n
  com.android.ipsec
  com.android.media
  com.android.media.swcodec
  com.android.mediaprovider
  com.android.nearby.halfsheet
  com.android.networkstack.tethering
  com.android.neuralnetworks
  com.android.nfcservices
  com.android.ondevicepersonalization
  com.android.os.statsd
  com.android.permission
  com.android.profiling
  com.android.resolv
  com.android.rkpd
  com.android.runtime
  com.android.safetycenter.resources
  com.android.scheduling
  com.android.sdkext
  com.android.support.apexer
  com.android.telephony
  com.android.telephonycore
  com.android.telephonymodules
  com.android.tethering
  com.android.tzdata
  com.android.uprobestats
  com.android.uwb
  com.android.uwb.resources
  com.android.virt
  com.android.vndk.current
  com.android.vndk.current.on_vendor
  com.android.wifi
  com.android.wifi.dialog
  com.android.wifi.resources
  com.google.cf.bt
  com.google.cf.confirmationui
  com.google.cf.disabled
  com.google.cf.gralloc
  com.google.cf.health
  com.google.cf.health.storage
  com.google.cf.input.config
  com.google.cf.light
  com.google.cf.oemlock
  com.google.cf.vulkan
  com.google.cf.wifi
  com.google.cf.wpa_supplicant
  com.google.emulated.camera.provider.hal
  com.google.emulated.camera.provider.hal.fastscenecycle
  com.google.pixel.camera.hal
  com.google.pixel.vibrator.hal
  com.qorvo.uwb
)

if [[ "$check_only" == "1" ]]; then
  missing=0
  for cert in "${regular_keys[@]}"; do
    if [[ ! -f "$ANDROID_CERTS_DIR/$cert.pk8" || ! -f "$ANDROID_CERTS_DIR/$cert.x509.pem" ]]; then
      printf '[lineage-desktop] missing regular key: %s\n' "$cert" >&2
      missing=1
    fi
  done
  for apex in "${apex_keys[@]}"; do
    if [[ ! -f "$ANDROID_CERTS_DIR/$apex.pk8" \
          || ! -f "$ANDROID_CERTS_DIR/$apex.x509.pem" \
          || ! -f "$ANDROID_CERTS_DIR/$apex.pem" ]]; then
      printf '[lineage-desktop] missing APEX key: %s\n' "$apex" >&2
      missing=1
    fi
  done
  exit "$missing"
fi

for apex in "${apex_keys[@]}"; do
  if [[ -f "$ANDROID_CERTS_DIR/$apex.pk8" \
        && -f "$ANDROID_CERTS_DIR/$apex.x509.pem" \
        && -f "$ANDROID_CERTS_DIR/$apex.pem" ]]; then
    printf '[lineage-desktop]   skip (exists): apex %s\n' "$apex"
    continue
  fi
  printf '[lineage-desktop]   gen apex:      %s\n' "$apex"
  gen_key "$ANDROID_CERTS_DIR/$apex" "$(subject_for "$apex")" 4096
  # The wiki extracts a PEM-encoded *unencrypted* payload key alongside the
  # PKCS#8 cert; sign_target_files_apks consumes the .pem via
  # --extra_apex_payload_key.
  openssl pkcs8 \
    -in "$ANDROID_CERTS_DIR/$apex.pk8" \
    -inform DER \
    -nocrypt \
    -out "$ANDROID_CERTS_DIR/$apex.pem"
done

printf '[lineage-desktop] done. %d regular + %d APEX keys ready.\n' \
  "${#regular_keys[@]}" "${#apex_keys[@]}"
