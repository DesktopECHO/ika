# ika: start options and the help text.
# Sourced by src/tools/ika, in its order; see there.

parse_start_options() {
  local -n fullscreen_mode_ref="$1"
  local -n start_args_ref="$2"
  local camera_device=""
  local no_camera=false
  local hw_video_decode_mode
  shift 2

  hw_video_decode_mode="$(normalize_hw_video_decode_mode "${IKA_HW_VIDEO_DECODE}")"
  IKA_CAMERA_POWER_LINE_FREQUENCY="$(normalize_camera_power_line_frequency \
    "${IKA_CAMERA_POWER_LINE_FREQUENCY}")"

  fullscreen_mode_ref="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--fullscreen)
        fullscreen_mode_ref="true"
        shift
        ;;
      # --noconsole too: Cuttlefish would take it as its --console (the serial
      # console, off already), and it would do nothing
      --no-console|--noconsole)
        START_CONSOLE="false"
        shift
        ;;
      # Exported, as restart runs start again
      --lowcpu)
        export IKA_LOWCPU="on"
        shift
        ;;
      --lowcpu=*)
        export IKA_LOWCPU="$(normalize_lowcpu_mode "${1#*=}")"
        shift
        ;;
      --no-lowcpu)
        export IKA_LOWCPU="off"
        shift
        ;;
      --gfxstream_vulkan=*)
        GFXSTREAM_VULKAN_MODE="$(normalize_gfxstream_vulkan_mode "${1#*=}")"
        export GFXSTREAM_VULKAN="${GFXSTREAM_VULKAN_MODE}"
        shift
        ;;
      --gfxstream_vulkan)
        shift
        [[ $# -gt 0 ]] || die "--gfxstream_vulkan requires a value: auto, on, or off"
        GFXSTREAM_VULKAN_MODE="$(normalize_gfxstream_vulkan_mode "$1")"
        export GFXSTREAM_VULKAN="${GFXSTREAM_VULKAN_MODE}"
        shift
        ;;
      # Exported, as restart runs start again
      --host_cached_memory=*)
        IKA_HOST_CACHED_MEMORY="$(normalize_host_cached_memory_mode "${1#*=}")" \
          || die "--host_cached_memory requires on or off, not '${1#*=}'"
        export IKA_HOST_CACHED_MEMORY
        shift
        ;;
      --data_gb=*|--data_gb)
        respond_console "Use '${SCRIPT_NAME} reset --data_gb=GB' to change userdata size."
        die "--data_gb is only valid with '${SCRIPT_NAME} reset'"
        ;;
      --camera|--camera=*)
        [[ -z "${camera_device}" ]] || die "--camera given more than once"
        camera_device="auto"
        if [[ "$1" == --camera=* ]]; then
          camera_device="${1#--camera=}"
        elif [[ $# -gt 1 && "$2" =~ ^(/dev/)?video[0-9]+$ ]]; then
          camera_device="$2"
          shift
        fi
        # The camera is attached when the VM starts
        if [[ "${START_KEEPS_RUNNING_VM}" == "true" ]] && has_live_cvd_processes; then
          [[ "${camera_device}" == "auto" ]] && camera_device=""
          die "Unable to add camera to a powered-on instance, try '${SCRIPT_NAME} restart --camera${camera_device:+=${camera_device}}'"
        fi
        camera_device="$(resolve_camera_device "${camera_device}")" || exit 1
        log_start_note "$(camera_description "${camera_device}")"
        start_args_ref+=("--media=v4l2_proxy:device=${camera_device}")
        shift
        ;;
      --no-camera)
        no_camera=true
        shift
        ;;
      --camera_power_line_frequency=*)
        IKA_CAMERA_POWER_LINE_FREQUENCY="$(normalize_camera_power_line_frequency "${1#*=}")"
        shift
        ;;
      --camera_power_line_frequency)
        shift
        [[ $# -gt 0 ]] || die "--camera_power_line_frequency requires a value: auto, 50, 60 or off"
        IKA_CAMERA_POWER_LINE_FREQUENCY="$(normalize_camera_power_line_frequency "$1")"
        shift
        ;;
      --hw_video_decode=*)
        hw_video_decode_mode="$(normalize_hw_video_decode_mode "${1#*=}")"
        # 'restart' hands its options to 'start' without this one.
        export IKA_HW_VIDEO_DECODE="${hw_video_decode_mode}"
        shift
        ;;
      --hw_video_decode)
        shift
        [[ $# -gt 0 ]] || die "--hw_video_decode requires a value: auto or off"
        hw_video_decode_mode="$(normalize_hw_video_decode_mode "$1")"
        export IKA_HW_VIDEO_DECODE="${hw_video_decode_mode}"
        shift
        ;;
      --ika_scrcpy=*)
        IKA_SCRCPY="${1#*=}"
        export IKA_SCRCPY
        shift
        ;;
      --ika_scrcpy)
        shift
        [[ $# -gt 0 ]] || die "--ika_scrcpy requires a value"
        IKA_SCRCPY="$1"
        export IKA_SCRCPY
        shift
        ;;
      *)
        start_args_ref+=("$1")
        shift
        ;;
    esac
  done

  [[ "${no_camera}" != "true" || -z "${camera_device}" ]] \
    || die "--camera and --no-camera given together"
  # Without --camera or --no-camera, the camera of ika.ini, if any
  if [[ -z "${camera_device}" && "${no_camera}" != "true" ]] \
      && camera_device="$(ini_camera_device)"; then
    log_start_note "$(camera_description "${camera_device}")"
    start_args_ref+=("--media=v4l2_proxy:device=${camera_device}")
  fi

  # After all options, as --camera_power_line_frequency may follow --camera
  [[ -z "${camera_device}" ]] || apply_camera_power_line_frequency "${camera_device}"
  # Exported, as restart runs start again: the camera is in the arguments now,
  # or --no-camera said there is none, and start must not add ika.ini's camera
  # to it (two cameras, both the same device, and Android's camera app quits)
  if [[ -n "${camera_device}" || "${no_camera}" == "true" ]]; then
    export IKA_CAMERA=off
  fi
}

console_notify() {
  local action="$1"
  local elapsed_sec="$2"
  local launcher_log_path
  if [[ "${action}" == "started" ]]; then
    launcher_log_path="${CVD_LAUNCHER_LOG}"
    if [[ "${launcher_log_path}" == "${HOME}/"* ]]; then
      launcher_log_path="~/${launcher_log_path#"${HOME}/"}"
    fi
    printf 'Device online in %ss: %s\n' "${elapsed_sec}" "${launcher_log_path}" >&3
    return 0
  fi
  printf 'Android virtual device %s in %ss.\n' "${action}" "${elapsed_sec}" >&3
}

run_timed_operation() {
  local action="$1"
  shift

  local start_epoch
  local elapsed_sec

  start_epoch="$(date +%s)"
  "$@"
  elapsed_sec="$(( $(date +%s) - start_epoch ))"

  console_notify "${action}" "${elapsed_sec}"
}

# Each 'ika start' adds its output to the start log under a dated header line.
readonly START_LOG_RUN_PREFIX="==== "

redirect_start_logs() {
  mkdir -p "$(dirname "${START_LOG_FILE}")"
  trim_log_lines "${START_LOG_FILE}"
  exec >>"${START_LOG_FILE}" 2>&1
  printf '%s%s %s start\n' "${START_LOG_RUN_PREFIX}" "$(date '+%Y-%m-%d %H:%M:%S')" \
    "${SCRIPT_NAME}"
}

usage() {
  local output_fd="${1:-1}"
  cat >&"${output_fd}" <<EOF

Usage:

  ${SCRIPT_NAME} start [-f|--fullscreen|--no-console] [--lowcpu|--no-lowcpu] [--camera[=videoN]|--no-camera] [--gfxstream_vulkan=auto|on|off] [--ika_scrcpy=ARGS] [--setting=arg] ...
  ${SCRIPT_NAME} stop
  ${SCRIPT_NAME} restart [-f|--fullscreen|--no-console] [--lowcpu|--no-lowcpu] [--camera[=videoN]|--no-camera] [--gfxstream_vulkan=auto|on|off] [--ika_scrcpy=ARGS] ...
  ${SCRIPT_NAME} reset [--data_gb=GB]
  ${SCRIPT_NAME} root
  ${SCRIPT_NAME} shell [COMMAND...]
  ${SCRIPT_NAME} adb [ARGS...]
  ${SCRIPT_NAME} gsf
  ${SCRIPT_NAME} backup [FILE]
  ${SCRIPT_NAME} restore [FILE]
  ${SCRIPT_NAME} status
  ${SCRIPT_NAME} session
  ${SCRIPT_NAME} options
  ${SCRIPT_NAME} app NAME|PACKAGE [-f|--fullscreen] [--touch] [--title=TEXT] [--size=WxH] [--dpi=N] [--ika_scrcpy=ARGS]
  ${SCRIPT_NAME} app --info NAME|PACKAGE
  ${SCRIPT_NAME} app --options NAME|PACKAGE
  ${SCRIPT_NAME} app --controller NAME|PACKAGE
  ${SCRIPT_NAME} app
  ${SCRIPT_NAME} app close NAME|PACKAGE|--all
  ${SCRIPT_NAME} app sync [--remove]
  ${SCRIPT_NAME} install FILE.apk...
  ${SCRIPT_NAME} remove NAME|PACKAGE
  ${SCRIPT_NAME} help

Example:

  ${SCRIPT_NAME} start --gpu_mode=guest_swiftshader --cpus=2 --memory_mb=2048 --dpi=240 --fullscreen
  ${SCRIPT_NAME} start --gpu_mode=gfxstream_guest_angle
  ${SCRIPT_NAME} reset --data_gb=128
  ${SCRIPT_NAME} restart --gpu_mode=gfxstream --gfxstream_vulkan=on
  ${SCRIPT_NAME} restart --ika_scrcpy="--no-clipboard-autosync"
  ${SCRIPT_NAME} restart --camera
  ${SCRIPT_NAME} restart --camera=video2
  ${SCRIPT_NAME} app com.gameloft.android.ANMP.GloftA8HM -f
  ${SCRIPT_NAME} app Asphalt 8 --touch

Options:

  --touch                With app, send left-button clicks and drags as real
                         touch input instead of mouse input, for games that
                         ignore the mouse. The right and middle buttons and
                         the wheel stay mouse input, Ctrl or Shift with the
                         left button still simulates a pinch, and the
                         keyboard and gamepads chosen in the app's start
                         options still pass through; the mouse does not.
                         It is also a start option ("Startup options"
                         on an app's menu entry).
  --no-console           With start or restart, run the VM without opening the
                         desktop console window (app windows still work).
  --lowcpu, --no-lowcpu  With start or restart, run low-CPU mode for
                         weak hosts, or not: the display refreshes at 30 Hz
                         (refresh_rate_hz in ika.ini), window blurs are off
                         and animations are shorter; the display's size and
                         density stay as they are. By default it is on when
                         the host has no hardware Vulkan driver or the GPU
                         mode is guest_swiftshader or guest_lavapipe, gives
                         the guest 2 vCPUs or fewer (4 or fewer under WSL),
                         or has less than 8 GB of memory
                         (--lowcpu=auto|on|off and IKA_LOWCPU=auto|on|off do
                         the same).
  --hw_video_decode=auto|off
                         With start or restart, give Android a video decoder
                         backed by the host's VA-API when the host has a
                         working driver (auto, the default), or not.
                         IKA_HW_VIDEO_DECODE and hw_video_decode in ika.ini
                         do the same.
  --host_cached_memory=on|off
                         With start or restart, take the guest's host-visible
                         Vulkan memory from a cached coherent host memory type
                         instead of a write-combined one, which is faster for
                         the guest's uploads on some drivers; off, the
                         default, leaves the driver's choice. NVIDIA's
                         proprietary driver always gets cached memory, which
                         it needs to draw correctly. Applies to the
                         gfxstream modes with Vulkan. IKA_HOST_CACHED_MEMORY
                         and host_cached_memory in ika.ini do the same.
  --camera[=videoN]      With start or restart, pass a host camera to Android
                         as its front camera. Without a value, the first
                         video capture device offering MJPEG, NV12 or YUYV
                         is used (USB webcams, the Mac FaceTime camera), and
                         a virtual camera only when there is no other; videoN
                         or /dev/videoN picks one. Applies until the next
                         start or restart without it. Needs the video group.
                         start only adds a camera when Android is off; use
                         restart while it runs. camera.device in ika.ini
                         (off, auto or videoN; "Start with the camera" in
                         Ika's Startup options) passes one at every start.
  --no-camera            With start or restart, start without the camera of
                         camera.device in ika.ini.
  --camera_power_line_frequency=auto|50|60|off
                         With --camera, set the camera's anti-flicker to the
                         mains frequency of the room's lights (default auto:
                         that of the country of the host's timezone; ika.ini
                         camera.power_line_frequency).
  --dpi=N                With start or restart, set the display density
                         in either mode (default: from the host display, or
                         144 when no display size can be read, and 1.5 times
                         that in TV mode; IKADPI does the same, and
                         IKA_TV_DPI in TV mode).
  --memory_mb=MB         Override the default guest RAM setting.
                         Normally ~25% of host RAM, capped at 32 GB.
  --data_gb=GB           With reset, configure the userdata size used by the
                         next start and subsequent factory resets.
  --title=TEXT           With app, override the window title (default: the
                         app's label).
  --size=WxH             With app, set the initial window size in logical
                         points (default: last size, or 60% of the screen's
                         width at 16:9).
  --dpi=N                With app, set the window's display density for this
                         start, 96 to 999 (1 to 95 is 96), over the app's
                         start options; auto or 0 is the console's.

TV mode:

  "Desktop/TV" lists the desktop's launcher under "Desktop mode" and each TV
  launcher under "TV mode"; nothing else changes the mode. It is in the
  desktop's app menu, where it opens in a window of its own like any app
  ('${SCRIPT_NAME} app Desktop/TV' does the same), in Android's app drawer in
  desktop mode, and in the TV launcher's apps in TV mode. Switching modes asks
  first, then Android restarts in the other mode, the console reopens in it
  and app windows close. In TV mode, choosing another TV launcher makes it the
  Home app at once.

  In TV mode the console is fullscreen at every start (MOD+F leaves it), at
  1.5 times the desktop's automatic density (tv_dpi in ika.ini; --dpi
  overrides it), and passes the gamepad through as the remote: the D-pad or
  left stick moves, A selects, B goes back and the guide button goes Home; with
  tv_keyboard_gamepad = true in ika.ini, the keyboard is a gamepad too. The
  keyboard and mouse work as on the desktop, except that a right click goes
  back (Shift and right-click for a right click). Apps opened from the
  desktop's app menu or with '${SCRIPT_NAME} app' still open in their own
  windows, at the desktop's density.

App windows:

  '${SCRIPT_NAME} app NAME' opens one app in its own resizable, titled
  window backed by a Cuttlefish display of its own, added while the VM runs
  and shown with raw frames like the console. The app is restarted on that
  display if it was already running, and closing the window, MOD+Q or
  '${SCRIPT_NAME} app close' closes the app and removes the display. 'stop',
  'reset', 'restart' and a switch between desktop and TV mode close all app
  windows; 'start' leaves them open.

  Games (apps declaring android:appCategory="game", or listed in game_apps
  under [apps] in ika.ini) open in their own windows too. Their menu
  entries are marked as games, and a game added to the menu starts
  fullscreen, with the keyboard sent straight to Android (see the start
  options below).

  Opening a game sends the other games with open windows to the background:
  their windows close, and each stays on its own display, turned off, so that
  Android stops it without ending it. Opening it again brings it back where
  it left off. '${SCRIPT_NAME} app close' ends a game in the background, and
  'stop', 'reset', 'restart' and a switch between desktop and TV mode end
  them all. background_games = false under [apps] in ika.ini turns this off.

  '${SCRIPT_NAME} app' alone lists the apps that can be launched, with apps
  already open in their own window in bold (marked "(open)" when the output
  is not a terminal or NO_COLOR is set), and games in the background marked
  "(background)".

  NAME is a package name or an app label from that list. Labels match
  case-insensitively, exactly or by a unique part ('app setti' opens
  Settings), and need no quotes when they contain spaces.

  '${SCRIPT_NAME} app sync' adds each launchable app to the desktop's app
  menu, as "∙ LABEL", or "🎮 ∙ LABEL" for a game, with its own
  icon, in an "Android Apps (Ika)" group (a GNOME app-grid folder, or a
  submenu on KDE Plasma, XFCE, Cinnamon and MATE), and removes entries for
  apps that were uninstalled. While the VM runs, a watcher started by 'start'
  keeps the menu in sync as apps are installed or removed (log:
  ~/ika/app-menu.log). '--remove' deletes the entries and the group and turns
  the automatic sync off until 'app sync' is run again. 'reset' removes the
  entries as well; the next 'start' rebuilds them.

  Right-clicking an app in the menu offers "Startup options", a window,
  "Startup Options · LABEL": the app window's display density ("0=Auto"
  for the console's, else 96 to 999 DPI; 1 to 95 is 96), then a checkbox for
  each option the app can start with: "Fullscreen mode (F11, Cmd+F or
  Left-Alt+F exits)", "Send the keyboard straight to Android (many games
  need this)", "Send the mouse straight to Android (Cmd or Left-Alt releases
  pointer)", "Use gamepads, including ones plugged in later", "Keyboard as a
  gamepad (keys on the Gamepad Emulation tab)" (its keys are in
  [keyboard_gamepad] in ika.ini) and "Mouse as touch:
  clicks tap, drags swipe". The keyboard and the mouse sent straight to
  Android reach it as HID devices (uhid), as gamepads do; the window
  captures the pointer, and tapping Cmd (Left Super) or Left Alt releases
  it. "Apply settings" saves them, "Apply and start" saves them and starts
  the app with them, and Cancel leaves them as they were.
  '${SCRIPT_NAME} app --options NAME' opens
  it from a terminal. They are saved in ~/ika/app-options.ini, and 'app' adds
  them to the options it is given, from the menu or a terminal ('--dpi' goes
  over the saved density). Without them, an app or game gets the console's
  density, the desktop's keyboard and mouse, and no gamepad. A game starts
  with "Fullscreen mode" and "Send the keyboard straight to Android" ticked
  the first time it is added to the menu.

  The window has those as its "Startup Options" tab, for games and other
  apps alike, and a "Gamepad Emulation" tab with the keyboard gamepad's keys
  and settings for the app:
  a key or more per control (SDL's scancode names, or the mouse's buttons
  and wheel: Mouse_Left, Wheel_Up, ...), "Full tilt, ms" (the milliseconds
  a stick takes to go where it is pushed; 0 is instant), the walk speed
  (the sticks' deflection with the walk key held), what two opposite
  directions held together do ("Last pressed wins" or "Cancel out"), and
  which stick the mouse moves (none by default; the right
  one is the camera in most games) and how fast. With the mouse on a stick,
  the window captures the pointer (Alt releases it); with "Off", the mouse is
  not the gamepad's. "Apply settings" also saves an edited mapping in
  ~/ika/apps/PACKAGE/controller.ini, over [keyboard_gamepad] in ika.ini, and
  ticks "Keyboard as a gamepad" unless it was unticked there;
  "Reset to default", once confirmed, resets the start options (a game's to
  "Fullscreen mode", at the console's density) and removes the game's
  mapping, so that it has ika.ini's. '${SCRIPT_NAME} app --controller NAME'
  opens the window on that tab. The window is GTK 3's (python3 with its GTK
  bindings), native on Wayland and X11 alike.

Installing and removing apps:

  '${SCRIPT_NAME} install FILE.apk...' installs each APK in Android, replacing
  an installed version of the same app and keeping its data. The file manager
  offers it as "Ika APK installer" for APK files. '${SCRIPT_NAME} remove NAME'
  uninstalls an app and deletes its data; NAME is a package name or an app
  label, matched as for 'app'. Apps that come with Android cannot be removed.
  If the VM is not running, either command starts it without the console
  first.

Root:

  '${SCRIPT_NAME} root' runs ika-root, which roots the VM with the latest Magisk
  release and enables developer options. Rooting a VM the first time unlocks
  and wipes it, after asking to confirm; later runs update Magisk and keep the
  data. 'reset' undoes it.

Android shell:

  '${SCRIPT_NAME} shell' opens a shell in Android (adb shell); '${SCRIPT_NAME} shell
  COMMAND' runs COMMAND there. If the VM is not running, it is started
  without the console first. On WSL, Windows Terminal's Ika profile opens it.

adb:

  '${SCRIPT_NAME} adb ARGS' runs Ika's adb (${CVD_ADB_BIN})
  with ARGS as given, such as '${SCRIPT_NAME} adb devices' or
  '${SCRIPT_NAME} adb logcat'. It starts nothing.

GSF ID:

  '${SCRIPT_NAME} gsf' prints the Google Services Framework ID, copies it to
  the clipboard (wl-copy, xclip or xsel) and opens Google's uncertified device
  page in the default browser. Register the ID there if Google blocks sign-in
  because the device is not Play Protect certified; it does not make the
  device certified. A factory reset gives the device a new ID. If the VM is
  not running, it is started first.

Android files:

  While the VM runs, Android's shared storage (/sdcard) is mounted on
  \$XDG_RUNTIME_DIR/ika/Android (~/ika/Android without one), where host
  programs can open, change and delete its files; the file manager's sidebar
  lists it as Android. 'start' mounts it; 'stop', 'restart' and 'reset'
  unmount it, as does Android turning off by itself. Its log is
  ~/ika/madbfs.log.

Backup:

  '${SCRIPT_NAME} backup [FILE]' saves to FILE, a gzip-compressed tar archive
  (default: ~/ika/ika-backup-YYYYMMDDHHMMSS.tgz), the apps you installed,
  with their split APKs, their files in /sdcard/Android/data and game downloads in
  /sdcard/Android/obb, the DCIM, Pictures, Download, Documents, Music, Movies
  and Recordings folders, and your choices: granted app permissions, special
  app access, default apps, apps you disabled, the dark theme, and settings
  such as font size, keyboard, pointer speed and accessibility. App-private
  data such as logins and saved games is not included, nor are files an app
  keeps readable only to itself. Each app is stopped while its files are
  copied. '${SCRIPT_NAME} restore [FILE]' reinstalls the apps, copies the
  files back and reapplies your choices, for example after 'reset'; without
  FILE it restores the latest backup in ~/ika. It asks before it starts, as
  it replaces what is on the device. If the VM is not running, it is started
  first.

Settings:

  Ika's defaults are in ~/ika/ika.ini, which Ika writes the first time it
  runs. Edit it to change them: it has a section for each area ([compute],
  [gpu], [network], [apps] and others) and a comment for each setting.
  Command-line options override it, and so do the environment variables below.
  Delete the file to get a fresh copy.

  "Startup options" on Ika's launcher ('${SCRIPT_NAME} options') opens a window,
  "Startup Options · Ika", for its most used settings, with two tabs.
  Startup Options has "GPU Hardware" first (gpu.use_gpu: Auto, or one of the
  host's GPUs, which Ika then uses alone), then the GPU mode (Auto, the
  default, is gpu_mode = auto; "gfxstream, OpenGL ES" is gfxstream with
  gfxstream_vulkan = off), the vCPUs and the memory, the console's density on
  the desktop and in TV mode and its refresh rate (0 for auto), hardware
  video decoding, low-CPU mode, "Start with the camera"
  (camera.device: ticked, the first usable camera, unless ika.ini names one)
  and "Enable gamepad emulation in TV mode" (tv_keyboard_gamepad). Gamepad
  Emulation has the keyboard gamepad of
  [keyboard_gamepad], which TV mode and the apps without a mapping of their
  own use. "Apply settings" writes the settings changed in ika.ini, in place
  of their lines, "Apply and restart" also restarts Ika, so that they apply,
  "Reset to default", once confirmed, writes their built-in values, and
  Cancel leaves the file as it was.

Environment variables:

  GFXSTREAM_VULKAN       auto, on, or off. With --gpu_mode=gfxstream, auto
                         disables Vulkan only when the primary host Vulkan
                         device is llvmpipe, or when gfxstream would pick
                         llvmpipe over the GPU; on forces GLES+Vulkan, and off
                         forces GLES-only. The setting is ignored by the
                         Vulkan-only gfxstream_guest_angle mode. On Apple
                         Silicon hosts with 16 KiB pages, gfxstream modes route
                         host-visible guest Vulkan memory through udmabuf-backed
                         dma-bufs (the path the Apple GPU supports).
  IKA_HOST_CACHED_MEMORY on or off, as --host_cached_memory.
  IKA_HW_VIDEO_DECODE    auto or off, as --hw_video_decode.
  IKA_CAMERA_POWER_LINE_FREQUENCY
                         auto, 50, 60 or off, as --camera_power_line_frequency.
  CVD_BOOT_TIMEOUT_SEC   Seconds to wait for Android to boot (default: 150),
                         kept waiting for up to four times as long while
                         Android still makes progress.
  IKA_MIN_OPEN_FILES     The open files limit the VM needs (default: 65536).
  IKA_KERNEL_PAGE_SIZE   auto, 4k or 16k: the ARM64 guest kernel's page size.
  IKADPI                 Display density, as --dpi.
  IKA_REFRESH_RATE_HZ    The display's refresh rate: auto (the host display's,
                         the default) or a number. Low-CPU mode and --display=
                         win.
  IKA_LOWCPU             auto, on or off: low-CPU mode, as --lowcpu and
                         --no-lowcpu.
  IKA_TV_DPI             Display density in TV mode (default: 1.5 times the
                         automatic density).
  IKA_TV_KEYBOARD_GAMEPAD
                         true: the keyboard is a gamepad in TV mode too, with
                         the keys of [keyboard_gamepad] in ika.ini.
  IKA_SCRCPY             Extra whitespace-separated args appended to the console
                         and the app windows.
                         Equivalent command-line option: --ika_scrcpy=ARGS
                         (example: --keyboard=uhid --no-clipboard-autosync)
  IKA_APP_MENU_POLL_SEC  Seconds between checks for installed or removed
                         apps while the app menu watcher runs (default: 5).
  IKA_BACKGROUND_GAMES   false: opening a game leaves the other games' windows
                         open, instead of sending them to the background
                         (default: true).
  IKA_INSTALL_TIMEOUT_SEC
                         Seconds 'install' allows for each APK (default: 1800).
  IKA_GSF_ID_TIMEOUT_SEC Seconds 'gsf' waits for Google Play Services to
                         assign the ID (default: 120).
  IKA_STOP_GRACE_SEC     Seconds to allow Cuttlefish and gfxstream to clean up
                         before forcing surviving processes to exit (default: 30).
  IKA_SCRCPY_REBOOT_TIMEOUT_SEC
                         Seconds to wait for a guest reboot before leaving the
                         console closed (default: 120).

  NOTE: All other parameters will be passed directly to Cuttlefish.

EOF
}

