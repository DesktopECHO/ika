#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: sync_webview_lfs_prebuilts.sh ANDROID_ROOT [arm|arm64|x86|x86_64|all]...

Fetch and checkout Chromium WebView Git LFS APK prebuilts. This repairs repo
checkouts where Git LFS smudge is locally configured with --skip.
EOF
}

log() {
  printf '[lineage-desktop] %s\n' "$*"
}

die() {
  printf '[lineage-desktop] error: %s\n' "$*" >&2
  exit 1
}

normalize_arches() {
  if (( $# == 0 )); then
    printf '%s\n' arm arm64 x86 x86_64
    return
  fi

  local arch
  for arch in "$@"; do
    case "$arch" in
      all)
        printf '%s\n' arm arm64 x86 x86_64
        ;;
      arm|arm64|x86|x86_64)
        printf '%s\n' "$arch"
        ;;
      aarch64)
        printf '%s\n' arm64
        ;;
      amd64|x86-64)
        printf '%s\n' x86_64
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        die "unknown WebView architecture '$arch'"
        ;;
    esac
  done | awk '!seen[$0]++'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
  usage
  exit 0
fi

(( $# >= 1 )) || {
  usage >&2
  exit 2
}

android_root="$(cd "$1" && pwd)"
shift

command -v git-lfs >/dev/null 2>&1 || die "git-lfs is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

mapfile -t arches < <(normalize_arches "$@")

for arch in "${arches[@]}"; do
  project="external/chromium-webview/prebuilt/$arch"
  project_dir="$android_root/$project"
  apk="$project_dir/webview.apk"

  [[ -d "$project_dir/.git" ]] || die "missing WebView prebuilt git project: $project"

  log "syncing Git LFS objects: $project"
  git -C "$project_dir" lfs install --local --force >/dev/null
  git_network_retry "fetch WebView Git LFS object for $project" \
    git -C "$project_dir" lfs fetch --include='webview.apk' --exclude=''
  git -C "$project_dir" lfs checkout webview.apk

  [[ -f "$apk" ]] || die "missing WebView prebuilt APK: $apk"
  if head -c 128 "$apk" | grep -q 'git-lfs.github.com/spec'; then
    die "WebView prebuilt is still a Git LFS pointer: $apk"
  fi
  validate_zip_file "$apk" || die "invalid WebView prebuilt APK: $apk"
done
