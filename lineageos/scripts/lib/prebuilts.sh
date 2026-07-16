#!/usr/bin/env bash
# Host toolchain prebuilt management for the LineageOS Desktop build engine:
# Clang payload selection/sync (arm64 + x86 host families), and ARM64 host-native
# prebuilt fetching (Go, Rust, JDK, CMake, clang-tools) with their install,
# bridge, and verification helpers. Source only (defines functions). ARM64
# fetchers self-gate on host_is_arm64. Relies on engine globals + core primitives.

arm64_prebuilt_cache_subdir() {
  local subdir="$1"
  local base="${arm64_prebuilt_cache_dir:-$ika_work_root/arm64-prebuilts}"
  local dir

  [[ -n "$base" && "$base" != "/" ]] || \
    die "unsafe ARM64_PREBUILT_CACHE_DIR: $base"

  dir="$base/$subdir"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

ensure_arm64_go_prebuilt() {
  host_is_arm64 || return 0
  if [[ -x "$workspace/prebuilts/go/linux-arm64/bin/go" ]]; then
    require_arm64_prebuilt_executable "$workspace/prebuilts/go/linux-arm64/bin/go" "ARM64 Go"
    return 0
  fi

  local cache_dir tmp_dir dest_dir
  cache_dir="$(arm64_prebuilt_cache_subdir go)"
  dest_dir="$workspace/prebuilts/go/linux-arm64"

  mkdir -p "$cache_dir"
  tmp_dir="$(mktemp -d "$cache_dir/linux-arm64.XXXXXX")"
  log "cloning ARM64 Go prebuilt: $arm64_go_prebuilt_git_url ($arm64_go_prebuilt_git_ref)"
  git_clone_with_retries "$tmp_dir" "clone ARM64 Go prebuilt" \
    --depth=1 --branch "$arm64_go_prebuilt_git_ref" "$arm64_go_prebuilt_git_url" || \
    die "failed to clone ARM64 Go prebuilt: $arm64_go_prebuilt_git_url@$arm64_go_prebuilt_git_ref"
  [[ -x "$tmp_dir/bin/go" && -f "$tmp_dir/pkg/linux_arm64/fmt.a" ]] || {
    rm -rf "$tmp_dir"
    die "ARM64 Go prebuilt is incomplete: $arm64_go_prebuilt_git_url@$arm64_go_prebuilt_git_ref"
  }

  rm -rf "$dest_dir.tmp" "$dest_dir"
  mkdir -p "${dest_dir%/*}"
  mv "$tmp_dir" "$dest_dir.tmp"
  mv "$dest_dir.tmp" "$dest_dir"
  require_arm64_prebuilt_executable "$dest_dir/bin/go" "ARM64 Go"

  log "installed ARM64 Go prebuilt at ${dest_dir#$workspace/}"
}

clang_payload_dir() {
  local dest="$1"
  find "$dest" -maxdepth 1 -mindepth 1 -type d -name 'clang-r*' \
    -exec test -x '{}/bin/clang' ';' -print 2>/dev/null | sort | tail -n 1
}

clang_payload_name_from_metadata() {
  local dest="$1"
  [[ -f "$dest/Android.bp" ]] || return 1
  sed -n 's/.*"\(clang-r[^"]*\)".*/\1/p' "$dest/Android.bp" | sort -V | tail -n 1
}

clang_release_version() {
  local clang_dir="$1"
  find "$clang_dir/lib/clang" -maxdepth 1 -mindepth 1 -type d \
    -printf '%f\n' 2>/dev/null | sort -V | tail -n 1
}

set_clang_version_vars() {
  local host_tag="$1"
  local clang_dir="$2"
  local prebuilt_version release_version

  prebuilt_version="${clang_dir##*/}"
  release_version="$(clang_release_version "$clang_dir")"
  [[ -n "$release_version" ]] || \
    die "failed to detect LLVM release version under ${clang_dir#$workspace/}"

  case "$host_tag" in
    linux-arm64)
      linux_arm64_llvm_prebuilts_version="$prebuilt_version"
      linux_arm64_llvm_release_version="$release_version"
      ;;
    linux-x86)
      linux_x86_llvm_prebuilts_version="$prebuilt_version"
      linux_x86_llvm_release_version="$release_version"
      ;;
    *)
      die "internal error: unsupported Clang host tag $host_tag"
      ;;
  esac
}

clang_marker_file() {
  local dest="$1"
  printf '%s\n' "$dest/.lineage-desktop-clang-prebuilt"
}

clang_marker_value() {
  local marker="$1"
  local key="$2"
  sed -n "s/^$key=//p" "$marker" 2>/dev/null | tail -n 1
}

clang_cached_commit() {
  local dest="$1"
  local payload_name="$2"
  local git_url="$3"
  local git_ref="$4"
  local marker commit

  marker="$(clang_marker_file "$dest")"
  [[ -f "$marker" ]] || return 1
  [[ "$(clang_marker_value "$marker" url)" == "$git_url" ]] || return 1
  [[ "$(clang_marker_value "$marker" ref)" == "$git_ref" ]] || return 1
  [[ "$(clang_marker_value "$marker" payload)" == "$payload_name" ]] || return 1
  commit="$(clang_marker_value "$marker" commit)"
  [[ -n "$commit" ]] || return 1
  git -C "$dest" cat-file -e "$commit^{commit}" 2>/dev/null || return 1
  printf '%s\n' "$commit"
}

clang_exclude_payload() {
  local dest="$1"
  local payload_name="$2"
  local git_dir exclude_file pattern

  git_dir="$(git -C "$dest" rev-parse --git-dir 2>/dev/null)" || return 0
  [[ "$git_dir" = /* ]] || git_dir="$dest/$git_dir"
  exclude_file="$git_dir/info/exclude"
  mkdir -p "${exclude_file%/*}"
  touch "$exclude_file"
  for pattern in "/$payload_name/" "/$payload_name.tmp/" "/clang-stable/" "/clang-stable.tmp/" "/.lineage-desktop-clang-prebuilt"; do
    grep -qxF "$pattern" "$exclude_file" || printf '%s\n' "$pattern" >>"$exclude_file"
  done
}

clang_write_marker() {
  local dest="$1"
  local payload_name="$2"
  local commit="$3"
  local git_url="$4"
  local git_ref="$5"
  local marker

  marker="$(clang_marker_file "$dest")"
  cat >"$marker" <<EOF
url=$git_url
ref=$git_ref
payload=$payload_name
commit=$commit
EOF
}

clang_payload_name_from_ref() {
  local dest="$1"
  local ref="$2"

  git -C "$dest" ls-tree --name-only "$ref" \
    | grep -E '^clang-r[[:alnum:]_.-]*$' \
    | sort \
    | tail -n 1 || true
}

extract_clang_payload_from_ref() {
  local dest="$1"
  local ref="$2"
  local payload_name="$3"

  rm -rf "$dest/$payload_name.tmp" "$dest/$payload_name"
  mkdir -p "$dest/$payload_name.tmp"
  git -C "$dest" archive "$ref" "$payload_name" \
    | tar -x -C "$dest/$payload_name.tmp" --strip-components=1
  mv "$dest/$payload_name.tmp" "$dest/$payload_name"
}

ensure_linux_x86_clang_stable_alias() {
  local dest="$1"
  local payload_name="$2"

  if [[ -e "$dest/clang-stable/lib/libclang.so" ]]; then
    return 0
  fi

  [[ -e "$dest/$payload_name/lib/libclang.so" ]] || \
    die "x86 Clang payload is missing libclang: ${dest#$workspace/}/$payload_name"
  rm -rf "$dest/clang-stable.tmp" "$dest/clang-stable"
  ln -s "$payload_name" "$dest/clang-stable"
}

ensure_linux_x86_clang_trusty_dirgroup() {
  local dest="$1"
  local payload_name="$2"
  local bp="$dest/Android.bp"

  [[ -d "$dest/$payload_name" ]] || \
    die "missing x86 Clang payload for Trusty dirgroup: ${dest#$workspace/}/$payload_name"

  python3 - "$bp" "$payload_name" <<'PY'
import re
import sys
from pathlib import Path

bp = Path(sys.argv[1])
payload = sys.argv[2]
text = bp.read_text()
pattern = re.compile(
    r'(dirgroup \{\n'
    r'    name: "trusty_dirgroup_prebuilts_clang_host_linux-x86",\n'
    r'    dirs: \[\n)'
    r'(?:        "clang-r[^"]+",\n)+'
    r'(    \],\n'
    r'    visibility: \["//trusty/vendor/google/aosp/scripts"\],\n'
    r'\})'
)
def replacement(match):
    return f'{match.group(1)}        "{payload}",\n{match.group(2)}'
updated, count = pattern.subn(replacement, text, count=1)
if count != 1:
    raise SystemExit(f"failed to update Trusty dirgroup in {bp}")
legacy_ncurses = re.compile(
    r'\nfilegroup \{\n'
    r'    name: "clang-libncurses\.so\.5",\n'
    r'    srcs: \[\n'
    r'        "clang-3289846/lib64/libncurses\.so\.5",\n'
    r'    \],\n'
    r'\}\n?'
)
updated = legacy_ncurses.sub('\n', updated, count=1)
bp.write_text(updated)
PY
}

clone_clang_prebuilt_repo() {
  local host_tag="$1"
  local dest="$2"
  local git_url="$3"
  local git_ref="$4"
  local payload_name="${5:-}"
  local cache_dir tmp_dir clang_dir

  cache_dir="$(arm64_prebuilt_cache_subdir clang)"
  mkdir -p "$cache_dir"
  tmp_dir="$(mktemp -d "$cache_dir/$host_tag.XXXXXX")"
  log "cloning $host_tag Clang prebuilt: $git_url ($git_ref)" >&2
  git_clone_with_retries "$tmp_dir" "clone $host_tag Clang prebuilt" \
    --depth=1 --branch "$git_ref" "$git_url" || \
    die "failed to clone $host_tag Clang prebuilt: $git_url@$git_ref"

  if [[ -n "$payload_name" ]]; then
    clang_dir="$tmp_dir/$payload_name"
  else
    clang_dir="$(clang_payload_dir "$tmp_dir")"
  fi
  [[ -n "$clang_dir" ]] || {
    rm -rf "$tmp_dir"
    die "$host_tag Clang prebuilt is incomplete: $git_url@$git_ref"
  }
  [[ -x "$clang_dir/bin/clang" ]] || {
    rm -rf "$tmp_dir"
    die "$host_tag Clang prebuilt branch is missing requested payload: $git_url@$git_ref:$payload_name"
  }

  rm -rf "$dest.tmp" "$dest"
  mkdir -p "${dest%/*}"
  mv "$tmp_dir" "$dest.tmp"
  mv "$dest.tmp" "$dest"
  printf '%s\n' "$dest/${clang_dir##*/}"
}

# Provision a single Clang payload via a blobless, sparse clone: only the pinned
# payload's blobs are downloaded (~3.5 GB) instead of every payload at the branch
# tip (~18 GB). The promisor remote keeps the Soong metadata (Android.bp,
# soong/clangprebuilts.go) fetchable on demand via `git show`, so the resulting
# $dest has the same shape the repo-managed/extract path produces. Returns
# non-zero on failure (missing payload in the branch, interrupted fetch) so the
# caller can fail with a clear error.
fetch_clang_single_payload() {
  local dest="$1"
  local git_url="$2"
  local git_ref="$3"
  local payload_name="$4"

  [[ -n "$payload_name" ]] || return 1

  rm -rf "$dest.tmp"
  mkdir -p "${dest%/*}"

  if ! git_clone_with_retries "$dest.tmp" "clone single Clang payload" \
       --depth=1 --branch "$git_ref" --filter=blob:none --no-checkout "$git_url"; then
    rm -rf "$dest.tmp"
    return 1
  fi

  # Materialize only the pinned payload directory; its blobs are faulted in from
  # the promisor during checkout, the other payloads are never downloaded.
  if ! git -C "$dest.tmp" sparse-checkout set --no-cone "/$payload_name/" || \
     ! git_network_retry "checkout single Clang payload $payload_name" \
       git -C "$dest.tmp" checkout -q HEAD; then
    rm -rf "$dest.tmp"
    return 1
  fi

  if [[ ! -x "$dest.tmp/$payload_name/bin/clang" ]]; then
    rm -rf "$dest.tmp"
    return 1
  fi

  rm -rf "$dest"
  mv "$dest.tmp" "$dest"
}

linux_arm64_clang_payload_dir() {
  clang_payload_dir "$workspace/prebuilts/clang/host/linux-arm64"
}

set_linux_arm64_clang_version_vars() {
  local clang_dir="$1"
  set_clang_version_vars linux-arm64 "$clang_dir"
}

ensure_linux_arm64_clang_prebuilt() {
  host_is_arm64 || return 0

  local dest="$workspace/prebuilts/clang/host/linux-arm64"
  local clang_dir=""

  if [[ -f "$dest/.lineage-desktop-clang-overlay" || -L "$dest" ]]; then
    rm -rf "$dest"
  fi

  if [[ -x "$dest/$linux_arm64_clang_prebuilt_version/bin/clang" ]]; then
    clang_dir="$dest/$linux_arm64_clang_prebuilt_version"
  fi
  if [[ -n "$clang_dir" ]]; then
    set_linux_arm64_clang_version_vars "$clang_dir"
    log "using ARM64 Clang prebuilt ${dest#$workspace/}/$linux_arm64_llvm_prebuilts_version"
    return 0
  fi

  clang_dir="$(clone_clang_prebuilt_repo linux-arm64 "$dest" \
    "$linux_arm64_clang_prebuilt_git_url" \
    "$linux_arm64_clang_prebuilt_git_ref" \
    "$linux_arm64_clang_prebuilt_version")"
  set_linux_arm64_clang_version_vars "$clang_dir"

  log "installed ARM64 Clang prebuilt at ${dest#$workspace/}/$linux_arm64_llvm_prebuilts_version"
}

set_linux_x86_clang_version_vars() {
  local clang_dir="$1"
  set_clang_version_vars linux-x86 "$clang_dir"
}

ensure_linux_x86_clang_soong_compat() {
  local clang_dir="$1"
  local lib_dir="$clang_dir/lib"

  if [[ ! -e "$lib_dir/libc++.so" ]]; then
    [[ -f "$lib_dir/x86_64-unknown-linux-gnu/libc++.so" ]] || \
      die "missing x86_64 glibc libc++ in ${clang_dir#$workspace/}"
    ln -s "x86_64-unknown-linux-gnu/libc++.so" "$lib_dir/libc++.so"
  fi
}

linux_x86_clang_soong_metadata_is_compatible() {
  local dest="$1"

  [[ -f "$dest/soong/Android.bp" ]] && \
    [[ -x "$dest/soong/generate_clang_builtin_headers_resources.sh" ]] && \
    grep -Fq 'name: "soong-clang-prebuilts"' "$dest/soong/Android.bp" && \
    grep -Fq 'pluginFor: ["soong_build"]' "$dest/soong/Android.bp" && \
    grep -Fq '../i386-unknown-linux-gnu' "$dest/soong/clangprebuilts.go" && \
    grep -Fq '../x86_64-unknown-linux-gnu' "$dest/soong/clangprebuilts.go"
}

sync_linux_x86_clang_soong_metadata() {
  local dest="$1"
  local ref="$2"

  mkdir -p "$dest/soong"
  git -C "$dest" show "$ref:Android.bp" >"$dest/Android.bp"
  git -C "$dest" show "$ref:soong/Android.bp" >"$dest/soong/Android.bp"
  git -C "$dest" show "$ref:soong/clangprebuilts.go" >"$dest/soong/clangprebuilts.go"
  git -C "$dest" show "$ref:soong/generate_clang_builtin_headers_resources.sh" >"$dest/soong/generate_clang_builtin_headers_resources.sh"
  chmod +x "$dest/soong/generate_clang_builtin_headers_resources.sh"
  if linux_x86_clang_soong_metadata_is_compatible "$dest"; then
    return 0
  fi

  die "x86 Clang metadata from $ref is incompatible with the pinned Clang prebuilt"
}

ensure_linux_x86_clang_prebuilt() {
  host_is_arm64 && return 0

  local dest="$workspace/prebuilts/clang/host/linux-x86"
  local clang_dir payload_name cached_commit fetched_commit link_target

  if git -C "$dest" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    payload_name="$linux_x86_clang_prebuilt_version"
    [[ -n "$payload_name" ]] || \
      payload_name="$(clang_marker_value "$(clang_marker_file "$dest")" payload || true)"
    [[ -n "$payload_name" ]] || payload_name="$(clang_payload_name_from_metadata "$dest" || true)"
    if [[ -n "$payload_name" && -L "$dest/$payload_name" ]]; then
      link_target="$(readlink "$dest/$payload_name")"
      case "$link_target" in
        *linux-arm64*|*aarch64*)
          log "removing ARM64 Clang overlay from x86 prebuilt path: ${dest#$workspace/}/$payload_name -> $link_target"
          rm -f "$dest/$payload_name"
          ;;
      esac
    fi
    if [[ -n "$payload_name" && -x "$dest/$payload_name/bin/clang" ]] && \
       executable_is_arm64_elf "$dest/$payload_name/bin/clang"; then
      log "removing ARM64 Clang payload from x86 prebuilt path: ${dest#$workspace/}/$payload_name"
      rm -rf "$dest/$payload_name"
    fi
    if [[ -n "$payload_name" && -x "$dest/$payload_name/bin/clang" ]]; then
      cached_commit="$(clang_cached_commit "$dest" "$payload_name" \
        "$linux_x86_clang_prebuilt_git_url" "$linux_x86_clang_prebuilt_git_ref" || true)"
      if [[ -n "$cached_commit" ]] && git -C "$dest" cat-file -e "$cached_commit^{commit}" 2>/dev/null; then
        log "using cached x86 Clang prebuilt ${dest#$workspace/}/$payload_name"
        sync_linux_x86_clang_soong_metadata "$dest" "$cached_commit"
        clang_exclude_payload "$dest" "$payload_name"
        clang_write_marker "$dest" "$payload_name" "$cached_commit" \
          "$linux_x86_clang_prebuilt_git_url" "$linux_x86_clang_prebuilt_git_ref"
        ensure_linux_x86_clang_stable_alias "$dest" "$payload_name"
        ensure_linux_x86_clang_trusty_dirgroup "$dest" "$payload_name"
        clang_dir="$dest/$payload_name"
        set_linux_x86_clang_version_vars "$clang_dir"
        ensure_linux_x86_clang_soong_compat "$clang_dir"
        return 0
      fi
    fi

    log "syncing x86 Clang prebuilt: $linux_x86_clang_prebuilt_git_url ($linux_x86_clang_prebuilt_git_ref)"
    git_network_retry "fetch x86 Clang prebuilt" \
      git -C "$dest" fetch --depth=1 "$linux_x86_clang_prebuilt_git_url" "$linux_x86_clang_prebuilt_git_ref" || \
      die "failed to fetch x86 Clang prebuilt: $linux_x86_clang_prebuilt_git_url@$linux_x86_clang_prebuilt_git_ref"
    fetched_commit="$(git -C "$dest" rev-parse FETCH_HEAD)"
    if [[ -z "$payload_name" ]]; then
      payload_name="$(clang_payload_name_from_ref "$dest" FETCH_HEAD)"
    elif ! git -C "$dest" cat-file -e "FETCH_HEAD:$payload_name/bin/clang" 2>/dev/null; then
      die "x86 Clang prebuilt branch is missing requested payload: $linux_x86_clang_prebuilt_git_url@$linux_x86_clang_prebuilt_git_ref:$payload_name"
    fi
    [[ -n "$payload_name" ]] || \
      die "x86 Clang prebuilt branch has no clang-r* payload: $linux_x86_clang_prebuilt_git_url@$linux_x86_clang_prebuilt_git_ref"
    extract_clang_payload_from_ref "$dest" FETCH_HEAD "$payload_name"
    sync_linux_x86_clang_soong_metadata "$dest" FETCH_HEAD
    ensure_linux_x86_clang_stable_alias "$dest" "$payload_name"
    ensure_linux_x86_clang_trusty_dirgroup "$dest" "$payload_name"
    clang_dir="$dest/$payload_name"
  elif [[ ! -e "$dest" ]]; then
    fetch_clang_single_payload "$dest" \
      "$linux_x86_clang_prebuilt_git_url" \
      "$linux_x86_clang_prebuilt_git_ref" \
      "$linux_x86_clang_prebuilt_version" || \
      die "failed to fetch pinned x86 Clang payload $linux_x86_clang_prebuilt_version from $linux_x86_clang_prebuilt_git_url@$linux_x86_clang_prebuilt_git_ref"
    clang_dir="$dest/$linux_x86_clang_prebuilt_version"
    fetched_commit="$(git -C "$dest" rev-parse HEAD)"
    sync_linux_x86_clang_soong_metadata "$dest" HEAD
    ensure_linux_x86_clang_stable_alias "$dest" "$linux_x86_clang_prebuilt_version"
    ensure_linux_x86_clang_trusty_dirgroup "$dest" "$linux_x86_clang_prebuilt_version"
  else
    die "cannot install pinned x86 Clang prebuilt over existing non-git path: ${dest#$workspace/}"
  fi

  [[ -n "$clang_dir" ]] || \
    die "x86 Clang prebuilt is incomplete: $linux_x86_clang_prebuilt_git_url@$linux_x86_clang_prebuilt_git_ref"
  set_linux_x86_clang_version_vars "$clang_dir"
  ensure_linux_x86_clang_stable_alias "$dest" "$linux_x86_llvm_prebuilts_version"
  ensure_linux_x86_clang_trusty_dirgroup "$dest" "$linux_x86_llvm_prebuilts_version"
  ensure_linux_x86_clang_soong_compat "$clang_dir"
  if [[ -n "${fetched_commit:-}" ]]; then
    clang_exclude_payload "$dest" "$linux_x86_llvm_prebuilts_version"
    clang_write_marker "$dest" "$linux_x86_llvm_prebuilts_version" "$fetched_commit" \
      "$linux_x86_clang_prebuilt_git_url" "$linux_x86_clang_prebuilt_git_ref"
  fi

  log "using x86 Clang prebuilt ${dest#$workspace/}/$linux_x86_llvm_prebuilts_version"
}

ensure_linux_arm64_clang_ready() {
  host_is_arm64 || return 0
  [[ -n "$linux_arm64_llvm_prebuilts_version" ]] || die "ARM64 Clang version has not been detected"

  local arm64_dir="$workspace/prebuilts/clang/host/linux-arm64/$linux_arm64_llvm_prebuilts_version"
  local lib_dir="$arm64_dir/lib"

  [[ -x "$arm64_dir/bin/clang" ]] || \
    die "missing ARM64 Clang payload: ${arm64_dir#$workspace/}"
  require_arm64_prebuilt_executable "$arm64_dir/bin/clang" "ARM64 Clang"
  require_arm64_prebuilt_executable "$arm64_dir/bin/clang++" "ARM64 Clang++"
  [[ -f "$arm64_dir/include/c++/v1/string" ]] || \
    die "ARM64 Clang prebuilt is missing libc++ headers: ${arm64_dir#$workspace/}/include/c++/v1/string"
  [[ -f "$arm64_dir/android_libc++/platform/aarch64/include/c++/v1/__config_site" ]] || \
    die "ARM64 Clang prebuilt is missing Android libc++ headers: ${arm64_dir#$workspace/}/android_libc++/platform/aarch64/include/c++/v1/__config_site"

  if [[ ! -e "$lib_dir/libc++.so" ]]; then
    [[ -f "$lib_dir/aarch64-unknown-linux-musl/libc++.so" ]] || \
      die "missing ARM64 libc++ in ${arm64_dir#$workspace/}"
    ln -s "aarch64-unknown-linux-musl/libc++.so" "$lib_dir/libc++.so"
  fi

  log "using ARM64 Clang prebuilt ${arm64_dir#$workspace/}"
}

ensure_linux_arm64_clang_trusty_dirgroup() {
  host_is_arm64 || return 0
  [[ -n "$linux_arm64_llvm_prebuilts_version" ]] || die "ARM64 Clang version has not been detected"

  local module="trusty_dirgroup_prebuilts_clang_host_linux-arm64"
  local arm64_root="$workspace/prebuilts/clang/host/linux-arm64"
  local clang_bp="$arm64_root/Android.bp"
  local trusty_bp="$workspace/trusty/vendor/google/aosp/scripts/Android.bp"
  local tmp entry anchor

  [[ -d "$arm64_root/$linux_arm64_llvm_prebuilts_version" ]] || \
    die "missing ARM64 Clang payload for Trusty dirgroup: ${arm64_root#$workspace/}/$linux_arm64_llvm_prebuilts_version"

  tmp="$clang_bp.tmp"
  cat >"$tmp" <<EOF
dirgroup {
    name: "$module",
    dirs: ["$linux_arm64_llvm_prebuilts_version"],
    visibility: ["//trusty/vendor/google/aosp/scripts"],
}
EOF
  if ! cmp -s "$tmp" "$clang_bp"; then
    mv "$tmp" "$clang_bp"
    log "updated Trusty ARM64 Clang dirgroup metadata: ${clang_bp#$workspace/}"
  else
    rm -f "$tmp"
  fi

  entry="        \":$module\","
  if grep -Fqx "$entry" "$trusty_bp"; then
    return 0
  fi

  anchor='        ":trusty_dirgroup_prebuilts_clang-tools",'
  grep -Fqx "$anchor" "$trusty_bp" || \
    die "failed to find Trusty clang-tools dirgroup anchor in ${trusty_bp#$workspace/}"

  tmp="$trusty_bp.tmp"
  awk -v anchor="$anchor" -v entry="$entry" '
    { print }
    $0 == anchor { print entry }
  ' "$trusty_bp" >"$tmp"
  mv "$tmp" "$trusty_bp"
  log "added ARM64 Clang dirgroup to Trusty sandbox inputs"
}

ensure_linux_x86_clang_arm64_soong_compat() {
  host_is_arm64 || return 0
  [[ -n "$linux_arm64_llvm_prebuilts_version" ]] || die "ARM64 Clang version has not been detected"

  local payload="$linux_arm64_llvm_prebuilts_version"
  local dest="$workspace/prebuilts/clang/host/linux-x86"
  local arm64_dir="$workspace/prebuilts/clang/host/linux-arm64/$payload"
  local overlay="$dest/$payload"
  local tmp="$overlay.tmp"
  local entry name path

  [[ -d "$dest" ]] || die "missing linux-x86 Clang metadata package: ${dest#$workspace/}"
  [[ -x "$arm64_dir/bin/clang" ]] || die "missing ARM64 Clang payload: ${arm64_dir#$workspace/}"

  if [[ -e "$overlay" || -L "$overlay" ]]; then
    if [[ -f "$overlay/.lineage-desktop-arm64-clang-compat" ]]; then
      rm -rf "$overlay"
    elif [[ -x "$overlay/bin/clang" ]] && executable_is_arm64_elf "$overlay/bin/clang"; then
      rm -rf "$overlay"
    elif [[ ! -x "$overlay/bin/clang" ]]; then
      rm -rf "$overlay"
    else
      die "refusing to use non-ARM64 Clang payload on ARM64 host: ${overlay#$workspace/}"
    fi
  fi

  rm -rf "$tmp"
  mkdir -p "$tmp/lib" "$tmp/include"

  for entry in "$arm64_dir"/*; do
    [[ -e "$entry" ]] || continue
    name="${entry##*/}"
    case "$name" in
      lib|include) continue ;;
    esac
    ln -s "../../linux-arm64/$payload/$name" "$tmp/$name"
  done

  for entry in "$arm64_dir/lib"/*; do
    [[ -e "$entry" ]] || continue
    name="${entry##*/}"
    case "$name" in
      i386-unknown-linux-gnu|x86_64-unknown-linux-gnu) continue ;;
    esac
    ln -s "../../../linux-arm64/$payload/lib/$name" "$tmp/lib/$name"
  done
  ln -s "i686-unknown-linux-musl" "$tmp/lib/i386-unknown-linux-gnu"
  ln -s "x86_64-unknown-linux-musl" "$tmp/lib/x86_64-unknown-linux-gnu"

  for entry in "$arm64_dir/include"/*; do
    [[ -e "$entry" ]] || continue
    name="${entry##*/}"
    case "$name" in
      i386-unknown-linux-gnu|x86_64-unknown-linux-gnu) continue ;;
    esac
    ln -s "../../../linux-arm64/$payload/include/$name" "$tmp/include/$name"
  done
  ln -s "i686-unknown-linux-musl" "$tmp/include/i386-unknown-linux-gnu"
  ln -s "x86_64-unknown-linux-musl" "$tmp/include/x86_64-unknown-linux-gnu"

  : > "$tmp/.lineage-desktop-arm64-clang-compat"
  mv "$tmp" "$overlay"
  clang_exclude_payload "$dest" "$payload"

  for path in \
    bin/llvm-cxxfilt \
    bin/llvm-objcopy \
    bin/llvm-strip \
    bin/llvm-symbolizer \
    lib/libc++.so \
    lib/x86_64-unknown-linux-gnu/libc++.so; do
    [[ -e "$overlay/$path" ]] || \
      die "ARM64 Clang Soong compatibility overlay is missing $path: ${overlay#$workspace/}"
  done
  require_arm64_prebuilt_executable "$overlay/bin/clang" "ARM64 Clang Soong compatibility overlay"

  log "using ARM64 Clang Soong compatibility overlay at ${overlay#$workspace/}"
}

ensure_arm64_native_cmake_prebuilt() {
  host_is_arm64 || return 0

  local dest="$workspace/prebuilts/cmake/linux-arm64"
  local cache_dir tmp_dir

  if [[ -L "$dest" ]]; then
    rm -f "$dest"
  fi

  if [[ -x "$dest/bin/cmake" ]]; then
    require_arm64_prebuilt_executable "$dest/bin/cmake" "ARM64 CMake"
    log "using ARM64 CMake prebuilt at ${dest#$workspace/}"
    return 0
  fi

  cache_dir="$(arm64_prebuilt_cache_subdir cmake)"
  mkdir -p "$cache_dir"
  tmp_dir="$(mktemp -d "$cache_dir/linux-arm64.XXXXXX")"
  log "cloning ARM64 CMake prebuilt: $arm64_cmake_prebuilt_git_url ($arm64_cmake_prebuilt_git_ref)"
  git_clone_with_retries "$tmp_dir" "clone ARM64 CMake prebuilt" \
    --depth=1 --branch "$arm64_cmake_prebuilt_git_ref" "$arm64_cmake_prebuilt_git_url" || {
      rm -rf "$tmp_dir"
      die "failed to clone ARM64 CMake prebuilt: $arm64_cmake_prebuilt_git_url@$arm64_cmake_prebuilt_git_ref"
    }

  if [[ ! -x "$tmp_dir/bin/cmake" ]]; then
    rm -rf "$tmp_dir"
    die "ARM64 CMake prebuilt is incomplete: $arm64_cmake_prebuilt_git_url@$arm64_cmake_prebuilt_git_ref"
  fi

  rm -rf "$dest.tmp" "$dest"
  mkdir -p "${dest%/*}"
  mv "$tmp_dir" "$dest.tmp"
  mv "$dest.tmp" "$dest"
  require_arm64_prebuilt_executable "$dest/bin/cmake" "ARM64 CMake"

  log "installed ARM64 CMake prebuilt at ${dest#$workspace/}"
}

ensure_arm64_native_jdk21_prebuilt() {
  host_is_arm64 || return 0

  local dest="$workspace/prebuilts/jdk/jdk21/linux-arm64"
  local cache_dir archive tmp_dir extract_dir version

  if [[ -x "$dest/bin/javac" && -x "$dest/bin/jlink" && -f "$dest/jmods/java.base.jmod" ]]; then
    version="$("$dest/bin/jlink" --version 2>/dev/null || true)"
    if [[ "$version" == 21.* ]]; then
      require_arm64_prebuilt_executable "$dest/bin/javac" "ARM64 JDK 21 javac"
      require_arm64_prebuilt_executable "$dest/bin/jlink" "ARM64 JDK 21 jlink"
      log "using ARM64 JDK 21 prebuilt at ${dest#$workspace/} ($version)"
      return 0
    fi
    log "warning: ignoring ARM64 JDK prebuilt with unexpected jlink version '$version'"
  fi

  cache_dir="$(arm64_prebuilt_cache_subdir jdk21)"
  archive="$cache_dir/jdk21-linux-arm64.tar.gz"
  mkdir -p "$cache_dir"

  if [[ ! -s "$archive" ]]; then
    log "downloading ARM64 JDK 21 prebuilt: $arm64_jdk21_prebuilt_url"
    curl -fL --retry 5 --retry-delay 5 \
      "$arm64_jdk21_prebuilt_url" -o "$archive.tmp"
    mv "$archive.tmp" "$archive"
  fi

  tmp_dir="$(mktemp -d "$cache_dir/linux-arm64.XXXXXX")"
  extract_dir="$tmp_dir/extract"
  mkdir -p "$extract_dir"
  tar -xzf "$archive" -C "$extract_dir" --strip-components=1 || {
    rm -rf "$tmp_dir" "$archive"
    die "failed to extract ARM64 JDK 21 prebuilt archive"
  }

  [[ -x "$extract_dir/bin/javac" && -x "$extract_dir/bin/jlink" && -f "$extract_dir/jmods/java.base.jmod" ]] || {
    rm -rf "$tmp_dir" "$archive"
    die "ARM64 JDK 21 prebuilt archive is incomplete: $arm64_jdk21_prebuilt_url"
  }

  version="$("$extract_dir/bin/jlink" --version 2>/dev/null || true)"
  [[ "$version" == 21.* ]] || {
    rm -rf "$tmp_dir" "$archive"
    die "ARM64 JDK prebuilt has unexpected jlink version '$version'; expected 21.x"
  }

  rm -rf "$dest.tmp" "$dest"
  mkdir -p "${dest%/*}"
  touch "$extract_dir/.lineage-desktop-jdk-overlay"
  mv "$extract_dir" "$dest.tmp"
  mv "$dest.tmp" "$dest"
  rm -rf "$tmp_dir"
  require_arm64_prebuilt_executable "$dest/bin/javac" "ARM64 JDK 21 javac"
  require_arm64_prebuilt_executable "$dest/bin/jlink" "ARM64 JDK 21 jlink"

  log "installed ARM64 JDK 21 prebuilt at ${dest#$workspace/} ($version)"
}

ensure_arm64_jdk8_prebuilt() {
  host_is_arm64 || return 0

  local dest="$workspace/prebuilts/jdk/jdk8/linux-arm64"
  local cache_dir archive tmp_dir extract_dir version

  if [[ -L "$dest" ]]; then
    log "removing ARM64 JDK 8 symlink before installing real prebuilt: ${dest#$workspace/} -> $(readlink "$dest")"
    rm -f "$dest"
  fi

  if [[ -x "$dest/bin/java" && -x "$dest/bin/javac" && -f "$dest/jre/lib/rt.jar" ]]; then
    version="$("$dest/bin/java" -version 2>&1 | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -n 1)"
    if [[ "$version" == 1.8.* || "$version" == 8* ]]; then
      require_arm64_prebuilt_executable "$dest/bin/java" "ARM64 JDK 8 java"
      require_arm64_prebuilt_executable "$dest/bin/javac" "ARM64 JDK 8 javac"
      log "using ARM64 JDK 8 prebuilt at ${dest#$workspace/} ($version)"
      return 0
    fi
    log "warning: ignoring ARM64 JDK 8 prebuilt with unexpected java version '$version'"
  fi

  cache_dir="$(arm64_prebuilt_cache_subdir jdk8)"
  archive="$cache_dir/jdk8-linux-arm64.tar.gz"
  mkdir -p "$cache_dir"

  if [[ ! -s "$archive" ]]; then
    log "downloading ARM64 JDK 8 prebuilt: $arm64_jdk8_prebuilt_url"
    curl -fL --retry 5 --retry-delay 5 \
      "$arm64_jdk8_prebuilt_url" -o "$archive.tmp"
    mv "$archive.tmp" "$archive"
  fi

  tmp_dir="$(mktemp -d "$cache_dir/linux-arm64.XXXXXX")"
  extract_dir="$tmp_dir/extract"
  mkdir -p "$extract_dir"
  tar -xzf "$archive" -C "$extract_dir" --strip-components=1 || {
    rm -rf "$tmp_dir" "$archive"
    die "failed to extract ARM64 JDK 8 prebuilt archive"
  }

  [[ -x "$extract_dir/bin/java" && -x "$extract_dir/bin/javac" && -f "$extract_dir/jre/lib/rt.jar" ]] || {
    rm -rf "$tmp_dir" "$archive"
    die "ARM64 JDK 8 prebuilt archive is incomplete: $arm64_jdk8_prebuilt_url"
  }

  version="$("$extract_dir/bin/java" -version 2>&1 | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -n 1)"
  [[ "$version" == 1.8.* || "$version" == 8* ]] || {
    rm -rf "$tmp_dir" "$archive"
    die "ARM64 JDK 8 prebuilt has unexpected java version '$version'; expected 1.8.x"
  }

  rm -rf "$dest.tmp" "$dest"
  mkdir -p "${dest%/*}"
  touch "$extract_dir/.lineage-desktop-jdk-overlay"
  mv "$extract_dir" "$dest.tmp"
  mv "$dest.tmp" "$dest"
  rm -rf "$tmp_dir"
  require_arm64_prebuilt_executable "$dest/bin/java" "ARM64 JDK 8 java"
  require_arm64_prebuilt_executable "$dest/bin/javac" "ARM64 JDK 8 javac"

  log "installed ARM64 JDK 8 prebuilt at ${dest#$workspace/} ($version)"
}

executable_is_arm64_elf() {
  local path="$1"

  if command -v readelf >/dev/null 2>&1; then
    readelf -h "$path" 2>/dev/null | grep -Eq 'Machine:[[:space:]]+AArch64' && return 0
    return 1
  fi

  command -v file >/dev/null 2>&1 || return 1
  file -Lb "$path" 2>/dev/null | grep -Eiq 'aarch64|arm64|AArch64'
}

require_arm64_prebuilt_executable() {
  local path="$1"
  local label="$2"

  [[ -x "$path" ]] || die "missing executable for $label: ${path#$workspace/}"
  executable_is_arm64_elf "$path" || \
    die "$label is not an ARM64 ELF executable: ${path#$workspace/}"
}

require_arm64_rust_stdlibs() {
  local rust_root="$1"
  local version="$2"
  local triple

  for triple in aarch64-unknown-linux-gnu aarch64-unknown-linux-musl; do
    [[ -d "$rust_root/$version/lib/rustlib/$triple/lib" ]] || \
      die "ARM64 Rust prebuilt is missing $triple stdlib: ${rust_root#$workspace/}/$version"
  done
}

require_arm64_rust_tools() {
  local rust_root="$1"
  local version="$2"
  local tool

  for tool in rustc clippy-driver rustdoc rustfmt cargo cargo-clippy cargo-fmt; do
    require_arm64_prebuilt_executable "$rust_root/$version/bin/$tool" "ARM64 Rust $tool"
  done
}

ensure_arm64_rust_tool_bridge() {
  host_is_arm64 || return 0

  local tool="$1"
  local version arm64_tool musl_bin musl_tool backup tmp
  version="$(rust_prebuilt_version "$workspace")"
  [[ -n "$version" ]] || die "failed to detect Rust prebuilt version"
  arm64_tool="$workspace/prebuilts/rust/linux-arm64/$version/bin/$tool"
  musl_bin="$workspace/prebuilts/rust/linux-musl-x86/$version/bin"
  musl_tool="$musl_bin/$tool"
  backup="$musl_bin/$tool.android-linux-musl-x86"

  [[ -x "$arm64_tool" ]] || \
    die "missing ARM64 Rust $tool for compiler bridge: ${arm64_tool#$workspace/}"
  [[ -d "$musl_bin" ]] || \
    die "missing Android Rust linux-musl-x86 bin directory: ${musl_bin#$workspace/}"

  if [[ -f "$musl_tool" ]] && \
     grep -Eaq 'lineage_desktop_arm64_rust(c|_tool)_bridge|linux-arm64|arm64_rustc|arm64_tool' "$musl_tool"; then
    log "using ARM64 Rust $tool bridge at ${musl_tool#$workspace/}"
    return 0
  fi

  if [[ -e "$musl_tool" && ! -e "$backup" ]]; then
    mv "$musl_tool" "$backup"
  fi
  [[ -x "$backup" ]] || \
    die "missing original Android Rust $tool backup for bridge: ${backup#$workspace/}"

  tmp="$musl_tool.tmp.$$"
  cat > "$tmp" <<'RUST_TOOL_BRIDGE'
#!/bin/bash
# lineage_desktop_arm64_rust_tool_bridge
set -e

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version="$(basename "$(dirname "$script_dir")")"
tool="$(basename "$0")"
arm64_tool="$script_dir/../../../linux-arm64/$version/bin/$tool"

if [[ ! -x "$arm64_tool" ]]; then
  top="${ANDROID_BUILD_TOP:-$(pwd)}"
  arm64_tool="$top/prebuilts/rust/linux-arm64/$version/bin/$tool"
fi
if [[ ! -x "$arm64_tool" ]]; then
  printf 'lineage-desktop: missing ARM64 Rust %s for bridge: %s\n' "$tool" "$arm64_tool" >&2
  exit 1
fi

export RUSTC_BOOTSTRAP="${RUSTC_BOOTSTRAP:-1}"
exec "$arm64_tool" "$@"
RUST_TOOL_BRIDGE
  chmod +x "$tmp"
  mv "$tmp" "$musl_tool"
  log "installed ARM64 Rust $tool bridge at ${musl_tool#$workspace/}"
}

ensure_arm64_rust_tool_bridges() {
  host_is_arm64 || return 0

  local tool
  for tool in rustc clippy-driver rustdoc rustfmt cargo cargo-clippy cargo-fmt; do
    ensure_arm64_rust_tool_bridge "$tool"
  done
}

restore_android_rust_tool_bridge() {
  host_is_arm64 && return 0

  local tool="$1"
  local version musl_bin musl_tool backup
  version="$(rust_prebuilt_version "$workspace")"
  [[ -n "$version" ]] || return 0
  musl_bin="$workspace/prebuilts/rust/linux-musl-x86/$version/bin"
  musl_tool="$musl_bin/$tool"
  backup="$musl_bin/$tool.android-linux-musl-x86"
  [[ -d "$musl_bin" ]] || return 0

  if [[ ! -e "$musl_tool" && -x "$backup" ]]; then
    mv "$backup" "$musl_tool"
    log "restored Android Rust $tool at ${musl_tool#$workspace/}"
    return 0
  fi
  if [[ -f "$musl_tool" ]] && \
     grep -Eaq 'lineage_desktop_arm64_rust(c|_tool)_bridge|linux-arm64|arm64_rustc|arm64_tool' "$musl_tool"; then
    [[ -x "$backup" ]] || \
      die "x86 host found ARM64 Rust $tool bridge without original backup: ${backup#$workspace/}"
    mv "$backup" "$musl_tool"
    log "restored Android Rust $tool at ${musl_tool#$workspace/}"
  fi
}

restore_android_rust_tool_bridges() {
  host_is_arm64 && return 0

  local tool
  for tool in rustc clippy-driver rustdoc rustfmt cargo cargo-clippy cargo-fmt; do
    restore_android_rust_tool_bridge "$tool"
  done
}

ensure_no_arm64_x86_prebuilt_substitutions() {
  host_is_arm64 || return 0

  local link target
  while IFS= read -r link; do
    [[ "$(basename "$link")" == "linux-arm64" ]] || continue
    target="$(readlink "$link")"
    case "$target" in
      *linux-x86*|*x86_64*|*x86-64*)
        die "ARM64 prebuilt path points at an x86 prebuilt: ${link#$workspace/} -> $target"
        ;;
    esac
  done < <(find "$workspace/prebuilts" -path '*linux-arm64*' -type l -print 2>/dev/null)
}

find_arm64_prebuilt_payload_dir() {
  local root="$1"
  local probe="$2"
  local match

  if [[ -e "$root/$probe" ]]; then
    printf '%s\n' "$root"
    return 0
  fi

  if [[ -e "$root/linux-arm64/$probe" ]]; then
    printf '%s\n' "$root/linux-arm64"
    return 0
  fi

  match="$(find "$root" -path "*/linux-arm64/$probe" -print -quit 2>/dev/null || true)"
  if [[ -n "$match" ]]; then
    printf '%s\n' "${match%/$probe}"
    return 0
  fi

  return 1
}

install_arm64_prebuilt_from_dir() {
  local source_dir="$1"
  local dest="$2"
  local probe="$3"
  local label="$4"
  local payload_dir

  [[ -d "$source_dir" ]] || die "$label source directory does not exist: $source_dir"
  payload_dir="$(find_arm64_prebuilt_payload_dir "$source_dir" "$probe")" || \
    die "$label source does not contain a linux-arm64 payload with $probe: $source_dir"

  rm -rf "$dest.tmp"
  mkdir -p "$dest.tmp"
  cp -a "$payload_dir/." "$dest.tmp/"
  rm -rf "$dest"
  mkdir -p "${dest%/*}"
  mv "$dest.tmp" "$dest"
}

download_arm64_prebuilt_archive() {
  local archive_source="$1"
  local cache_dir="$2"
  local label="$3"
  local archive_path

  mkdir -p "$cache_dir"
  archive_path="$cache_dir/${archive_source##*/}"
  [[ -n "${archive_path##*/}" ]] || archive_path="$cache_dir/prebuilt.tar"

  case "$archive_source" in
    http://*|https://*)
      if [[ ! -s "$archive_path" ]]; then
        log "downloading $label prebuilt archive: $archive_source" >&2
        curl -fL --retry 5 --retry-delay 5 "$archive_source" -o "$archive_path.tmp"
        mv "$archive_path.tmp" "$archive_path"
      fi
      ;;
    *)
      [[ -f "$archive_source" ]] || die "$label archive does not exist: $archive_source"
      cp -f "$archive_source" "$archive_path"
      ;;
  esac

  printf '%s\n' "$archive_path"
}

extract_arm64_prebuilt_archive() {
  local archive_path="$1"
  local extract_dir="$2"

  mkdir -p "$extract_dir"
  case "$archive_path" in
    *.zip)
      python3 - "$archive_path" "$extract_dir" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    archive.extractall(sys.argv[2])
PY
      ;;
    *)
      tar -xf "$archive_path" -C "$extract_dir"
      ;;
  esac
}

install_arm64_prebuilt_from_archive() {
  local archive_source="$1"
  local dest="$2"
  local probe="$3"
  local label="$4"
  local cache_dir archive_path tmp_dir

  cache_dir="$(arm64_prebuilt_cache_subdir archives)"
  archive_path="$(download_arm64_prebuilt_archive "$archive_source" "$cache_dir" "$label")"
  tmp_dir="$(mktemp -d "$cache_dir/extract.XXXXXX")"
  extract_arm64_prebuilt_archive "$archive_path" "$tmp_dir"
  install_arm64_prebuilt_from_dir "$tmp_dir" "$dest" "$probe" "$label"
  rm -rf "$tmp_dir"
}

install_arm64_prebuilt_from_git() {
  local git_url="$1"
  local git_ref="$2"
  local dest="$3"
  local probe="$4"
  local label="$5"
  local cache_dir tmp_dir
  local -a clone_args

  cache_dir="$(arm64_prebuilt_cache_subdir git)"
  mkdir -p "$cache_dir"
  tmp_dir="$(mktemp -d "$cache_dir/git.XXXXXX")"
  clone_args=(--depth=1)
  if [[ -n "$git_ref" ]]; then
    clone_args+=(--branch "$git_ref")
    log "cloning $label ARM64 prebuilt: $git_url ($git_ref)"
  else
    log "cloning $label ARM64 prebuilt: $git_url"
  fi
  git_clone_with_retries "$tmp_dir" "clone $label ARM64 prebuilt" \
    "${clone_args[@]}" "$git_url" || \
    die "failed to clone $label ARM64 prebuilt: $git_url${git_ref:+@$git_ref}"
  install_arm64_prebuilt_from_dir "$tmp_dir" "$dest" "$probe" "$label"
  rm -rf "$tmp_dir"
}

prepare_arm64_rust_upstream_component() {
  local component="$1"
  local probe="$2"
  local cache_dir archive extract_dir root

  cache_dir="$(arm64_prebuilt_cache_subdir rust)"
  archive="$cache_dir/$component.tar.xz"
  extract_dir="$cache_dir/extract-$component"
  root="$extract_dir/$component"

  mkdir -p "$cache_dir"
  if [[ ! -s "$archive" ]]; then
    ensure_downloader
    log "downloading ARM64 Rust upstream component: $component" >&2
    download_file "$arm64_rust_upstream_base_url/$component.tar.xz" "$archive.tmp"
    mv "$archive.tmp" "$archive"
  fi

  if [[ ! -e "$root/$probe" ]]; then
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"
    tar -xf "$archive" -C "$extract_dir" || {
      rm -rf "$extract_dir" "$archive"
      die "failed to extract ARM64 Rust upstream component archive: $archive"
    }
  fi
  [[ -e "$root/$probe" ]] || \
    die "ARM64 Rust upstream component is incomplete: $archive"
  printf '%s\n' "$root"
}

install_arm64_rust_from_upstream_dist() {
  local version="$1"
  local dest="$2"
  local base cache_dir gnu_root musl_root install_dir

  base="$workspace/prebuilts/rust/linux-musl-x86/$version"
  [[ -d "$base" ]] || \
    die "missing Android Rust template prebuilt: ${base#$workspace/}"

  gnu_root="$(prepare_arm64_rust_upstream_component \
    "rust-$version-aarch64-unknown-linux-gnu" "rustc/bin/rustc")"
  musl_root="$(prepare_arm64_rust_upstream_component \
    "rust-std-$version-aarch64-unknown-linux-musl" \
    "rust-std-aarch64-unknown-linux-musl/lib/rustlib/aarch64-unknown-linux-musl/lib")"

  cache_dir="$(arm64_prebuilt_cache_subdir rust)"
  install_dir="$(mktemp -d "$cache_dir/install.XXXXXX")"
  "$gnu_root/install.sh" --prefix="$install_dir" --disable-ldconfig >/dev/null
  "$musl_root/install.sh" --prefix="$install_dir" --disable-ldconfig >/dev/null

  rm -rf "$dest.tmp"
  mkdir -p "$dest.tmp/$version"
  cp -a "$base/." "$dest.tmp/$version/"
  cp -a "$install_dir/." "$dest.tmp/$version/"
  rm -rf "$dest"
  mkdir -p "${dest%/*}"
  mv "$dest.tmp" "$dest"
  rm -rf "$install_dir"
}

cleanup_arm64_prebuilt_download_caches() {
  host_is_arm64 || return 0

  rm -rf \
    "$workspace/out/lineage-desktop/arm64-prebuilts" \
    "$workspace/out/lineage-desktop/go-prebuilts" \
    "$workspace/out/lineage-desktop/clang-prebuilts" \
    "$workspace/out/lineage-desktop/cmake-prebuilts" \
    "$workspace/out/lineage-desktop/jdk21-prebuilts" \
    "$workspace/out/lineage-desktop/jdk8-prebuilts"
}

ensure_arm64_rust_prebuilt() {
  host_is_arm64 || return 0

  local version dest probe rustc
  version="$(rust_prebuilt_version "$workspace")"
  [[ -n "$version" ]] || die "failed to detect Rust prebuilt version"
  dest="$workspace/prebuilts/rust/linux-arm64"
  probe="$version/bin/rustc"
  rustc="$dest/$probe"

  if [[ -L "$dest" ]]; then
    rm -f "$dest"
  fi

  if [[ -x "$rustc" ]]; then
    require_arm64_prebuilt_executable "$rustc" "ARM64 Rust rustc"
    require_arm64_rust_tools "$dest" "$version"
    require_arm64_rust_stdlibs "$dest" "$version"
    log "using ARM64 Rust prebuilt at ${dest#$workspace/}/$version"
    return 0
  fi

  if [[ -n "$arm64_rust_prebuilt_dir" ]]; then
    install_arm64_prebuilt_from_dir "$arm64_rust_prebuilt_dir" "$dest" "$probe" "Rust"
  elif [[ -n "$arm64_rust_prebuilt_archive" ]]; then
    install_arm64_prebuilt_from_archive "$arm64_rust_prebuilt_archive" "$dest" "$probe" "Rust"
  elif [[ -n "$arm64_rust_prebuilt_git_url" ]]; then
    install_arm64_prebuilt_from_git "$arm64_rust_prebuilt_git_url" \
      "$arm64_rust_prebuilt_git_ref" "$dest" "$probe" "Rust"
  else
    install_arm64_rust_from_upstream_dist "$version" "$dest"
  fi

  require_arm64_prebuilt_executable "$rustc" "ARM64 Rust rustc"
  require_arm64_rust_tools "$dest" "$version"
  require_arm64_rust_stdlibs "$dest" "$version"
  log "installed ARM64 Rust prebuilt at ${dest#$workspace/}/$version"
}

ensure_arm64_clang_tools_prebuilt() {
  host_is_arm64 || return 0

  local dest probe tool
  dest="$workspace/prebuilts/clang-tools/linux-arm64"
  probe="bin/header-abi-dumper"

  if [[ -L "$dest" ]]; then
    rm -f "$dest"
  fi

  if [[ -x "$dest/bin/header-abi-dumper" ]]; then
    for tool in bindgen cxx_extractor header-abi-diff header-abi-dumper header-abi-linker ide_query_cc_analyzer proto_metadata_plugin protoc_extractor; do
      [[ -e "$dest/bin/$tool" ]] || continue
      require_arm64_prebuilt_executable "$dest/bin/$tool" "ARM64 clang-tools $tool"
    done
    log "using ARM64 clang-tools prebuilt at ${dest#$workspace/}"
    return 0
  fi

  if [[ -n "$arm64_clang_tools_prebuilt_dir" ]]; then
    install_arm64_prebuilt_from_dir "$arm64_clang_tools_prebuilt_dir" "$dest" "$probe" "clang-tools"
  elif [[ -n "$arm64_clang_tools_prebuilt_archive" ]]; then
    install_arm64_prebuilt_from_archive "$arm64_clang_tools_prebuilt_archive" "$dest" "$probe" "clang-tools"
  else
    install_arm64_prebuilt_from_git "$arm64_clang_tools_prebuilt_git_url" \
      "$arm64_clang_tools_prebuilt_git_ref" "$dest" "$probe" "clang-tools"
  fi

  for tool in bindgen cxx_extractor header-abi-diff header-abi-dumper header-abi-linker ide_query_cc_analyzer proto_metadata_plugin protoc_extractor; do
    [[ -e "$dest/bin/$tool" ]] || continue
    require_arm64_prebuilt_executable "$dest/bin/$tool" "ARM64 clang-tools $tool"
  done
  require_arm64_prebuilt_executable "$dest/bin/header-abi-dumper" "ARM64 clang-tools header-abi-dumper"
  log "installed ARM64 clang-tools prebuilt at ${dest#$workspace/}"
}

detect_arm64_android_java_home() {
  if [[ -n "$arm64_android_java_home" ]]; then
    printf '%s\n' "$arm64_android_java_home"
    return 0
  fi

  if [[ -n "${OVERRIDE_ANDROID_JAVA_HOME:-}" ]]; then
    printf '%s\n' "$OVERRIDE_ANDROID_JAVA_HOME"
    return 0
  fi

  if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/javac" ]]; then
    printf '%s\n' "$JAVA_HOME"
    return 0
  fi

  local javac_path
  javac_path="$(command -v javac 2>/dev/null || true)"
  [[ -n "$javac_path" ]] || return 1
  javac_path="$(readlink -f "$javac_path")"
  printf '%s\n' "$(cd "$(dirname "$javac_path")/.." && pwd -P)"
}

arm64_android_java_home_for_build() {
  host_is_arm64 || return 1
  if [[ -x "$workspace/prebuilts/jdk/jdk21/linux-arm64/bin/javac" ]]; then
    return 1
  fi

  detect_arm64_android_java_home || \
    die "ARM64 host needs JDK 21 because this branch lacks an ARM64 JDK prebuilt; set ARM64_JDK21_PREBUILT_URL or ARM64_ANDROID_JAVA_HOME"
}
