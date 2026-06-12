#!/usr/bin/env bash
# Host-environment helpers for the LineageOS Desktop build engine: tool
# detection, privileged execution, downloader, SELinux labeling, and temporary
# zram swap sizing. Source only (defines functions). Relies on the engine's
# core primitives (log/die/enabled/need_cmd) and globals at call time.
#
# Distro packages are installed by ./ika-build
# (tools/buildutils/lib/dependencies.sh); helpers here only verify tools and
# fail with guidance.

run_privileged() {
  if (( EUID == 0 )); then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    return 1
  fi
}

nofile_limit_at_least() {
  local value="$1"
  local minimum="$2"

  [[ "$value" == "unlimited" ]] && return 0
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  [[ "$minimum" =~ ^[0-9]+$ ]] || return 1
  (( value >= minimum ))
}

ensure_downloader() {
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || \
    die "missing curl or wget; run ./ika-build to install all build dependencies, or install one manually"
}

download_file() {
  local url="$1"
  local dest="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -L --fail -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$dest" "$url"
  else
    die "missing curl or wget"
  fi
}

ensure_host_commands() {
  local -a required=(git git-lfs python3 tar awk find readlink rsync install mktemp file readelf adb zip 7z simg2img fsck.erofs debugfs lz4 pahole mogrify)
  local -a missing=()
  local cmd

  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  (( ${#missing[@]} == 0 )) || \
    die "missing required host tools: ${missing[*]} (run ./ika-build to install all build dependencies, or install them manually)"

  ensure_downloader
}

ensure_arm64_native_host() {
  host_is_arm64 || return 0

  local page_size
  page_size="$(host_page_size)"
  if [[ "$page_size" != "4096" ]]; then
    log "ARM64 host page size is $page_size; building natively with ARM64 prebuilts"
  else
    log "ARM64 host build will run natively with ARM64 prebuilts"
  fi
}

selinux_label_type() {
  local path="$1"
  [[ -e "$path" ]] || return 1

  ls -Zd "$path" 2>/dev/null | awk '{print $1}' | awk -F: '{print $3}'
}

regex_escape() {
  sed -e 's/[][\\.^$*+?{}|()]/\\&/g' <<<"$1"
}

ensure_selinux_fcontext() {
  local path="$1"
  local type="$2"
  local escaped regex

  if command -v semanage >/dev/null 2>&1; then
    escaped="$(regex_escape "$path")"
    regex="${escaped}(/.*)?"
    run_privileged semanage fcontext -a -t "$type" "$regex" >/dev/null 2>&1 || \
      run_privileged semanage fcontext -m -t "$type" "$regex" >/dev/null 2>&1 || \
      die "failed to configure SELinux fcontext for $path"
  fi
}

ensure_workspace_selinux_contexts() {
  command -v getenforce >/dev/null 2>&1 || return 0
  [[ "$(getenforce 2>/dev/null || true)" != "Disabled" ]] || return 0

  local workspace_type="${SELINUX_WORKSPACE_TYPE:-src_t}"
  [[ -n "$workspace_type" && "$workspace_type" != "none" ]] || return 0
  local -a relabel_paths=()
  local current_type

  current_type="$(selinux_label_type "$ika_root" || true)"
  if [[ "$current_type" != "$workspace_type" ]]; then
    relabel_paths+=("$ika_root")
  fi

  current_type="$(selinux_label_type "$workspace" || true)"
  if [[ -e "$workspace" && "$workspace" != "$ika_root" &&
      "$current_type" != "$workspace_type" ]]; then
    relabel_paths+=("$workspace")
  fi
  (( ${#relabel_paths[@]} > 0 )) || return 0

  log "repairing SELinux labels for workspace access ($workspace_type)"
  local path
  for path in "${relabel_paths[@]}"; do
    ensure_selinux_fcontext "$path" "$workspace_type"
  done
  if command -v semanage >/dev/null 2>&1; then
    command -v restorecon >/dev/null 2>&1 || \
      die "SELinux fcontext configured for ${relabel_paths[*]}, but restorecon is missing"
    run_privileged restorecon -R "${relabel_paths[@]}" || \
      die "failed to restore SELinux labels; run: sudo restorecon -R ${relabel_paths[*]}"
  else
    run_privileged chcon -R -t "$workspace_type" "${relabel_paths[@]}" || \
      die "failed to set SELinux labels; run: sudo chcon -R -t $workspace_type ${relabel_paths[*]}"
  fi
}

ensure_temp_zram_commands() {
  local -a required=(modprobe mkswap swapoff swapon zramctl)
  local -a missing=()
  local cmd

  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  (( ${#missing[@]} == 0 )) || \
    die "missing required zram tools: ${missing[*]} (run ./ika-build to install all build dependencies, or install kmod/util-linux manually)"
}

format_kib_as_gib() {
  local kib="$1"
  awk -v kib="$kib" 'BEGIN { printf "%.1f GiB", kib / 1024 / 1024 }'
}

swap_priority_for_device() {
  local dev="$1"
  awk -v dev="$dev" 'NR > 1 && $1 == dev { print $5; found=1; exit } END { if (!found) print "" }' \
    /proc/swaps 2>/dev/null || true
}

max_swap_priority() {
  awk '
    NR > 1 && $5 ~ /^-?[0-9]+$/ {
      if (!found || $5 > max) {
        max=$5
        found=1
      }
    }
    END {
      if (found) print max
      else print -2
    }
  ' /proc/swaps 2>/dev/null || printf '%s\n' -2
}

max_non_zram_swap_priority() {
  awk '
    NR > 1 && $1 !~ /^\/dev\/zram[0-9]+$/ && $5 ~ /^-?[0-9]+$/ {
      if (!found || $5 > max) {
        max=$5
        found=1
      }
    }
    END {
      if (found) print max
      else print -2
    }
  ' /proc/swaps 2>/dev/null || printf '%s\n' -2
}

next_swap_priority() {
  local max priority
  max="$(max_swap_priority)"
  [[ "$max" =~ ^-?[0-9]+$ ]] || max=-2
  priority=$((max + 1))
  (( priority < 100 )) && priority=100
  (( priority > 32767 )) && priority=32767
  printf '%s\n' "$priority"
}

zram_device_size_kib() {
  local dev="$1"
  local base="${dev##*/}"
  local disksize="/sys/block/$base/disksize"
  local bytes

  [[ -r "$disksize" ]] || return 1
  bytes="$(<"$disksize")"
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' $(((bytes + 1023) / 1024))
}

adequate_zram_swap_device() {
  local target_kib="$1"
  local non_zram_max dev priority size_kib

  non_zram_max="$(max_non_zram_swap_priority)"
  [[ "$non_zram_max" =~ ^-?[0-9]+$ ]] || non_zram_max=-2

  while read -r dev; do
    [[ -n "$dev" ]] || continue
    priority="$(swap_priority_for_device "$dev")"
    size_kib="$(zram_device_size_kib "$dev" || true)"
    [[ "$priority" =~ ^-?[0-9]+$ && "$size_kib" =~ ^[0-9]+$ ]] || continue
    if (( size_kib >= target_kib && priority > non_zram_max )); then
      printf '%s\n' "$dev"
      return 0
    fi
  done < <(awk 'NR > 1 && $1 ~ /^\/dev\/zram[0-9]+$/ { print $1 }' /proc/swaps 2>/dev/null || true)

  return 1
}

setup_temp_zram_if_needed() {
  local mem_kib cores target_combined_gib target_combined_kib zram_kib zram_size dev existing_zram zram_priority

  mem_kib="$(physical_memory_total_kib)"
  if [[ ! "$mem_kib" =~ ^[0-9]+$ || "$mem_kib" -le 0 ]]; then
    log "could not determine host RAM; skipping temporary zram setup"
    return 0
  fi

  # Target combined RAM (physical + zram) is (cores * 2) + 4 GiB, minimum 40 GiB;
  # zram makes up the shortfall to reach it.
  cores="$(logical_cpu_count)"
  target_combined_gib=$(( cores * 2 + 4 ))
  (( target_combined_gib >= 40 )) || target_combined_gib=40
  target_combined_kib=$(( target_combined_gib * 1024 * 1024 ))

  zram_kib=$(( target_combined_kib - mem_kib ))
  if (( zram_kib <= 0 )); then
    log "host RAM $(format_kib_as_gib "$mem_kib") already meets the ${target_combined_gib} GiB combined target; skipping temporary zram setup"
    return 0
  fi

  existing_zram="$(adequate_zram_swap_device "$zram_kib" || true)"
  if [[ -n "$existing_zram" ]]; then
    log "existing zram swap $existing_zram already provides the needed $(format_kib_as_gib "$zram_kib")"
    return 0
  fi

  ensure_temp_zram_commands

  # Load zram if it is not already available. zramctl will allocate a free
  # device below, so this does not touch any existing system zram swap.
  if [[ ! -e /sys/class/zram-control && ! -d /sys/block/zram0 ]]; then
    run_privileged modprobe zram || \
      die "failed to load zram kernel module"
  fi

  zram_size="${zram_kib}K"
  zram_priority="$(next_swap_priority)"

  # Prefer a higher-ratio compressor (zstd) so the same physical RAM holds a
  # larger working set before the build spills to slower backing swap; the
  # extra CPU cost lands on cores the memory-bound build leaves idle. Fall back
  # to the kernel default if the requested algorithm is unavailable.
  local zram_algorithm="${ZRAM_COMP_ALGORITHM:-zstd}"
  dev=""
  if [[ -n "$zram_algorithm" ]]; then
    dev="$(run_privileged zramctl --find --algorithm "$zram_algorithm" --size "$zram_size" 2>/dev/null || true)"
    [[ -n "$dev" ]] || log "zram algorithm '$zram_algorithm' unavailable; using kernel default"
  fi
  if [[ -z "$dev" ]]; then
    dev="$(run_privileged zramctl --find --size "$zram_size")" || \
      die "failed to create temporary zram device"
  fi
  temp_zram_device="$dev"

  run_privileged mkswap "$temp_zram_device" >/dev/null || \
    die "failed to initialize temporary zram swap at $temp_zram_device"
  run_privileged swapon --priority "$zram_priority" "$temp_zram_device" || \
    die "failed to enable temporary zram swap at $temp_zram_device"

  local actual_algorithm
  actual_algorithm="$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' \
    "/sys/block/${temp_zram_device##*/}/comp_algorithm" 2>/dev/null || true)"
  log "created temporary zram swap $temp_zram_device ($(format_kib_as_gib "$zram_kib") to reach a ${target_combined_gib} GiB physical+zram total, priority $zram_priority, algorithm ${actual_algorithm:-unknown})"
}

cleanup_temp_zram() {
  [[ -n "$temp_zram_device" ]] || return 0

  log "removing temporary zram swap $temp_zram_device"
  # Runs from the exit trap, so a failure must not abort shutdown — but the
  # user needs to know the device is still consuming RAM and how to free it.
  if ! run_privileged swapoff "$temp_zram_device" >/dev/null 2>&1 || \
     ! run_privileged zramctl --reset "$temp_zram_device" >/dev/null 2>&1; then
    log "warning: failed to remove temporary zram swap $temp_zram_device; remove it manually with: sudo swapoff $temp_zram_device; sudo zramctl --reset $temp_zram_device (or reboot)"
  fi
  temp_zram_device=""
}
