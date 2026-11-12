# ika: paths, WSLg app IDs, and ika.ini: its parser, its template and loading it.
# Sourced by src/tools/ika, in its order; see there.

SCRIPT_NAME="$(basename "$0")"
PACKAGED_CVD_HOST_OUT="/usr/lib/cuttlefish-common"
DEFAULT_CVD_PRODUCT_OUT="/usr/share/cuttlefish-common/lineageos"
PACKAGED_SCRCPY_BIN="/usr/lib/cuttlefish-common/bin/scrcpy"
PACKAGED_SCRCPY_SERVER="/usr/lib/cuttlefish-common/share/scrcpy/scrcpy-server"
PACKAGED_GETCHROMIUM_BIN="/usr/lib/cuttlefish-common/bin/getchromium"
PACKAGED_IKA_ROOT_BIN="/usr/lib/cuttlefish-common/bin/ika-root"
PACKAGED_MADBFS_BIN="/usr/lib/cuttlefish-common/bin/madbfs"
PACKAGED_WSL_GPU_DIR="/usr/lib/cuttlefish-common/wsl"
# Whether windows show through WSLg, WSL's display server for the Windows
# desktop, whose task bar matches windows to desktop entries in its own way.
IKA_ON_WSLG=false
[[ ! -d /mnt/wslg ]] || IKA_ON_WSLG=true

# Windows makes a WSLg window's task bar identity from its app ID alone, so
# the windows of an app ID in different WSL distributions share one task bar
# button, with the name, icon and command of whichever Windows met first. On
# WSLg, Ika's app IDs carry the distribution's name, as this prints it: in
# lower case, with dashes for anything else than letters and digits (WSLg
# keeps a desktop entry under the last dot-separated part of its name only).
# Prints nothing outside WSLg.
wslg_distro_id() {
  local name="${WSL_DISTRO_NAME:-}"

  [[ "${IKA_ON_WSLG}" == true ]] || return 0
  name="${name,,}"
  printf '%s\n' "${name//[^a-z0-9]/-}"
}

# WSLg reads the desktop entries of the system's applications directories
# only; ika-wsl-setup links this one of them to the user's.
WSLG_LINKED_APPLICATIONS_DIR="/usr/local/share/applications"
IKA_DESKTOP_ENTRY="/usr/share/applications/ika.desktop"

wslg_reads_user_applications() {
  [[ "$(readlink -f "${WSLG_LINKED_APPLICATIONS_DIR}")" \
    == "$(readlink -f "${XDG_DATA_HOME:-${HOME}/.local/share}/applications")" ]]
}

# The app ID of Ika's own windows, the console's and Startup Options': on
# WSLg ika-DISTRIBUTION, once write_wslg_console_entry has written its desktop
# entry where WSLg reads it; otherwise ika.desktop's, ika.
console_app_id() {
  local distro

  distro="$(wslg_distro_id)"
  if [[ -n "${distro}" \
      && -f "${XDG_DATA_HOME:-${HOME}/.local/share}/applications/ika-${distro}.desktop" ]] \
      && wslg_reads_user_applications; then
    printf 'ika-%s\n' "${distro}"
  else
    printf 'ika\n'
  fi
}
SCRCPY_ICON_DIR_DEFAULT="/usr/lib/cuttlefish-common/share/icons/hicolor/256x256/apps"
IKA_SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

# Runs COMMAND with a time limit of SECONDS, as coreutils' timeout does. The
# uutils timeout Ubuntu ships since 25.10 polls for the command's end every
# 0.1 s, a tenth of a second on each of the adb and crosvm calls behind an app
# window; perl, which perl-base makes always available, stands in for it then.
if [[ "$(timeout --version 2>/dev/null)" == *"GNU coreutils"* ]] \
    || ! command -v perl >/dev/null 2>&1; then
  with_timeout() {
    timeout "$@"
  }
else
  with_timeout() {
    perl -e '
      my $limit = shift @ARGV;
      my $pid = fork;
      defined $pid or exit 125;
      if (!$pid) { exec {$ARGV[0]} @ARGV or exit 127 }
      $SIG{ALRM} = sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 };
      alarm $limit;
      waitpid $pid, 0;
      exit(($? & 127) ? 128 + ($? & 127) : $? >> 8);
    ' "$@"
  }
fi

# ============================================================================
# Settings file (~/ika/ika.ini)
# ============================================================================
# The defaults below can be changed in ~/ika/ika.ini, which ika_ini_write_default
# generates when it is missing. Precedence: command line, then environment
# variable, then ika.ini, then the default in this script. Runs before log()
# exists, so it writes to stderr itself.
IKA_INI_FILE="${CVD_HOME_DIR:-${HOME}/ika}/ika.ini"
declare -A IKA_INI=()
declare -A IKA_INI_USED=()

ika_ini_warn() {
  printf '[%s] %s\n' "${SCRIPT_NAME}" "$*" >&2
}

# Reads "[section]" headers and "key = value" lines into IKA_INI as
# "section.key". Lines starting with # or ; are comments; values are literal.
ika_ini_load() {
  local file="$1"
  local line section="" key value
  local line_number=0

  [[ -r "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_number=$((line_number + 1))
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "${line}" in
      ""|"#"*|";"*)
        ;;
      "["*"]")
        section="${line:1:${#line}-2}"
        section="${section#"${section%%[![:space:]]*}"}"
        section="${section%"${section##*[![:space:]]}"}"
        section="${section,,}"
        ;;
      *=*)
        if [[ -z "${section}" ]]; then
          ika_ini_warn "${file}:${line_number}: setting outside a [section]; ignored"
          continue
        fi
        key="${line%%=*}"
        value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        IKA_INI["${section}.${key,,}"]="${value}"
        ;;
      *)
        ika_ini_warn "${file}:${line_number}: not a setting; ignored"
        ;;
    esac
  done <"${file}"
}

# ika_ini_get VAR SECTION KEY DEFAULT [uint]: sets VAR to the ika.ini value, or
# to DEFAULT when the file has none. With "uint" a value that is not a positive
# whole number is reported and replaced by DEFAULT. Not a command substitution,
# so that IKA_INI_USED records the key.
ika_ini_get() {
  local -n _ika_out="$1"
  local _ika_key="$2.$3"
  local _ika_val="$4"

  IKA_INI_USED["${_ika_key}"]=1
  if [[ -n "${IKA_INI[${_ika_key}]+set}" ]]; then
    _ika_val="${IKA_INI[${_ika_key}]}"
    if [[ "${5:-}" == "uint" && ! "${_ika_val}" =~ ^[1-9][0-9]*$ ]]; then
      ika_ini_warn "${IKA_INI_FILE}: ${2}.${3} must be a positive whole number, not '${_ika_val}'; using $4"
      _ika_val="$4"
    fi
  fi
  _ika_out="${_ika_val}"
}

# ika_ini_default VAR SECTION KEY DEFAULT [uint]: like ika_ini_get, but an
# environment variable VAR that is already set wins.
ika_ini_default() {
  local ini_value

  IKA_INI_USED["$2.$3"]=1
  [[ -z "${!1:-}" ]] || return 0
  ika_ini_get ini_value "$2" "$3" "$4" "${5:-}"
  printf -v "$1" '%s' "${ini_value}"
}

# ika_ini_set SECTION KEY VALUE: writes "KEY = VALUE" in [SECTION] of ika.ini,
# in place of the key's lines there (the last of which ika_ini_load would
# take), else after the section's last setting, before the comments and blank
# lines that end it, else in a new section at the end. Comments and every
# other line stay as they are, and IKA_INI follows. Fails, leaving the file
# as it was, when it cannot be written.
ika_ini_set() {
  local section="${1,,}"
  local key="${2,,}"
  local value="$3"
  local file="${IKA_INI_FILE}"

  if [[ ! -e "${file}" ]]; then
    mkdir -p "${file%/*}" && ika_ini_write_default >"${file}" || return 1
  fi
  awk -v section="${section}" -v key="${key}" -v value="${value}" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function setting() { print key (value == "" ? " =" : " = " value); written = 1 }
    {
      line = trim($0)
    }
    line ~ /^\[.*\]$/ {
      if (in_section && !written) setting()
      printf "%s", pending
      pending = ""
      in_section = (tolower(trim(substr(line, 2, length(line) - 2))) == section)
      if (in_section) seen = 1
      print
      next
    }
    in_section && line != "" && line !~ /^[#;]/ && index(line, "=") {
      printf "%s", pending
      pending = ""
      if (tolower(trim(substr(line, 1, index(line, "=") - 1))) == key) {
        if (!written) setting()
        next
      }
      print
      next
    }
    in_section {
      pending = pending $0 "\n"
      next
    }
    { print }
    END {
      if (in_section && !written) setting()
      printf "%s", pending
      if (!seen) { printf "\n[%s]\n", section; print key (value == "" ? " =" : " = " value) }
    }' "${file}" >"${file}.$$" || { rm -f "${file}.$$"; return 1; }
  chmod --reference="${file}" "${file}.$$" 2>/dev/null || true
  mv -f "${file}.$$" "${file}" || { rm -f "${file}.$$"; return 1; }
  IKA_INI["${section}.${key}"]="${value}"
}

# ika_ini_list ARRAY SECTION KEY: replaces ARRAY with the words of the ika.ini
# value, when the file has the key.
ika_ini_list() {
  local -n _ika_list="$1"
  local ini_key="$2.$3"
  local words

  IKA_INI_USED["${ini_key}"]=1
  [[ -n "${IKA_INI[${ini_key}]+set}" ]] || return 0
  words="${IKA_INI[${ini_key}]//,/ }"
  _ika_list=()
  read -r -a _ika_list <<<"${words}"
}

# ika_ini_apply_map MAP SECTION: overrides each entry of an associative array of
# cvd_internal_start defaults with the same key in ika.ini.
ika_ini_apply_map() {
  local -n _ika_map="$1"
  local section="$2"
  local key value

  for key in "${!_ika_map[@]}"; do
    ika_ini_get value "${section}" "${key}" "${_ika_map[${key}]}"
    case "${section}.${key}" in
      gpu.gpu_mode)
        # "auto" keeps the built-in mode, which start replaces on a host
        # whose GPU gfxstream cannot use.
        [[ "${value,,}" != "auto" ]] || continue
        ;;
      compute.cpus|compute.memory_mb)
        # "auto" keeps the value calculated from the host.
        if [[ "${value}" == "auto" ]]; then
          continue
        elif [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
          ika_ini_warn "${IKA_INI_FILE}: ${section}.${key} must be auto or a positive whole number, not '${value}'; using auto"
          continue
        fi
        ;;
    esac
    _ika_map["${key}"]="${value}"
  done
}

ika_ini_warn_unknown() {
  local ini_key

  for ini_key in "${!IKA_INI[@]}"; do
    [[ -n "${IKA_INI_USED[${ini_key}]+set}" ]] \
      || ika_ini_warn "${IKA_INI_FILE}: unknown setting '${ini_key}'; ignored"
  done
}

# Keep the values here equal to the defaults in this script; the test
# tools/tests/test_ika_settings.sh checks that they are.
ika_ini_write_default() {
  cat <<'EOF'
# Ika settings. Ika writes this file the first time it runs; edit it to change
# Ika's defaults. Delete it to get a fresh copy, or delete a line to use the
# built-in default for that setting.
#
# A line starting with # or ; is a comment. Values are written as they are,
# without quotes, and a # after a value is part of the value. Command-line
# options override this file, and an environment variable named in a
# comment below overrides its setting. Changes apply the next time Ika starts
# the VM (or the console, for [console] and [apps]).


# ----------------------------------------------------------------------------
[compute]
# Virtual CPUs and guest memory. "auto" sizes them from the host: half the
# performance cores, counting each hardware thread (at most cpu_cap; under WSL,
# all the CPUs WSL has), and a quarter of the host's memory rounded up to a
# multiple of memory_step_mb (at most memory_cap_mb; under WSL, all the memory
# WSL has less 1.5 GB for Linux). Each vCPU is pinned to a host CPU: the
# performance cores first (an Intel hybrid CPU's P-cores), one hardware thread
# of each core before any core's second, from the highest CPU number down.
# Command-line equivalents: --cpus=, --memory_mb=
cpus = auto
memory_mb = auto
cpu_cap = 12
memory_step_mb = 2048
memory_cap_mb = 32768
# Used when the host's memory cannot be read.
memory_fallback_mb = 4096
enable_bootanimation = false
enable_sandbox = false


# ----------------------------------------------------------------------------
[gpu]
# auto, gfxstream_guest_angle, gfxstream, guest_swiftshader, venus, ...
# auto is venus on a host whose first Vulkan device is a GPU with Vulkan 1.3
# or newer and ETC2 textures (RADV's emulated ones count, as under Venus);
# gfxstream on a host with only software Vulkan devices, or whose GPU
# gfxstream passes over for llvmpipe (an older Vulkan version, such as
# Haswell's 1.2), with OpenGL ES only when gfxstream_vulkan is auto, whatever
# is set here; gfxstream_guest_angle otherwise. Command-line
# equivalent: --gpu_mode=, which wins on every host; --gpu_mode=auto gives
# auto's choice for that start, whatever is set here. venus (Mesa's Venus
# Vulkan driver in the guest over virglrenderer) and guest_lavapipe (Mesa's
# lavapipe on the guest's CPU) need a ROM that ships those drivers; see
# GRAPHICS.md.
gpu_mode = auto
# The GPU Ika uses, and no other: auto, or a GPU's Vulkan vendor and device
# ID in hex, as vulkaninfo --summary lists them (10de:27a0); "GPU Hardware" in
# Ika's Startup Options sets it. crosvm, gfxstream, Venus, the console and
# hardware video decoding all run on it. auto takes a discrete GPU beside an
# integrated one, else the only GPU; so does a GPU the host does not have.
# Under WSL2 it is the Windows adapter Mesa's Dozen lists. Environment
# variable: IKA_GPU. A MESA_VK_DEVICE_SELECT or DRI_PRIME of the environment
# wins.
use_gpu = auto
gpu_vhost_user_mode = auto
enable_gpu_udmabuf = true
use_cvdalloc = true
# Features of gfxstream's renderer, separated by semicolons.
gpu_renderer_features = MinimalLogging:disabled;VulkanBatchedDescriptorSetUpdate:disabled
# auto, on or off. With gfxstream_guest_angle this is ignored.
# Command-line equivalent: --gfxstream_vulkan=. Environment variable:
# GFXSTREAM_VULKAN
gfxstream_vulkan = auto
# on takes the guest's host-visible Vulkan memory from a cached coherent host
# memory type instead of a write-combined one (gfxstream's
# VulkanPreferHostCachedMemory), which is faster for the guest's uploads on
# some drivers; off, the default, leaves the driver's choice. NVIDIA's
# proprietary driver always gets cached memory, which it needs to draw
# correctly. Command-line equivalent: --host_cached_memory=. Environment
# variable: IKA_HOST_CACHED_MEMORY
host_cached_memory = off
# auto or off. auto gives Android a video decoder backed by the host's VA-API
# (H.264, HEVC, VP8 and VP9, as far as the host decodes them) when vainfo
# finds a working VA-API driver. Command-line equivalent: --hw_video_decode=.
# Environment variable: IKA_HW_VIDEO_DECODE
hw_video_decode = auto


# ----------------------------------------------------------------------------
[lowcpu]
# Low-CPU mode for weak hosts: the display refreshes at refresh_rate_hz
# instead of the host display's rate, window blurs are off and animations run
# at half their length; the display's size and density stay as they are. auto,
# on or off.
# auto turns it on when vulkaninfo finds no hardware Vulkan device on the
# host, when the GPU mode is guest_swiftshader or guest_lavapipe, when the
# guest gets 2 vCPUs or fewer (4 or fewer under WSL), or when the host has
# less than 8 GB of memory. Command-line equivalents: --lowcpu, --no-lowcpu.
# Environment variable: IKA_LOWCPU
mode = auto
# Display refresh rate in low-CPU mode, in Hz. A --display= option wins.
refresh_rate_hz = 30


# ----------------------------------------------------------------------------
[camera]
# The camera passed to Android at every start, as with --camera: off, auto
# (the first usable camera of the host) or videoN. A camera that is missing,
# or that Ika cannot open, is left out, and Ika starts without one. --camera
# and --no-camera win. "Start with the camera" in Ika's Startup options sets
# it. Environment variable: IKA_CAMERA
device = off
# Anti-flicker of the camera passed to Android with --camera: auto, 50, 60 or
# off. Lights flicker at twice the mains frequency; a camera set for the wrong
# one shows bands and in dim light can run slower. auto takes the mains
# frequency of the country of the host's timezone, and leaves the camera's own
# setting where that country has two (Japan). Command-line equivalent:
# --camera_power_line_frequency=. Environment variable:
# IKA_CAMERA_POWER_LINE_FREQUENCY
power_line_frequency = auto


# ----------------------------------------------------------------------------
[network]
vhost_net = true
vhost_user_vsock = false
# Native vsock carries adb; the half tunnel keeps TCP 6520 for fastboot.
adb_mode = native_vsock,vsock_half_tunnel
enable_wifi = false
enable_host_bluetooth = false
netsim_bt = false
enable_host_nfc = false
netsim_nfc = false
casimir_instance_num = 1
enable_host_uwb = false
netsim_uwb = false
pica_instance_num = 1
start_gnss_proxy = false
enable_modem_simulator = false


# ----------------------------------------------------------------------------
[storage]
# Size of the data partition in decimal GB for a new VM. 'ika reset
# --data_gb=N' sets a different size and remembers it.
data_gb = 64
use_overlay = true
use_sdcard = false


# ----------------------------------------------------------------------------
[logging]
# VERBOSE, DEBUG, INFO, WARNING, ERROR or FATAL.
file_verbosity = WARNING
verbosity = WARNING


# ----------------------------------------------------------------------------
[reporting]
# y or n: send anonymous usage statistics to Google.
report_anonymous_usage_stats = n


# ----------------------------------------------------------------------------
[launcher]
daemon = true
start_webrtc = false


# ----------------------------------------------------------------------------
[boot]
# Seconds to wait for Android to finish booting. Past them, a start keeps
# waiting while Android still makes progress, for up to four times as long.
# Environment variable: CVD_BOOT_TIMEOUT_SEC
boot_timeout_sec = 150


# ----------------------------------------------------------------------------
[console]
# Display density. "auto" calculates it from the host's display.
# Command-line equivalent: --dpi=. Environment variable: IKADPI
dpi = auto
# Display density in Android's TV mode. "auto" is 1.5 times the density "auto"
# calculates for dpi, so that the TV interface is larger.
# Command-line equivalent: --dpi=, in either mode. Environment variable:
# IKA_TV_DPI
tv_dpi = auto
# Whether the keyboard drives a gamepad in Android's TV mode too, with the
# keys and settings of [keyboard_gamepad] below: true or false. Those keys no
# longer type there; the host's gamepads are the TV remote either way.
# Environment variable: IKA_TV_KEYBOARD_GAMEPAD
tv_keyboard_gamepad = false
# Extra arguments for the console and the app windows, separated by spaces, for
# example --keyboard=uhid --no-clipboard-autosync
# Command-line equivalent: --ika_scrcpy=. Environment variable: IKA_SCRCPY
scrcpy_args =
# Seconds to wait for the guest to reboot before leaving the console closed.
# Environment variable: IKA_SCRCPY_REBOOT_TIMEOUT_SEC
reboot_timeout_sec = 120
# The display's refresh rate in Hz, which paces Android's frames. "auto" takes
# the host display's rate (60 when it cannot be read), so that the guest's
# frames land on the host's refreshes; a number sets it, for example 60 on a
# 120 Hz display to halve the guest's composition work. Low-CPU mode and a
# --display= option win. Environment variable: IKA_REFRESH_RATE_HZ
refresh_rate_hz = auto


# ----------------------------------------------------------------------------
[keyboard_gamepad]
# The keys of the keyboard gamepad, for apps whose start options ("Startup
# options" on an app's launcher) use the keyboard as a gamepad, and for TV
# mode with tv_keyboard_gamepad = true; "Startup options" on Ika's launcher
# edits them. One
# or more key names per control, separated by spaces; SDL's scancode names (Up,
# Space, Return, Escape, Backspace, Tab, F1, A, 1, ...), the physical positions
# of keys on a US layout, with _ for a space in a name (Keypad_Enter,
# Left_Shift, Page_Up). An empty value leaves the control without a key. Mapped
# keys drive the gamepad instead of typing. Keys that Ika does not know are
# reported in the app window's ~/ika/apps/PACKAGE/window.log and skipped. A key
# given to a control here is taken from the control it is a default of.
# left_stick and right_stick are the sticks' clicks; walk, held, slows the
# sticks (walk_percent below). The mouse's buttons and wheel are keys too:
# Mouse_Left, Mouse_Right, Mouse_Middle, Mouse_X1, Mouse_X2, Wheel_Up,
# Wheel_Down, Wheel_Left, Wheel_Right (a notch presses the control for a
# moment). The mouse's buttons cross over on the triggers, as in PC shooters:
# the left button, which fires, is the right trigger, and the right button,
# which aims, the left. With mouse_stick set, the window captures the pointer
# (Cmd or Left Alt releases it) and the mouse, buttons and wheel too, is the
# gamepad's while captured; with mouse_stick = off, the mouse is not the
# gamepad's at all.
# A game can have keys and settings of its own,
# over these: 'ika app --controller NAME' edits them, in
# ~/ika/apps/PACKAGE/controller.ini.
left_stick_up = W
left_stick_down = S
left_stick_left = A
left_stick_right = D
dpad_up = Up
dpad_down = Down
dpad_left = Left
dpad_right = Right
right_stick_up = I
right_stick_down = K
right_stick_left = J
right_stick_right = L
a = Space
b = Escape
x = C
y = V
start = Return Keypad_Enter
back = Backspace
guide =
left_shoulder = Q Wheel_Up
right_shoulder = E Wheel_Down
left_stick = Left_Shift
right_stick = F Mouse_Middle
left_trigger = Z Mouse_Right
right_trigger = X Mouse_Left
walk = Tab
# Milliseconds a stick takes from its center to where it is pushed, as a
# thumb pushing a stick does, so that a tap moves a little and a held key
# more; 0 pushes it all the way at once. A stick comes back at once.
stick_ramp_ms = 100
# The sticks' deflection, in percent, while the walk key is held.
walk_percent = 50
# What two opposite directions held together do: last (the last pressed
# counts) or neutral (they cancel out), on every pad; socd_dpad,
# socd_left_stick and socd_right_stick set one pad, empty leaves it as socd.
socd = last
socd_dpad =
socd_left_stick =
socd_right_stick =
# The stick the mouse moves: off, right (the camera in most games) or left.
# The faster the mouse moves, the farther the stick, full at 32 pixels per
# 8 ms at mouse_sensitivity 100 (percent); the stick comes back when the
# mouse stops, and the stick's keys win while held.
mouse_stick = off
mouse_sensitivity = 100


# ----------------------------------------------------------------------------
[apps]
# Seconds between checks for installed or removed apps while the app menu
# watcher runs. Environment variable: IKA_APP_MENU_POLL_SEC
menu_poll_sec = 5
# Apps kept out of the app list, name matching and the desktop menu, as package
# names separated by spaces. They can still be opened by their package name.
hidden_apps = com.google.android.apps.restore com.google.android.googlequicksearchbox com.android.calculator2 org.lineageos.etar com.android.deskclock com.android.contacts org.lineageos.recorder org.lineageos.audiofx
# Apps treated as games, even though they do not declare themselves as games:
# their menu entries are marked as games, and they start with fullscreen and
# the keyboard sent straight to Android ticked in their start options.
# Package names separated by spaces.
game_apps =
# Opening a game sends the other open games to the background: their windows
# close, and each game stays on a display of its own, turned off, so that
# Android stops it until its window opens again, where it left off. false
# leaves the other games' windows open. Environment variable:
# IKA_BACKGROUND_GAMES
background_games = true


# ----------------------------------------------------------------------------
[timeouts]
# Seconds 'ika install' allows for each APK. Environment variable:
# IKA_INSTALL_TIMEOUT_SEC
install_timeout_sec = 1800
# Seconds 'ika gsf' waits for Google Play Services to assign the ID.
# Environment variable: IKA_GSF_ID_TIMEOUT_SEC
gsf_id_timeout_sec = 120
# Seconds 'ika backup' and 'ika restore' allow for listing apps, and for
# copying one app's files.
backup_list_timeout_sec = 120
backup_copy_timeout_sec = 3600


# ----------------------------------------------------------------------------
[system]
# Seconds to allow Cuttlefish and gfxstream to clean up before forcing
# surviving processes to exit. Environment variable: IKA_STOP_GRACE_SEC
stop_grace_sec = 30
# Open-file limit Ika raises its processes to when it is lower.
# Environment variable: IKA_MIN_OPEN_FILES
min_open_files = 65536
# Page size of the guest kernel on ARM64 hosts: auto, 4k or 16k.
# Environment variable: IKA_KERNEL_PAGE_SIZE
kernel_page_size = auto
EOF
}

if [[ ! -e "${IKA_INI_FILE}" ]]; then
  if mkdir -p "${IKA_INI_FILE%/*}" 2>/dev/null \
      && ika_ini_write_default >"${IKA_INI_FILE}.$$" 2>/dev/null; then
    mv -n -- "${IKA_INI_FILE}.$$" "${IKA_INI_FILE}" 2>/dev/null || true
  fi
  rm -f -- "${IKA_INI_FILE}.$$"
fi
ika_ini_load "${IKA_INI_FILE}"

