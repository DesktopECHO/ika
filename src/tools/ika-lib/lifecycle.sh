# ika: starting and stopping the VM.
# Sourced by src/tools/ika, in its order; see there.

log_start_context() {
  local launcher_log="$1"
  shift
  local scrcpy_dpi
  local cpu_count
  local memory_mb
  local start_message
  scrcpy_dpi="${SCRCPY_DPI:-unknown}"
  cpu_count="$(start_arg_value "cpus" "${CVD_COMPUTE_DEFAULTS[cpus]}" "$@")"
  memory_mb="$(start_arg_value "memory_mb" "${CVD_COMPUTE_DEFAULTS[memory_mb]}" "$@")"

  start_message="Starting Cuttlefish: ${cpu_count} Cores, ${memory_mb} MB"
  if [[ -n "${CVD_GRAPHICS_DRIVER_MESSAGE}" ]]; then
    start_message+=", ${CVD_GRAPHICS_DRIVER_MESSAGE}"
  fi
  if [[ "${LOWCPU_MODE_ACTIVE}" == "true" ]]; then
    start_message+=", low-CPU mode (${IKA_LOWCPU_REFRESH_RATE_HZ} Hz)"
  fi
  start_message+=" ${scrcpy_dpi} DPI"
  log "${start_message}"
  printf '%s\n' "${start_message}" >&3
  if [[ -n "${CVD_DATA_STORAGE_MESSAGE}" ]]; then
    log "${CVD_DATA_STORAGE_MESSAGE}"
    printf '%s\n' "${CVD_DATA_STORAGE_MESSAGE}" >&3
  fi
  log "HOME=${CVD_HOME_DIR}"
  log "TMPDIR=${CVD_TMP_DIR}"
  log "ANDROID_HOST_OUT=${CVD_HOST_OUT}"
  log "ANDROID_PRODUCT_OUT=${CVD_PRODUCT_OUT}"
  log "gpu_mode=${CVD_GPU_MODE}"
  log "launcher_log=${launcher_log}"
  emit_launch_command "$@"
}

# After a VM stops, its cvdalloc may still be removing the VM's network
# interfaces (cvd-pi-*); a new cvdalloc fails to create them while they exist.
# Gives it time to finish. Interfaces of a VM that was killed, with no cvdalloc
# left to remove them, are removed by the next cvdalloc itself.
wait_for_cvdalloc_teardown() {
  local deadline

  pgrep -u "$(id -u)" -x cvdalloc >/dev/null 2>&1 || return 0
  log "waiting for the previous VM's network interfaces to be removed"
  deadline="$(make_deadline 15)"
  while pgrep -u "$(id -u)" -x cvdalloc >/dev/null 2>&1; do
    if ! within_deadline "${deadline}"; then
      log "warning: cvdalloc of the previous VM is still running; starting anyway"
      return 0
    fi
    sleep 0.5
  done
}

# cvd records each instance group's state in its own database. A VM that stops
# without 'cvd stop' (ika stops it with cvd_internal_stop, and it also exits by
# itself when Android powers off or fails to boot) stays recorded as Running,
# or as Unreachable once cvd fails to reach it, and cvd_internal_start, which
# runs 'cvd create --reuse', then refuses to start it again with "Group is
# already running". 'cvd stop' records it as stopped; disks are kept.
clear_stale_cvd_group() {
  local states

  has_live_cvd_processes && return 0
  states="$(run_with_cvd_env timeout 30 "${CVD_CLI_BIN}" ps 2>/dev/null \
    | awk 'NR > 1 { print $4 }' || true)"
  grep -qxE 'Running|Starting|Stopping|Preparing|Unreachable' <<<"${states}" || return 0
  log_file_only "clearing the state cvd kept for the stopped VM:$(tr '\n' ' ' <<<"${states}")"
  run_with_cvd_env timeout 60 "${CVD_CLI_BIN}" stop --wait_for_launcher=0 >/dev/null 2>&1 \
    || log "warning: cvd stop could not clear the state of the stopped VM"
}

# Ika runs its VM as Cuttlefish instance 1: its instance directory (cvd-1),
# adb address and frame socket all follow from that. cvd hands a new group the
# first instance whose lock file is not marked in use, and a lock file outlives
# a group that left cvd's database without 'cvd remove' or 'cvd clear', so
# instance 1 can stay taken by no one. The next group is then instance 2, ika
# waits for a guest at instance 1's address, the start fails and the console
# never opens; 'cvd create --reuse' keeps that group on instance 2 from then on.
# Clears a recorded group on another instance and releases instance 1's lock
# when no recorded group holds it. Only with no VM running.
claim_cvd_instance_one() {
  local ids other_ids lock="${CVD_INSTANCE_LOCK_DIR}/local-instance-1.lock"

  has_live_cvd_processes && return 0
  ids="$(run_with_cvd_env timeout 30 "${CVD_CLI_BIN}" ps 2>/dev/null \
    | awk 'NR > 1 && $3 ~ /^[0-9]+$/ { print $3 }' || true)"
  other_ids="$(grep -vx 1 <<<"${ids}" | grep -v '^$' || true)"
  if [[ -n "${other_ids}" ]]; then
    log "the VM was recorded as Cuttlefish instance $(tr '\n' ' ' <<<"${other_ids}" | sed 's/ $//') instead of 1; clearing that record so it starts as instance 1 (its old data stays in $(dirname "${CVD_INSTANCE_DIR}"))"
    run_with_cvd_env timeout 60 "${CVD_CLI_BIN}" clear >/dev/null 2>&1 \
      || log "warning: cvd clear could not remove the record of instance ${other_ids}"
    ids=""
  fi
  if ! grep -qx 1 <<<"${ids}" && [[ -f "${lock}" ]]; then
    log_file_only "releasing Cuttlefish instance 1, whose lock no recorded VM holds"
    rm -f "${lock}" 2>/dev/null \
      || log "warning: could not release ${lock}; the VM may start as another instance"
  fi
}

# Whether a cuttlefish_config.json holds a JSON object. An empty file, or one
# cut short, does not.
cvd_config_is_readable() {
  local path="$1"

  [[ -s "${path}" ]] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json, sys
with open(sys.argv[1]) as config:
    sys.exit(0 if isinstance(json.load(config), dict) else 1)' "${path}" \
      >/dev/null 2>&1
    return
  fi
  [[ "$(LC_ALL=C tr -d '[:space:]\000' < "${path}" | tail -c 1)" == "}" ]]
}

# A host that crashes or loses power while assemble_cvd writes the VM's
# configuration leaves an empty or truncated cuttlefish_config.json behind:
# the file's size reached the disk, its contents did not. Every start then
# fails in cvd_internal_start, which finds the file, cannot parse it and aborts
# ("Check failed: previous_config"), and 'cvd stop' cannot read it either.
# Removes such files so that assemble_cvd writes them again. The disks stay:
# assemble_cvd keeps overlay.img whenever the OS disk is unchanged, which
# protect_overlay_resume checks before every start.
remove_unreadable_cvd_config() {
  local path

  for path in "${CVD_ASSEMBLY_CONFIG_PATH}" "${CVD_CONFIG_PATH}"; do
    [[ -e "${path}" ]] || continue
    cvd_config_is_readable "${path}" && continue
    log "removing the unreadable VM configuration ${path}, left by an unclean shutdown; it is written again at start"
    rm -f "${path}"
  done
}

start_cvd() {
  local fullscreen_mode="${1:-false}"
  shift || true
  local -a args=()
  local launcher_log
  local adb_serial
  local launcher_pid
  local start_epoch
  local scrcpy_dpi
  local -a cvd_env_args=(env)
  local -a own_session=()
  local -a start_args=()

  take_gpu_mode_auto start_args "$@"
  set -- "${start_args[@]}"

  require_executable "${CVD_BIN}" "cvd launcher"
  check_required_groups
  ensure_open_file_limit
  launcher_log="${CVD_LAUNCHER_LOG}"
  adb_serial="$(resolve_adb_serial)"
  start_epoch="$(date +%s)"
  # Probed here, once, for the DPI heuristic and the display ceiling, which
  # read it in subshells that could not share it.
  host_display_size >/dev/null || true
  split_start_args args scrcpy_dpi "$@"
  SCRCPY_DPI="${scrcpy_dpi}"

  if has_live_cvd_processes; then
    log "Cuttlefish is already running under ${CVD_HOME_DIR}"
    if [[ "${START_CONSOLE}" == "true" ]]; then
      respond_console "Instance already running, local console will be restarted"
    fi
    respond "Android virtual device running"
    if [[ "${START_CONSOLE}" == "true" ]]; then
      maybe_start_scrcpy "${adb_serial}" "${fullscreen_mode}" || true
    else
      ensure_chromium "${adb_serial}"
    fi
    mount_android_storage "${adb_serial}"
    start_app_menu_watcher
    return 0
  fi

  notify_progress "Starting Android, one moment..."
  record_gpu_in_use
  # A mount left from a VM that stopped by itself points at a device that is
  # gone.
  unmount_android_storage
  wait_for_cvdalloc_teardown
  remove_unreadable_cvd_config
  clear_stale_cvd_group
  claim_cvd_instance_one
  record_udmabuf_baseline
  protect_overlay_resume
  trim_adb_server_log

  load_vulkaninfo_summary
  if ! user_supplied_flag "gpu_mode" "$@"; then
    CVD_GPU_DEFAULTS[gpu_mode]="$(default_gpu_mode_for_start)"
  fi
  resolve_lowcpu_mode "$@"

  apply_start_default_args args "$@"
  append_cuttlefish_audio_args args "$@"
  append_data_storage_args args "$@"
  append_serial_number_args args "$@"
  append_arm64_kernel_page_args args "$@"
  append_gfxstream_vulkan_args args "$@"
  drop_udmabuf_without_device args
  check_vm_device_access args
  append_hw_video_decode_args args "$@"
  append_default_display_arg args "${scrcpy_dpi}" "$@"
  prepare_user_adb_key || return 1
  append_bootconfig_args args
  append_cvd_env_args cvd_env_args

  log_start_context "${launcher_log}" "${args[@]}"

  # Windows runs ika from the Start menu through wslg.exe, which hangs up the
  # session it started ika in when ika returns, and the launcher stops the
  # device on a hangup. On WSLg the launcher gets a session of its own, as the
  # console has. setsid keeps the subshell's process, which leads no process
  # group.
  [[ "${IKA_ON_WSLG}" != true ]] || own_session=(setsid)
  (
    cd "${CVD_PRODUCT_OUT}"
    exec 3>&-
    # systemd-run --scope runs the command in this process: launcher_pid stays
    # the launcher's.
    exec "${own_session[@]+"${own_session[@]}"}" systemd-run --user --scope --quiet --collect -p Delegate=yes \
      --unit="ika-android-$(date +%s)" -- \
      "${IKA_SCRIPT_PATH}" __launch-in-vcpu-scope \
      "$(start_arg_value "cpus" "${CVD_COMPUTE_DEFAULTS[cpus]}" "$@")" \
      "${cvd_env_args[@]}" "${CVD_BIN}" "${args[@]}"
  ) &
  launcher_pid="$!"
  disown "${launcher_pid}" || true

  log "launcher pid: ${launcher_pid}"

  if ! wait_for_boot "${launcher_log}" "${start_epoch}" "${launcher_pid}"; then
    if [[ -f "${launcher_log}" ]]; then
      tail -n 80 "${launcher_log}" >&2 || true
    fi
    die "Cuttlefish did not reach boot completion"
  fi
  adb_serial="$(resolve_adb_serial)"

  log "Ika console ready"
  # Alongside the console, which they would otherwise hold up.
  {
    detach_background_job
    disable_guest_bluetooth "${adb_serial}" "$@"
    seed_guest_theme "${adb_serial}"
    apply_lowcpu_mode_guest_settings "${adb_serial}"
  } 3>&- &
  respond "Android virtual device running"
  if [[ "${START_CONSOLE}" == "true" ]]; then
    maybe_start_scrcpy "${adb_serial}" "${fullscreen_mode}" || true
  else
    ensure_chromium "${adb_serial}"
  fi
  # In the background, as it waits for Android to mount /sdcard.
  (
    detach_background_job
    mount_android_storage "${adb_serial}"
  ) &
  start_app_menu_watcher
  close_progress_notifications
}

stop_cvd_internal() {
  local clear_instance_dirs="${1:-false}"
  shift || true
  local stop_ok="false"
  local adb_serial
  local -a run_with_args=()
  local -a stop_args=()

  normalize_stop_grace_seconds
  # Before the stop, which can clear the config the serial comes from.
  adb_serial="$(resolve_adb_serial)"

  if [[ "${clear_instance_dirs}" == "true" ]]; then
    stop_args+=("--clear_instance_dirs")
  else
    sync_guest_disks "${adb_serial}"
  fi
  if ! user_supplied_flag "wait_for_launcher" "$@"; then
    stop_args+=("--wait_for_launcher=${IKA_STOP_GRACE_SEC}")
  fi
  stop_args+=("$@")

  require_executable "${CVD_STOP_BIN}" "cvd stop helper"

  if [[ -f "${CVD_CONFIG_PATH}" ]]; then
    run_with_args+=(--config "${CVD_CONFIG_PATH}")
  fi

  if run_stop_helper "${run_with_args[@]}" "${CVD_STOP_BIN}" "${stop_args[@]}"; then
    stop_ok="true"
  else
    log "primary stop helper returned non-zero"
  fi

  if [[ "${stop_ok}" != "true" ]]; then
    log "retrying stop via $(basename "${CVD_CLI_BIN}") stop"
    run_stop_helper "${CVD_CLI_BIN}" stop "${stop_args[@]}" && stop_ok="true" || true
  fi

  if [[ "${clear_instance_dirs}" == "true" ]]; then
    run_with_cvd_env "${CVD_CLI_BIN}" clear >/dev/null 2>&1 || true
    rm -f "${CHROMIUM_INSTALL_STAMP}"
  fi

  stop_dnsmasq
  cleanup_user_processes
  disconnect_guest_adb "${adb_serial}"
  report_udmabuf_leaks

  if has_live_cvd_processes; then
    die "Cuttlefish processes are still running after stop attempt"
  fi
  clear_stale_cvd_group

  if [[ "${stop_ok}" != "true" ]]; then
    log "stop helper reported no active device; no live Cuttlefish processes remain"
  fi

}

