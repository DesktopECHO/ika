#!/usr/bin/env bash
set -euo pipefail

# One-time bootstrap for new clones of the ika repo.
#
# Idempotent — re-running skips steps that are already done:
#   1. Records a build-signing identity (org, email, etc.) to
#      ~/.config/ika/signing.conf. Asks interactively the first time.
#   2. Generates the LineageOS signing keys at ANDROID_CERTS_DIR
#      (default ~/.android-certs) using that identity.
#
# After setup completes, the regular build flow works:
#   ./lineageos/scripts/build_lineageos_desktop.sh
#
# To start over (regenerate identity / keys), delete the relevant
# file or directory and re-run this script.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
source "$repo_root/lineageos/scripts/signing_common.sh"

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/ika"
config_file="$config_dir/signing.conf"
android_certs_dir="$ANDROID_CERTS_DIR"

log() {
  printf '[ika-setup] %s\n' "$*"
}

prompt_with_default() {
  # prompt_with_default "Country (2-letter)" "US" -> echoes the response
  local prompt="$1"
  local default="$2"
  local reply
  if [[ -t 0 ]]; then
    read -rp "  $prompt [$default]: " reply || reply=""
  else
    reply=""
  fi
  printf '%s\n' "${reply:-$default}"
}

prompt_signing_identity() {
  cat <<'EOF'

This identity is embedded in every APK and APEX cert your builds emit. Use
real values if you plan to distribute builds; the defaults below are fine for
local-only development.

Press Enter at each prompt to accept the default in brackets.

EOF
  local c st l o ou cn email
  c="$(prompt_with_default 'Country (2-letter code)' 'CA')"
  st="$(prompt_with_default 'State / Province' 'ON')"
  l="$(prompt_with_default 'City / Locality' 'Toronto')"
  o="$(prompt_with_default 'Organization' 'DesktopECHO')"
  ou="$(prompt_with_default 'Organizational Unit' 'Ika')"
  cn="$(prompt_with_default 'Common Name' 'Android Desktop')"
  email="$(prompt_with_default 'Email address' "$(default_signing_email)")"
  printf '\n'

  mkdir -p "$config_dir"
  umask 077
  cat > "$config_file" <<EOF
# ika build signing identity.
# Sourced by lineageos/scripts/generate_signing_keys.sh. Values affect only
# future key generation; keys already in $android_certs_dir keep their
# original identity. Delete the matching .pk8 / .x509.pem / .pem files (or
# the whole directory) to regenerate.
SIGNING_C="$c"
SIGNING_ST="$st"
SIGNING_L="$l"
SIGNING_O="$o"
SIGNING_OU="$ou"
SIGNING_CN="$cn"
SIGNING_EMAIL="$email"
EOF
  chmod 0600 "$config_file"
  log "wrote $config_file"
}

ensure_identity() {
  if [[ -f "$config_file" ]]; then
    log "signing identity: $config_file (delete to reconfigure)"
    return 0
  fi
  log "no signing identity found at $config_file"
  if [[ ! -t 0 ]]; then
    log "error: stdin is not a terminal; cannot prompt for identity"
    log "create $config_file by hand (template: SIGNING_C=..., SIGNING_ST=..., ...) and re-run"
    exit 1
  fi
  prompt_signing_identity
}

ensure_keys() {
  if [[ -f "$android_certs_dir/releasekey.pk8" ]]; then
    log "signing keys: $android_certs_dir (adding any newly required keys)"
  else
    log "generating signing keys at $android_certs_dir"
  fi
  "$repo_root/lineageos/scripts/generate_signing_keys.sh"
}

main() {
  ensure_identity
  ensure_keys
  printf '\n[ika-setup] done.\n'
}

main "$@"
