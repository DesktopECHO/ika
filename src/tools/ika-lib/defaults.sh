# ika: Cuttlefish's defaults, environment paths, settings read from ika.ini, Ika's files.
# Sourced by src/tools/ika, in its order; see there.

# ============================================================================
# Compute Configuration Defaults (passed to cvd_internal_start)
# ============================================================================
declare -A CVD_COMPUTE_DEFAULTS=(
  [cpus]="$(default_guest_cpus)"
  [memory_mb]="$(default_guest_memory_mb)"
  [enable_bootanimation]="false"
  [enable_sandbox]="false"
)

# ============================================================================
# GPU Configuration Defaults (passed to cvd_internal_start)
# ============================================================================
declare -A CVD_GPU_DEFAULTS=(
  [gpu_mode]="gfxstream_guest_angle"
  # Use Cuttlefish's upstream ARM64 auto-selection now that the packaged
  # CrosVM includes standalone vhost-user GPU control-socket support.
  [gpu_vhost_user_mode]="auto"
  [enable_gpu_udmabuf]="true"
  [use_cvdalloc]="true"
  # gfxstream's batched descriptor path masks inlineUniformBlock even though
  # Vulkan 1.3 makes that feature mandatory. Keep the fully compliant
  # non-batched path until gfxstream can batch inline-uniform descriptors.
  [gpu_renderer_features]="MinimalLogging:disabled;VulkanBatchedDescriptorSetUpdate:disabled"
)

# ============================================================================
# Network Configuration Defaults (passed to cvd_internal_start)
# ============================================================================
declare -A CVD_NETWORK_DEFAULTS=(
  [vhost_net]="true"
  [vhost_user_vsock]="false"
  # Native vsock carries adb; the half tunnel keeps TCP 6520 for fastboot.
  [adb_mode]="native_vsock,vsock_half_tunnel"
  [enable_wifi]="false"
  [enable_host_bluetooth]="false"
  [netsim_bt]="false"
  [enable_host_nfc]="false"
  [netsim_nfc]="false"
  [casimir_instance_num]="1"
  [enable_host_uwb]="false"
  [netsim_uwb]="false"
  [pica_instance_num]="1"
  [start_gnss_proxy]="false"
  [enable_modem_simulator]="false"
)

# ============================================================================
# Reporting Configuration Defaults (passed to cvd_internal_start)
# ============================================================================
declare -A CVD_REPORT_DEFAULTS=(
  [report_anonymous_usage_stats]="n"
)

# ============================================================================
# Logging Configuration Defaults (passed to cvd_internal_start)
# ============================================================================
declare -A CVD_LOGGING_DEFAULTS=(
  [file_verbosity]="WARNING"
  [verbosity]="WARNING"
)

# ============================================================================
# Boot & Logging Configuration Defaults (internal use only)
# ============================================================================
declare -A CVD_BOOT_DEFAULTS=(
  [boot_timeout_sec]="150"
)

# Android Settings reports internal storage capacity in decimal GB. Cuttlefish's
# blank_data_image_mb flag is MiB, so keep the default just under 64 GB decimal.
ika_ini_get DEFAULT_DATA_GB storage data_gb 64 uint
readonly DEFAULT_DATA_GB

# ============================================================================
# Launcher Lifecycle Defaults (passed to cvd_internal_start)
# ============================================================================
declare -A CVD_LAUNCHER_DEFAULTS=(
  [daemon]="true"
  [start_webrtc]="false"
)

# ============================================================================
# Overlay Configuration Defaults (internal use only)
# ============================================================================
declare -A CVD_OVERLAY_DEFAULTS=(
  [use_overlay]="true"
  [use_sdcard]="false"
)

CVD_DEFAULT_ARG_MAPS=(
  CVD_COMPUTE_DEFAULTS
  CVD_GPU_DEFAULTS
  CVD_NETWORK_DEFAULTS
  CVD_REPORT_DEFAULTS
  CVD_LOGGING_DEFAULTS
  CVD_OVERLAY_DEFAULTS
  CVD_LAUNCHER_DEFAULTS
)

# The mode gpu_mode = auto starts from, before ika.ini puts its own in.
CVD_GPU_MODE_AUTO_BASE="${CVD_GPU_DEFAULTS[gpu_mode]}"
# Whether this start was given --gpu_mode=auto.
GPU_MODE_AUTO_REQUESTED="false"

ika_ini_apply_map CVD_COMPUTE_DEFAULTS compute
ika_ini_apply_map CVD_GPU_DEFAULTS gpu
ika_ini_apply_map CVD_NETWORK_DEFAULTS network
ika_ini_apply_map CVD_REPORT_DEFAULTS reporting
ika_ini_apply_map CVD_LOGGING_DEFAULTS logging
ika_ini_apply_map CVD_OVERLAY_DEFAULTS storage
ika_ini_apply_map CVD_LAUNCHER_DEFAULTS launcher

# Convenience variables
CVD_GPU_MODE="${CVD_GPU_DEFAULTS[gpu_mode]}"
ika_ini_default CVD_BOOT_TIMEOUT_SEC boot boot_timeout_sec \
  "${CVD_BOOT_DEFAULTS[boot_timeout_sec]}" uint
# A slow host, or the first boot of a new ROM, can take longer than
# boot_timeout_sec. Past it, a start keeps waiting while the guest's logs still
# grow, until they stop for CVD_BOOT_STALL_SEC or CVD_BOOT_MAX_SEC have passed.
# The default limit matches run_cvd's own boot timeout of 600 seconds.
CVD_BOOT_MAX_SEC="$((CVD_BOOT_TIMEOUT_SEC * 4))"
readonly CVD_BOOT_MAX_SEC
readonly CVD_BOOT_STALL_SEC=90

# ============================================================================
# Environment Paths
# ============================================================================
: "${CVD_HOST_OUT:=${PACKAGED_CVD_HOST_OUT}}"
: "${CVD_PRODUCT_OUT:=${DEFAULT_CVD_PRODUCT_OUT}}"
: "${CVD_HOME_DIR:=${HOME}/ika}"
HOST_HOME="${HOME}"
USER_ADB_PRIVATE_KEY="${HOST_HOME}/.android/adbkey"
USER_ADB_PUBLIC_KEY="${USER_ADB_PRIVATE_KEY}.pub"
CVD_BUILD_VARIANT=""
if [[ -r "${CVD_PRODUCT_OUT}/ika-build-variant" ]]; then
  IFS= read -r CVD_BUILD_VARIANT < "${CVD_PRODUCT_OUT}/ika-build-variant" || true
fi
mkdir -p "${CVD_HOME_DIR}"
CVD_TMP_DIR="${CVD_HOME_DIR}/tmp"
mkdir -p "${CVD_TMP_DIR}"
export TMPDIR="${CVD_TMP_DIR}"
# adb servers started by Ika log here, in TMPDIR, unless ANDROID_ADB_LOG_PATH
# names another file.
ADB_SERVER_LOG="${ANDROID_ADB_LOG_PATH:-${CVD_TMP_DIR}/adb.${UID}.log}"

# The pid or lock file (EXT is pid or lock) of an app window's supervisor. The
# app-supervisor- prefix keeps app-menu-watcher's files out of its glob.
app_supervisor_file() {
  printf '%s\n' "${CVD_TMP_DIR}/app-supervisor-$1.$2"
}
# The record of a game in the background, "BOOT_ID CUTTLEFISH_DISPLAY
# ANDROID_DISPLAY", and the mark that tells its window's supervisor to leave
# the display when the window closes (see background_app_window).
app_background_file() {
  printf '%s\n' "${CVD_TMP_DIR}/app-background-$1"
}
app_keep_display_file() {
  printf '%s\n' "${CVD_TMP_DIR}/app-keep-display-$1"
}
DATA_GB_CONFIG_FILE="${CVD_HOME_DIR}/data-gb"
SERIAL_NUMBER_FILE="${CVD_HOME_DIR}/serial-number"
START_LOG_FILE="${CVD_HOME_DIR}/ikastart.log"
SCRCPY_LOG_FILE="${CVD_HOME_DIR}/console.log"
# The desktop console's window state; SCRCPY_WINDOW_STATE_FILE is the state
# file of the console a supervisor runs, which app windows and the TV console
# point at files of their own.
DESKTOP_CONSOLE_WINDOW_STATE_FILE="${CVD_HOME_DIR}/console-window-state"
SCRCPY_WINDOW_STATE_FILE="${DESKTOP_CONSOLE_WINDOW_STATE_FILE}"
SCRCPY_SUPERVISOR_PID_FILE="${CVD_TMP_DIR}/console-supervisor.pid"
SCRCPY_SUPERVISOR_LOCK_FILE="${CVD_TMP_DIR}/console-supervisor.lock"
IKA_APPS_DIR="${CVD_HOME_DIR}/apps"
APP_MENU_WATCHER_PID_FILE="${CVD_TMP_DIR}/app-menu-watcher.pid"
APP_MENU_WATCHER_LOCK_FILE="${CVD_TMP_DIR}/app-menu-watcher.lock"
APP_MENU_SYNC_LOCK_FILE="${CVD_TMP_DIR}/app-menu-sync.lock"
APP_MENU_LOG_FILE="${CVD_HOME_DIR}/app-menu.log"
APP_MENU_DISABLED_FILE="${CVD_HOME_DIR}/app-menu-disabled"
# Android's shared storage (/sdcard), mounted with madbfs while the VM runs. It
# goes in the session's runtime directory, outside the home folder, so that
# backups and other programs walking the home folder do not go through adb into
# the VM; and a crash leaves no mount behind there. Ika mounted it in its home
# folder before, where it still does without a runtime directory.
LEGACY_ANDROID_STORAGE_DIR="${CVD_HOME_DIR}/Android"
if [[ -d "${XDG_RUNTIME_DIR:-/run/user/${UID}}" && -w "${XDG_RUNTIME_DIR:-/run/user/${UID}}" ]]; then
  ANDROID_STORAGE_DIR="${XDG_RUNTIME_DIR:-/run/user/${UID}}/ika/Android"
else
  ANDROID_STORAGE_DIR="${LEGACY_ANDROID_STORAGE_DIR}"
fi
MADBFS_LOG_FILE="${CVD_HOME_DIR}/madbfs.log"
# The storage watcher, which unmounts it once the VM has stopped by itself
STORAGE_WATCHER_PID_FILE="${CVD_TMP_DIR}/storage-watcher.pid"
STORAGE_WATCHER_LOCK_FILE="${CVD_TMP_DIR}/storage-watcher.lock"
STORAGE_WATCHER_POLL_SEC=2
APP_LIST_CACHE="${IKA_APPS_DIR}/app-list"
# Start options saved for each app: see saved_app_options.
APP_OPTIONS_FILE="${CVD_HOME_DIR}/app-options.ini"
# The console of Android's TV mode keeps its own window state, so that it does
# not replace the desktop console's size and fullscreen state.
TV_CONSOLE_WINDOW_STATE_FILE="${CVD_HOME_DIR}/tv-console-window-state"
APP_GAMES_FILE="${IKA_APPS_DIR}/games"
ika_ini_default IKA_APP_MENU_POLL_SEC apps menu_poll_sec 5 uint
ika_ini_default IKA_BACKGROUND_GAMES apps background_games true
CVD_BIN="${CVD_HOST_OUT}/bin/cvd_internal_start"
CVD_CLI_BIN="${CVD_HOST_OUT}/bin/cvd"
CVD_STOP_BIN="${CVD_HOST_OUT}/bin/cvd_internal_stop"
CVD_ADB_BIN="${CVD_HOST_OUT}/bin/adb"
CVD_ASSEMBLY_DIR="${CVD_HOME_DIR}/cuttlefish/assembly"
CVD_ASSEMBLY_CONFIG_PATH="${CVD_ASSEMBLY_DIR}/cuttlefish_config.json"
CVD_INSTANCE_DIR="${CVD_HOME_DIR}/cuttlefish/instances/cvd-1"
CVD_INSTANCE_LOCK_DIR="${CVD_INSTANCE_LOCK_DIR:-/var/tmp/cvd/lock}"
CVD_LAUNCHER_LOG="${CVD_INSTANCE_DIR}/logs/launcher.log"
CVD_CONFIG_PATH="${CVD_INSTANCE_DIR}/cuttlefish_config.json"
CHROMIUM_INSTALL_STAMP="${CVD_HOME_DIR}/chromium-installed-cvd-1"
CHROMIUM_APK="${IKA_APPS_DIR}/Chromium.apk"
UDMABUF_BASELINE_FILE="${CVD_HOME_DIR}/udmabuf-baseline"
# The host display's size as last found, for a start that finds none.
HOST_DISPLAY_SIZE_FILE="${CVD_HOME_DIR}/host-display-size"
SCRCPY_BIN="${PACKAGED_SCRCPY_BIN}"
SCRCPY_SERVER_PATH_OVERRIDE=""
if [[ -f "${PACKAGED_SCRCPY_SERVER}" ]]; then
  SCRCPY_SERVER_PATH_OVERRIDE="${PACKAGED_SCRCPY_SERVER}"
fi
SCRCPY_DPI=""
# Set to true when --dpi gives the density.
SCRCPY_DPI_GIVEN="false"
ika_ini_default GFXSTREAM_VULKAN gpu gfxstream_vulkan auto
ika_ini_default IKA_HOST_CACHED_MEMORY gpu host_cached_memory off
ika_ini_default IKA_HW_VIDEO_DECODE gpu hw_video_decode auto
ika_ini_default IKA_GPU gpu use_gpu auto
ika_ini_default IKA_LOWCPU lowcpu mode auto
ika_ini_get IKA_LOWCPU_REFRESH_RATE_HZ lowcpu refresh_rate_hz 30 uint
# Whether the VM runs low-CPU mode, decided at start (resolve_lowcpu_mode).
LOWCPU_MODE_ACTIVE="false"
LOWCPU_MODE_REASON=""
ika_ini_default IKA_CAMERA camera device off
ika_ini_default IKA_CAMERA_POWER_LINE_FREQUENCY camera power_line_frequency auto
GFXSTREAM_VULKAN_MODE="${GFXSTREAM_VULKAN}"
GFXSTREAM_GLES_CONTEXT_TYPES="gfxstream-gles:gfxstream-composer"
GFXSTREAM_VULKAN_CONTEXT_TYPES="gfxstream-gles:gfxstream-vulkan:gfxstream-composer"
GFXSTREAM_RADV_VULKAN_RENDERER_FEATURES="VulkanAllocateDeviceMemoryOnly:enabled"
RADV_VEGA_OR_OLDER_FAMILY_REGEX='(TAHITI|PITCAIRN|VERDE|OLAND|HAINAN|BONAIRE|KABINI|KAVERI|HAWAII|MULLINS|TONGA|ICELAND|CARRIZO|FIJI|STONEY|POLARIS10|POLARIS11|POLARIS12|VEGAM|VEGA10|RAVEN|VEGA12|VEGA20|RAVEN2|RENOIR)'
# Apple Silicon (Honeykrisp) exposes the dma-buf external-memory path
# (VK_EXT_external_memory_dma_buf) but NOT VK_EXT_external_memory_host, so the
# gfxstream SystemBlob host-pointer path cannot be backed by the Apple GPU and
# must stay disabled. Route host-visible guest Vulkan memory through
# udmabuf-backed dma-bufs instead; the packaged gfxstream build links the real
# Linux UdmabufCreator so this can initialize on hosts with /dev/udmabuf.
GFXSTREAM_APPLE_16K_VULKAN_RENDERER_FEATURES="ExternalBlob:enabled;SystemBlob:disabled;VulkanAllocateHostVisibleAsUdmabuf:enabled;VulkanUseDedicatedAhbMemoryType:enabled"
# gfxstream's ScanoutDmabufExport feature (the console scanned out as a dma-buf
# instead of read back) is on by default on this path too: the hwc framebuffers
# are re-created with an explicit DRM modifier (Apple twiddled) that the host
# display imports. It is not listed here, and a
# --gpu_renderer_features=ScanoutDmabufExport:... override is kept as given.
CVD_GRAPHICS_DRIVER_MESSAGE=""
CVD_DATA_STORAGE_MESSAGE=""
# Set to false by --no-console: start the VM without the desktop console.
START_CONSOLE="true"
# Set by 'start', which keeps a running VM: --camera then can't take effect.
START_KEEPS_RUNNING_VM="false"
ika_ini_default IKA_STOP_GRACE_SEC system stop_grace_sec 30 uint
ika_ini_default IKA_SCRCPY_REBOOT_TIMEOUT_SEC console reboot_timeout_sec 120 uint
ika_ini_default IKA_MIN_OPEN_FILES system min_open_files 65536 uint
ika_ini_default IKA_KERNEL_PAGE_SIZE system kernel_page_size auto
ika_ini_default IKADPI console dpi auto
ika_ini_default IKA_REFRESH_RATE_HZ console refresh_rate_hz auto
ika_ini_default IKA_TV_DPI console tv_dpi auto
ika_ini_default IKA_TV_KEYBOARD_GAMEPAD console tv_keyboard_gamepad false
# The keys of the keyboard gamepad, in the order of keyboard_gamepad_spec.
KEYBOARD_GAMEPAD_CONTROLS=(left_stick_up left_stick_down left_stick_left
  left_stick_right dpad_up dpad_down dpad_left dpad_right right_stick_up
  right_stick_down right_stick_left right_stick_right a b x y start back guide
  left_shoulder right_shoulder left_stick right_stick left_trigger
  right_trigger walk)
declare -A KEYBOARD_GAMEPAD_KEYS=(
  [left_stick_up]="W" [left_stick_down]="S" [left_stick_left]="A"
  [left_stick_right]="D" [dpad_up]="Up" [dpad_down]="Down"
  [dpad_left]="Left" [dpad_right]="Right" [right_stick_up]="I"
  [right_stick_down]="K" [right_stick_left]="J" [right_stick_right]="L"
  [a]="Space" [b]="Escape" [x]="C" [y]="V" [start]="Return Keypad_Enter"
  [back]="Backspace" [guide]="" [left_shoulder]="Q Wheel_Up"
  [right_shoulder]="E Wheel_Down" [left_stick]="Left_Shift"
  [right_stick]="F Mouse_Middle" [left_trigger]="Z Mouse_Right"
  [right_trigger]="X Mouse_Left" [walk]="Tab"
)
# The built-in keys and settings stay in KEYBOARD_GAMEPAD_DEFAULT_KEYS and
# KEYBOARD_GAMEPAD_DEFAULT_SETTING_VALUES, for "Reset to default"
declare -A KEYBOARD_GAMEPAD_DEFAULT_KEYS=()
declare -A KEYBOARD_GAMEPAD_DEFAULT_SETTING_VALUES=()
for keyboard_gamepad_control in "${KEYBOARD_GAMEPAD_CONTROLS[@]}"; do
  KEYBOARD_GAMEPAD_DEFAULT_KEYS[${keyboard_gamepad_control}]="${KEYBOARD_GAMEPAD_KEYS[${keyboard_gamepad_control}]}"
  ika_ini_get "KEYBOARD_GAMEPAD_KEYS[${keyboard_gamepad_control}]" \
    keyboard_gamepad "${keyboard_gamepad_control}" \
    "${KEYBOARD_GAMEPAD_KEYS[${keyboard_gamepad_control}]}"
done
unset keyboard_gamepad_control
# The keyboard gamepad's settings, see [keyboard_gamepad]; checked as the
# spec is built (normalize_keyboard_gamepad_setting).
KEYBOARD_GAMEPAD_SETTINGS=(stick_ramp_ms walk_percent socd socd_dpad
  socd_left_stick socd_right_stick mouse_stick mouse_sensitivity)
declare -A KEYBOARD_GAMEPAD_SETTING_VALUES=(
  [stick_ramp_ms]="100" [walk_percent]="50" [socd]="last" [socd_dpad]=""
  [socd_left_stick]="" [socd_right_stick]="" [mouse_stick]="off"
  [mouse_sensitivity]="100"
)
for keyboard_gamepad_setting in "${KEYBOARD_GAMEPAD_SETTINGS[@]}"; do
  KEYBOARD_GAMEPAD_DEFAULT_SETTING_VALUES[${keyboard_gamepad_setting}]="${KEYBOARD_GAMEPAD_SETTING_VALUES[${keyboard_gamepad_setting}]}"
  ika_ini_get "KEYBOARD_GAMEPAD_SETTING_VALUES[${keyboard_gamepad_setting}]" \
    keyboard_gamepad "${keyboard_gamepad_setting}" \
    "${KEYBOARD_GAMEPAD_SETTING_VALUES[${keyboard_gamepad_setting}]}"
done
unset keyboard_gamepad_setting
ika_ini_default IKA_SCRCPY console scrcpy_args ""
ika_ini_default IKA_INSTALL_TIMEOUT_SEC timeouts install_timeout_sec 1800 uint
# Settings of the former H.264 app windows, still in older ika.ini files
IKA_INI_USED[apps.bit_rate]=1
IKA_INI_USED[apps.codec_options]=1
# The former gamepad setting: each app's start options pass the gamepad now
IKA_INI_USED[console.gamepad]=1

readonly SCRCPY_EXIT_DISCONNECTED=2

CVD_PROCESS_REGEX='(^|/)(cvd_internal_start|launch_cvd|run_cvd|crosvm|process_restarter|ika_stream|socket_vsock_proxy|wmediumd)([[:space:]]|$)'

