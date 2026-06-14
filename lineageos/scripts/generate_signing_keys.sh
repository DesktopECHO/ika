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

run_package_manager() {
  if (( EUID == 0 )); then
    "$@"
    return
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    printf '[lineage-desktop] error: missing package(s) but sudo is not available: %s\n' "$*" >&2
    exit 1
  fi

  if [[ -t 0 ]]; then
    sudo "$@"
  else
    sudo -n "$@"
  fi
}

ensure_certificate_packages() {
  local -a required=(openssl coreutils sed hostname)
  local -a missing=() package_tools=() update_cmd=() install_cmd=()
  local ID="" ID_LIKE="" family="" cmd pkg status

  [[ -r /etc/os-release ]] || {
    printf '[lineage-desktop] error: cannot determine distro; /etc/os-release is missing\n' >&2
    exit 1
  }

  # shellcheck source=/etc/os-release
  . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *" debian "*|*" ubuntu "*)
      family=debian
      package_tools=(dpkg-query apt-get)
      update_cmd=(env DEBIAN_FRONTEND=noninteractive apt-get update -qq)
      install_cmd=(env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends)
      ;;
    *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*)
      family=fedora
      package_tools=(rpm dnf)
      install_cmd=(dnf -q -y install --setopt=install_weak_deps=False)
      ;;
    *" arch "*|*" archarm "*|*" manjaro "*|*" endeavouros "*|*" cachyos "*|*" garuda "*|*" artix "*)
      family=arch
      required=(openssl coreutils sed inetutils)
      package_tools=(pacman)
      install_cmd=(pacman -S --needed --noconfirm --quiet)
      ;;
    *)
      printf '[lineage-desktop] error: unsupported distro for certificate package install: ID=%s ID_LIKE=%s\n' \
        "${ID:-unknown}" "${ID_LIKE:-}" >&2
      exit 1
      ;;
  esac

  for cmd in "${package_tools[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || {
      printf '[lineage-desktop] error: required package tool not found for this distro: %s\n' "$cmd" >&2
      exit 1
    }
  done

  for pkg in "${required[@]}"; do
    case "$family" in
      debian)
        status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)"
        [[ "$status" == "install ok installed" ]] || missing+=("$pkg")
        ;;
      fedora)
        rpm -q --quiet "$pkg" || missing+=("$pkg")
        ;;
      arch)
        pacman -Q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
        ;;
    esac
  done

  (( ${#missing[@]} == 0 )) && return 0
  printf '[lineage-desktop] installing missing certificate package(s): %s\n' "${missing[*]}"
  (( ${#update_cmd[@]} == 0 )) || run_package_manager "${update_cmd[@]}"
  run_package_manager "${install_cmd[@]}" "${missing[@]}"
}

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

if [[ "$check_only" == "0" ]]; then
  ensure_certificate_packages
fi

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

if [[ "$check_only" == "0" ]]; then
  mkdir -p "$ANDROID_CERTS_DIR"
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

gen_apex_key() {
  local apex="$1"

  gen_key "$ANDROID_CERTS_DIR/$apex" "$(subject_for "$apex")" 4096
  # The wiki extracts a PEM-encoded *unencrypted* payload key alongside the
  # PKCS#8 cert; sign_target_files_apks consumes the .pem via
  # --extra_apex_payload_key.
  openssl pkcs8 \
    -in "$ANDROID_CERTS_DIR/$apex.pk8" \
    -inform DER \
    -nocrypt \
    -out "$ANDROID_CERTS_DIR/$apex.pem"
}

keygen_jobs="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')"
[[ "$keygen_jobs" =~ ^[0-9]+$ ]] || keygen_jobs=1
(( keygen_jobs > 0 )) || keygen_jobs=1
keygen_pids=()
keygen_names=()

wait_for_keygens() {
  local status=0 i

  for i in "${!keygen_pids[@]}"; do
    if ! wait "${keygen_pids[$i]}"; then
      printf '[lineage-desktop] error: key generation failed: %s\n' "${keygen_names[$i]}" >&2
      status=1
    fi
  done

  keygen_pids=()
  keygen_names=()
  return "$status"
}

queue_keygen() {
  local name="$1"
  shift

  "$@" &
  keygen_pids+=("$!")
  keygen_names+=("$name")

  if (( ${#keygen_pids[@]} >= keygen_jobs )); then
    wait_for_keygens || exit 1
  fi
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

for cert in "${regular_keys[@]}"; do
  if [[ -f "$ANDROID_CERTS_DIR/$cert.pk8" && -f "$ANDROID_CERTS_DIR/$cert.x509.pem" ]]; then
    printf '[lineage-desktop]   skip (exists): %s\n' "$cert"
    continue
  fi
  printf '[lineage-desktop]   gen:           %s\n' "$cert"
  queue_keygen "$cert" gen_key "$ANDROID_CERTS_DIR/$cert" "$(subject_for "$SIGNING_CN")"
done

for apex in "${apex_keys[@]}"; do
  if [[ -f "$ANDROID_CERTS_DIR/$apex.pk8" \
        && -f "$ANDROID_CERTS_DIR/$apex.x509.pem" \
        && -f "$ANDROID_CERTS_DIR/$apex.pem" ]]; then
    printf '[lineage-desktop]   skip (exists): apex %s\n' "$apex"
    continue
  fi
  printf '[lineage-desktop]   gen apex:      %s\n' "$apex"
  queue_keygen "apex $apex" gen_apex_key "$apex"
done

wait_for_keygens || exit 1

printf '[lineage-desktop] done. %d regular + %d APEX keys ready.\n' \
  "${#regular_keys[@]}" "${#apex_keys[@]}"
