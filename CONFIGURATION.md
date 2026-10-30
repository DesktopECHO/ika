[README](README.md) | [Using Ika](USAGE.md) | **Configuration** | [Graphics](GRAPHICS.md) | [Building](BUILDING.md) | [Downloads](DOWNLOADS.md) | [Changelog](CHANGELOG.md)

# Configuration

This page is the reference for the `ika` command, its options, the settings in
`~/ika/ika.ini`, the environment variables and the files Ika keeps. For how
to use Ika day to day, see [Using Ika](USAGE.md).

A setting is taken from the first of these that gives it:

1. a command-line option;
2. an environment variable;
3. `~/ika/ika.ini`;
4. the built-in default.

## Commands

| Command | What it does |
| --- | --- |
| `ika start [OPTIONS]` | Starts Android and opens the console. If Android is already running, reopens the console. |
| `ika stop` | Closes the console and app windows, unmounts Android's files and stops the VM. |
| `ika restart [OPTIONS]` | Stops the VM and starts it again with the options given, or starts it if it is stopped. |
| `ika status` | Says whether the VM is running, and how the console's frames reach it (`DMA-BUFs`, or `pixels read back by crosvm`, the slow path). |
| `ika reset [--data_gb=GB]` | Factory-resets Android, after you type `y`. See [Factory reset](#factory-reset). |
| `ika app` | Lists the apps that can be opened, with open app windows in bold. |
| `ika app NAME [OPTIONS]` | Opens an app in its own window. See [App windows](USAGE.md#app-windows). |
| `ika app --options NAME` | Opens the app's start options window. |
| `ika app --controller NAME` | Opens the start options window on its Gamepad Emulation tab. |
| `ika app NAME --dpi=N` | Opens an app window at a display density of 96 to 999 for this start (`auto`: the console's). |
| `ika app --info NAME` | Opens Android's App info page for the app. |
| `ika app close NAME` / `--all` | Closes an app window, or all of them. |
| `ika app sync [--remove]` | Adds the Android apps to the desktop's app menu at once, or removes them and turns the automatic sync off. |
| `ika install FILE.apk...` | Installs APK files, replacing an installed version of the same app and keeping its data. |
| `ika remove NAME` | Uninstalls an app and deletes its data, its window state and its controller mapping. |
| `ika root` | Roots Android with Magisk. See [Rooting with Magisk](USAGE.md#rooting-with-magisk). |
| `ika gsf` | Prints and copies the Google Services Framework ID. See [Google sign-in](USAGE.md#google-sign-in-on-uncertified-devices). |
| `ika backup [FILE]` / `ika restore [FILE]` | Backs up and restores your apps, files and choices. See [Backing up](USAGE.md#backing-up-apps-and-files). |
| `ika help` | Prints the built-in usage text. |

`NAME` is a package name or an app's label as `ika app` lists it. Labels match
without regard to case, exactly or by a part only one app has (`ika app setti`
opens Settings), and need no quotes when they contain spaces. A name that
matches several apps lists them instead of guessing.

`ika app NAME`, `ika install`, `ika remove`, `ika backup`, `ika restore`,
`ika gsf` and `ika root` start Android first when it is not running, without
the console. `ika app` alone and `ika app sync` need Android running.

## Options of start and restart

Ika handles these options itself:

| Option | Effect |
| --- | --- |
| `-f`, `--fullscreen` | Opens the console fullscreen. |
| `--no-console` | Starts Android without the console. App windows still open. |
| `--dpi=N` | The display density, in either mode. |
| `--lowcpu`, `--no-lowcpu`, `--lowcpu=auto\|on\|off` | Low-CPU mode on or off. See [Low-CPU mode](#low-cpu-mode). |
| `--camera[=videoN]` | Passes a host camera to Android. See [Camera](USAGE.md#camera). |
| `--camera_power_line_frequency=auto\|50\|60\|off` | The camera's anti-flicker. |
| `--gfxstream_vulkan=auto\|on\|off` | Vulkan in the `gfxstream` GPU mode. See [Graphics](GRAPHICS.md#vulkan-in-gfxstream-mode). |
| `--host_cached_memory=on\|off` | Cached host memory for the guest's Vulkan uploads. See [Graphics](GRAPHICS.md#host-cached-memory). |
| `--hw_video_decode=auto\|off` | Hardware video decoding. See [Hardware video decoding](#hardware-video-decoding). |
| `--ika_scrcpy=ARGS` | Extra arguments for the console and app windows, which are scrcpy windows. |

Any other option goes to Cuttlefish's launcher, `cvd_internal_start`, for
example `--gpu_mode=`, `--cpus=` or `--memory_mb=`:

```bash
ika restart --gpu_mode=gfxstream --cpus=8 --memory_mb=8192
ika start --gpu_mode=guest_swiftshader --cpus=2 --memory_mb=2048 --dpi=240
```

Ika passes its own values for what you do not give: the settings of the
`[compute]`, `[gpu]`, `[network]`, `[storage]`, `[logging]`, `[reporting]`
and `[launcher]` sections, audio, the display's size, density and refresh
rate, the host's time zone, a serial number and the CPU pinning. An option you
give wins over the value Ika would pass.

## Options of ika app

| Option | Effect |
| --- | --- |
| `-f`, `--fullscreen` | Opens the window fullscreen. |
| `--touch` | Sends left clicks and drags as a finger. See [Touch input](USAGE.md#touch-input). |
| `--title=TEXT` | The window title (default: the app's label). |
| `--size=WxH` | The window size in logical pixels (default: its last size, or 60% of the screen's width at 16:9). |
| `--ika_scrcpy=ARGS` | Extra arguments for this app's window. |

These add to the app's start options: an option that is ticked there stays on.

## Defaults

| What | Default | Set with |
| --- | --- | --- |
| Virtual CPUs | Half the host's performance cores, counting hardware threads, at most 12; under WSL, all the CPUs WSL has (`processors` in `.wslconfig`) | `--cpus=`, `cpus` and `cpu_cap` in `[compute]` |
| Memory | A quarter of the host's memory, rounded up to a multiple of 2 GB, at most 32 GB; under WSL, all the memory WSL has (`memory` in `.wslconfig`) less 1 GB for Linux | `--memory_mb=`, `memory_mb`, `memory_step_mb` and `memory_cap_mb` in `[compute]` |
| Data partition | 64 GB (decimal), thin-provisioned | `ika reset --data_gb=GB`, `data_gb` in `[storage]` |
| GPU mode | `auto`: `venus` on a GPU with Vulkan 1.3 or newer and ETC2 textures; `gfxstream` when the host's only Vulkan drivers are software ones or gfxstream would pick llvmpipe over the GPU; `gfxstream_guest_angle` otherwise | `--gpu_mode=`, `gpu_mode` in `[gpu]` (see [Graphics](GRAPHICS.md#how-ika-chooses)) |
| Density | From the host display's width; 1.5 times that in TV mode | `--dpi=`, `dpi` and `tv_dpi` in `[console]` |
| Refresh rate | The host display's | `refresh_rate_hz` in `[console]` |
| Network | Ethernet only: no Wi-Fi, Bluetooth, NFC, UWB, GNSS or modem | `[network]` |
| Browser | Chromium, installed on a new device as the default browser | — |

Each virtual CPU is pinned to a host CPU, from the highest-numbered CPU down.

### Data partition size

`ika reset --data_gb=128` sets the size, in decimal gigabytes, of the data
partition of the next new device, and remembers it in `~/ika/data-gb`, where
it wins over `data_gb` in `ika.ini` for later resets too. A size applies only
when Android has no data partition yet: the first start, after `ika reset`,
or after the first `ika root`.

### Factory reset

`ika reset` asks you to type `y`, closes the console and app windows, stops
Android and deletes its data, which also relocks the bootloader and removes
root. It removes the Android apps from the desktop's menu; the next
`ika start` creates a new device and puts them back. It does not start
Android.

A reset keeps `ika.ini`, the apps' start options and controller mappings,
your backups, the data partition size and the device's serial number.

When the installed ROM's images are newer than Android's disk, after an
update of `ika-lineageos`, Cuttlefish would rebuild the disk and discard
Android's data, so `ika start` refuses to start and says why. To move to a new
ROM with your apps and files, run `ika backup` before installing it, then
`ika reset` and `ika restore`.

## Display and performance

### Display density

`dpi = auto` in `[console]` takes the density from the host display's width
(the width divided by 10, less 24, rounded down to a multiple of 8, at least
96), or 144 when the width cannot be read. `tv_dpi = auto` is 1.5 times that,
rounded down to a multiple of 8, so that the TV interface is larger. A number
sets either one, and `--dpi=N` on `ika start` or `ika restart` sets the
density in both modes.

### Refresh rate

The display's refresh rate paces Android's frames. `refresh_rate_hz = auto` in
`[console]` takes the host display's rate, so that Android's frames land on
the host's refreshes: 120 Hz on a 120 Hz panel. The rate is read on Wayland
sessions; on X11 sessions, and when it cannot be read, it is 60 Hz. A number
sets it, for example 60 on a 120 Hz display to halve Android's composition
work. Low-CPU mode and a `--display=` option win. The start log says which
rate it uses.

### Low-CPU mode

Low-CPU mode lightens Android for weak hosts: the display refreshes at
`refresh_rate_hz` in `[lowcpu]` (30 Hz), window blurs are off and animations
run at half their length. The display keeps its size and density.

`ika start` turns it on when `vulkaninfo` finds no hardware Vulkan device on
the host, when the GPU mode is `guest_swiftshader` or `guest_lavapipe`, when
Android gets 2 virtual CPUs or fewer, or when the host has less than 8 GB of
memory; the start log
says why. `--lowcpu` and `--no-lowcpu` decide it for one start, and `mode` in
`[lowcpu]` (`auto`, `on` or `off`) or `IKA_LOWCPU` by default.

### Hardware video decoding

`hw_video_decode = auto` in `[gpu]` gives Android a video decoder backed by
the host's VA-API driver, for H.264, HEVC, VP8 and VP9 as far as the host
decodes them, when `vainfo` finds a working driver; the start log says what it
found, and on Fedora where to get the drivers. Android uses it only with a
V4L2 Codec2 HAL in the ROM, and decodes in software otherwise. `off`, or
`--hw_video_decode=off`, leaves the decoder out, and a
`--crosvm_media_decoder=` option of your own wins.

On Intel GPUs that share the CPU's cache, the host decodes each picture
straight into Android's buffer instead of copying it there, once a test
decode at the first video shows that the driver can. crosvm logs which way it
went in `~/ika/cuttlefish/instances/cvd-1/logs/launcher.log`: `VA-API:
decoding pictures straight into guest memory`, or why pictures are copied.
Other GPUs copy the pictures.

## ika.ini

Ika writes `~/ika/ika.ini`, with every default and a comment for each
setting, the first time it runs. Edit it to change Ika's defaults; a package
update does not change it.

- A line starting with `#` or `;` is a comment. Values are written as they are,
  without quotes, and a `#` after a value is part of the value.
- Section and key names are not case-sensitive.
- A list, such as `hidden_apps`, takes package names separated by spaces or
  commas, and replaces the default list.
- Delete a line to use its built-in default, or the file to get a fresh copy.
- Ika reports lines it does not understand.
- Changes apply the next time Ika starts Android, or the console for
  `[console]` and `[apps]`.

```ini
[compute]
cpus = 8
memory_mb = auto

[apps]
game_apps = com.example.game
```

### [compute]

| Key | Default | Meaning |
| --- | --- | --- |
| `cpus` | `auto` | Virtual CPUs. `--cpus=` |
| `memory_mb` | `auto` | Memory in MB. `--memory_mb=` |
| `cpu_cap` | `12` | The most virtual CPUs `auto` gives (not under WSL) |
| `memory_step_mb` | `2048` | `auto` memory is rounded up to a multiple of this (not under WSL) |
| `memory_cap_mb` | `32768` | The most memory `auto` gives (not under WSL) |
| `memory_fallback_mb` | `4096` | Memory when the host's cannot be read |
| `enable_bootanimation`, `enable_sandbox` | `false` | Cuttlefish options |

### [gpu]

| Key | Default | Meaning |
| --- | --- | --- |
| `gpu_mode` | `auto` | The GPU mode: `auto` (`venus` or `gfxstream_guest_angle`, by the host's GPU), `gfxstream_guest_angle`, `gfxstream`, `venus`, `guest_swiftshader` and others. `--gpu_mode=`, which wins on every host. Hosts with only software Vulkan drivers, or whose GPU gfxstream passes over for llvmpipe, use `gfxstream` whatever this says, `auto` included. See [Graphics](GRAPHICS.md#how-ika-chooses) |
| `gfxstream_vulkan` | `auto` | Vulkan in the `gfxstream` mode. `--gfxstream_vulkan=`, `GFXSTREAM_VULKAN` |
| `host_cached_memory` | `off` | Cached host memory for Vulkan uploads. `--host_cached_memory=`, `IKA_HOST_CACHED_MEMORY` |
| `hw_video_decode` | `auto` | VA-API video decoding. `--hw_video_decode=`, `IKA_HW_VIDEO_DECODE` |
| `gpu_renderer_features` | `MinimalLogging:disabled;VulkanBatchedDescriptorSetUpdate:disabled` | gfxstream renderer features, separated by semicolons |
| `gpu_vhost_user_mode`, `enable_gpu_udmabuf`, `use_cvdalloc` | `auto`, `true`, `true` | Cuttlefish options |

### [lowcpu]

| Key | Default | Meaning |
| --- | --- | --- |
| `mode` | `auto` | Low-CPU mode: `auto`, `on` or `off`. `--lowcpu`, `--no-lowcpu`, `IKA_LOWCPU` |
| `refresh_rate_hz` | `30` | The refresh rate in low-CPU mode |

### [camera]

| Key | Default | Meaning |
| --- | --- | --- |
| `device` | `off` | The camera passed to Android at every start: `off`, `auto` (the first usable camera) or `videoN`. A camera that is missing is left out, and Ika starts without one; `--camera` and `--no-camera` win. **Start with the camera** in Ika's Startup options sets it. `IKA_CAMERA` |
| `power_line_frequency` | `auto` | The camera's anti-flicker: `auto`, `50`, `60` or `off`. `--camera_power_line_frequency=`, `IKA_CAMERA_POWER_LINE_FREQUENCY`. See [Camera](USAGE.md#camera) |

### [network]

Android has Ethernet only. These are Cuttlefish options:

| Key | Default |
| --- | --- |
| `vhost_net` | `true` |
| `vhost_user_vsock` | `false` |
| `adb_mode` | `native_vsock,vsock_half_tunnel` (adb over vsock; TCP 6520 for fastboot) |
| `enable_wifi`, `enable_host_bluetooth`, `netsim_bt`, `enable_host_nfc`, `netsim_nfc`, `enable_host_uwb`, `netsim_uwb`, `start_gnss_proxy`, `enable_modem_simulator` | `false` |
| `casimir_instance_num`, `pica_instance_num` | `1` |

The host side of Android's network is per user: Cuttlefish's `cvdalloc`
helper creates its bridge and NAT rules in an `ip cuttlefish` nftables table,
and dnsmasq serves its addresses.

### [storage]

| Key | Default | Meaning |
| --- | --- | --- |
| `data_gb` | `64` | The data partition's size in decimal GB for a new device. `ika reset --data_gb=` wins |
| `use_overlay`, `use_sdcard` | `true`, `false` | Cuttlefish options |

### [logging], [reporting], [launcher], [boot]

| Key | Default | Meaning |
| --- | --- | --- |
| `[logging] file_verbosity`, `verbosity` | `WARNING` | Cuttlefish's log levels: `VERBOSE`, `DEBUG`, `INFO`, `WARNING`, `ERROR` or `FATAL` |
| `[reporting] report_anonymous_usage_stats` | `n` | `y` sends anonymous usage statistics to Google |
| `[launcher] daemon`, `start_webrtc` | `true`, `false` | Cuttlefish options |
| `[boot] boot_timeout_sec` | `150` | Seconds to wait for Android to boot; a start keeps waiting while Android still makes progress, up to four times as long. `CVD_BOOT_TIMEOUT_SEC` |

### [console]

| Key | Default | Meaning |
| --- | --- | --- |
| `dpi` | `auto` | The density. `--dpi=`, `IKADPI`. See [Display density](#display-density) |
| `tv_dpi` | `auto` | The density in TV mode. `IKA_TV_DPI` |
| `tv_keyboard_gamepad` | `false` | `true` makes the keyboard a gamepad in TV mode too, with the keys of `[keyboard_gamepad]`, which no longer type there; the host's gamepads are the remote either way. `IKA_TV_KEYBOARD_GAMEPAD` |
| `refresh_rate_hz` | `auto` | The display's refresh rate. `IKA_REFRESH_RATE_HZ`. See [Refresh rate](#refresh-rate) |
| `scrcpy_args` | (empty) | Extra arguments for the console and app windows, for example `--no-clipboard-autosync`. `--ika_scrcpy=`, `IKA_SCRCPY` |
| `reboot_timeout_sec` | `120` | Seconds the console waits for Android to come back after a reboot. `IKA_SCRCPY_REBOOT_TIMEOUT_SEC` |

### [keyboard_gamepad]

The keys and settings of the keyboard gamepad, for apps whose start options
tick **Keyboard as a gamepad**. See
[Keyboard as a gamepad](USAGE.md#keyboard-as-a-gamepad) for how it plays.

Each control takes one or more key names separated by spaces: SDL's names
(`Up`, `Space`, `Return`, `Escape`, `Backspace`, `Tab`, `F1`, letters and
digits), with `_` for a space in a name (`Keypad_Enter`, `Left_Shift`,
`Page_Up`), or the mouse's `Mouse_Left`, `Mouse_Right`, `Mouse_Middle`,
`Mouse_X1`, `Mouse_X2`, `Wheel_Up`, `Wheel_Down`, `Wheel_Left` and
`Wheel_Right` (a wheel notch presses its control for a moment). An empty value
leaves a control without a key. A key you give a control is taken from the
control it is a default of, so that moving a key takes one line. Keys Ika does
not know are reported in the console log and skipped.

| Control | Default keys |
| --- | --- |
| `left_stick_up`, `left_stick_down`, `left_stick_left`, `left_stick_right` | `W`, `S`, `A`, `D` |
| `dpad_up`, `dpad_down`, `dpad_left`, `dpad_right` | `Up`, `Down`, `Left`, `Right` |
| `right_stick_up`, `right_stick_down`, `right_stick_left`, `right_stick_right` | `I`, `K`, `J`, `L` |
| `a`, `b`, `x`, `y` | `Space`, `Escape`, `C`, `V` |
| `start`, `back`, `guide` | `Return Keypad_Enter`, `Backspace`, (none) |
| `left_shoulder`, `right_shoulder` | `Q Wheel_Up`, `E Wheel_Down` |
| `left_trigger`, `right_trigger` | `Z Mouse_Right`, `X Mouse_Left` |
| `left_stick`, `right_stick` (the sticks' clicks) | `Left_Shift`, `F Mouse_Middle` |
| `walk` (held, it slows the sticks) | `Tab` |

| Setting | Default | Meaning |
| --- | --- | --- |
| `stick_ramp_ms` | `100` | Milliseconds a stick takes from its center to where a key pushes it, as a thumb does, so that a tap moves it a little and a held key all the way; `0` pushes it at once (**Full tilt, ms** in the Gamepad Emulation tab). A stick comes back at once |
| `walk_percent` | `50` | How far the sticks go, in percent, while `walk` is held |
| `socd` | `last` | What two opposite directions held together do: `last`, the last pressed counts, or `neutral`, they cancel out, as fighting games expect (**Opposite directions** in the Gamepad Emulation tab: **Last pressed wins** or **Cancel out**) |
| `socd_dpad`, `socd_left_stick`, `socd_right_stick` | (empty) | `socd` for one pad; empty follows `socd` |
| `mouse_stick` | `off` | The stick the mouse moves: `off`, `right` (the camera in most games) or `left` |
| `mouse_sensitivity` | `100` | The mouse stick's speed in percent: at 100, the stick is fully pushed at 32 pixels of motion per 8 ms |

With `mouse_stick` on a stick, the window captures the pointer, and the
mouse's buttons and wheel are keys of the mapping; Alt releases it and takes
it back. With `mouse_stick = off`, the mouse is not the gamepad's, its mapped
buttons and wheel included, and works as usual.

A game can have keys and settings of its own, in
`~/ika/apps/PACKAGE/controller.ini`, with the same lines; they go over this
section. `ika app --controller NAME` edits them (see
[Controller mapping per game](USAGE.md#controller-mapping-per-game)), and the
file can be written by hand for any app.

### [apps]

| Key | Default | Meaning |
| --- | --- | --- |
| `menu_poll_sec` | `5` | Seconds between the app menu watcher's checks for installed or removed apps. `IKA_APP_MENU_POLL_SEC` |
| `hidden_apps` | Android Switch, Google search, Calculator, Calendar, Clock, Contacts, Recorder, AudioFX | Package names kept out of `ika app`, name matching and the desktop menu. They still open by package name |
| `game_apps` | (empty) | Package names treated as games, besides the apps that declare themselves games |

### [timeouts]

| Key | Default | Meaning |
| --- | --- | --- |
| `install_timeout_sec` | `1800` | Seconds `ika install` allows for each APK. `IKA_INSTALL_TIMEOUT_SEC` |
| `gsf_id_timeout_sec` | `120` | Seconds `ika gsf` waits for Google Play Services to assign the ID. `IKA_GSF_ID_TIMEOUT_SEC` |
| `backup_list_timeout_sec`, `backup_copy_timeout_sec` | `120`, `3600` | Seconds `ika backup` and `ika restore` allow for listing the apps, and for copying one app's files |

### [system]

| Key | Default | Meaning |
| --- | --- | --- |
| `stop_grace_sec` | `30` | Seconds Cuttlefish and gfxstream get to clean up when Android stops, before surviving processes are ended. `IKA_STOP_GRACE_SEC` |
| `min_open_files` | `65536` | The open-file limit Ika raises its processes to. `IKA_MIN_OPEN_FILES` |
| `kernel_page_size` | `auto` | The guest kernel's page size on ARM64 hosts: `auto`, `4k` or `16k`. `IKA_KERNEL_PAGE_SIZE` |

## Environment variables

Each of these overrides its setting in `ika.ini`:

| Variable | Setting |
| --- | --- |
| `GFXSTREAM_VULKAN` | `[gpu] gfxstream_vulkan` |
| `IKA_HOST_CACHED_MEMORY` | `[gpu] host_cached_memory` |
| `IKA_HW_VIDEO_DECODE` | `[gpu] hw_video_decode` |
| `IKA_LOWCPU` | `[lowcpu] mode` |
| `IKA_CAMERA_POWER_LINE_FREQUENCY` | `[camera] power_line_frequency` |
| `CVD_BOOT_TIMEOUT_SEC` | `[boot] boot_timeout_sec` |
| `IKADPI`, `IKA_TV_DPI` | `[console] dpi`, `tv_dpi` |
| `IKA_REFRESH_RATE_HZ` | `[console] refresh_rate_hz` |
| `IKA_SCRCPY` | `[console] scrcpy_args` |
| `IKA_SCRCPY_REBOOT_TIMEOUT_SEC` | `[console] reboot_timeout_sec` |
| `IKA_APP_MENU_POLL_SEC` | `[apps] menu_poll_sec` |
| `IKA_INSTALL_TIMEOUT_SEC`, `IKA_GSF_ID_TIMEOUT_SEC` | `[timeouts] install_timeout_sec`, `gsf_id_timeout_sec` |
| `IKA_STOP_GRACE_SEC`, `IKA_MIN_OPEN_FILES`, `IKA_KERNEL_PAGE_SIZE` | `[system] stop_grace_sec`, `min_open_files`, `kernel_page_size` |

These have no setting:

| Variable | Effect |
| --- | --- |
| `CVD_HOME_DIR` | Ika's folder, `~/ika` by default, `ika.ini` included |
| `IKA_ROOT_BOOT_TIMEOUT_SEC` | Seconds `ika root` waits for each boot (default 900) |
| `IKA_NOTIFY=true` | Reports progress and errors as desktop notifications. The menu entries set it |
| `IKA_LATENCY=1` | The console logs its frames' latency to `~/ika/console.log` every 300 frames |
| `NO_COLOR` | `ika app` marks open windows "(open)" instead of bold |

## Windows (WSL2)

Ika runs in a WSL2 distribution (Fedora, Debian, Ubuntu or Arch, from the
Requirements) once the parts a fresh WSL2 lacks are in place: nested
virtualization (off by default, so there is no `/dev/kvm`), the vhost-vsock
and vhost-net devices (older Microsoft kernels are built without them, and
Cuttlefish's adb runs over vsock), systemd and cgroup v2. Microsoft's kernel
has no udmabuf, which Ika does without: it then starts with
`enable_gpu_udmabuf=false`. Without them
`ika start` ends with `process monitor has died` and `Cuttlefish did not
reach boot completion`, because crosvm exits at once.

`tools/ika-wsl-install.ps1` does all of it on a Windows with WSL 2.4.4 or
newer: it installs Debian 13 (trixie), the latest WSL image from
[salsa.debian.org](https://salsa.debian.org/debian/WSL/-/releases), as a
distribution named Ika, with Ika's icon in the Start menu and Windows
Terminal, a user named after the Windows user, with passwordless sudo, and
systemd; installs Mesa from trixie-backports and the `ika-base` and
`ika-lineageos` packages of Ika's latest release; runs `ika-wsl-setup`;
restarts WSL when its settings changed (it asks first, as that stops every
distribution); and starts Ika. It is one line in PowerShell:

```powershell
irm https://raw.githubusercontent.com/DesktopECHO/ika/main/tools/ika-wsl-install.ps1 | iex
```

Without WSL it installs WSL first and asks for a restart of Windows, after
which the same line goes on; an older WSL it updates. Options go after the
script block:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/DesktopECHO/ika/main/tools/ika-wsl-install.ps1))) -Force
```

`-Name` and `-UserName` choose other names, `-Location` where the
distribution's disk goes, `-Force` replaces a distribution of the same name
(deleting its files) and restarts WSL without asking, and `-NoStart` leaves
Ika stopped. Every WSL distribution runs in the same virtual machine, so run
one Ika at a time: stop Ika in any other distribution first.

`ika-wsl-setup`, installed with `ika-base`, reports what is missing
(`ika-wsl-setup --check`) and installs it: it enables nested virtualization
and cgroup v2 in `%USERPROFILE%\.wslconfig`, systemd in `/etc/wsl.conf`,
adds the user to Ika's groups, and when the kernel lacks the devices builds
Microsoft's WSL2 kernel at the running version with them built in, installs
it under `%USERPROFILE%\ika-wsl\` and points `.wslconfig` at it. The
build takes ten minutes to an hour and a few GB under `~/ika/wsl-kernel`
(`IKA_WSL_BUILD_DIR`); `--no-kernel` changes the configuration only and
`--kernel` builds the kernel anyway. Afterwards run `wsl --shutdown` from
Windows, open the distribution again and start Ika.

It also keeps the clock on Windows' time. WSL sets the clock from Windows
when it starts but nothing keeps it there, and a clock that is off makes
programs that pace themselves by it run fast or slow (WSLg's audio crackles
and plays slow). `ika-wsl-setup` installs chrony if it is missing and points
it at the Windows clock through Hyper-V's `/dev/ptp_hyperv`
(`/etc/chrony/conf.d/ika-wsl-hyperv.conf`, or `ika-wsl-hyperv.conf` beside
`chrony.conf` where chrony has no `confdir`), steps the clock whenever it is
more than a second off, lets Debian's and Ubuntu's chrony steer the clock in
WSL (`SYNC_IN_CONTAINER="yes"` in `/etc/default/chrony`) and stops
`systemd-timesyncd`. `--check` also reports a clock more than a second off
Windows' and a time zone other than Windows'; WSL takes the time zone from
Windows when it starts unless `useWindowsTimezone=false` is set in
`/etc/wsl.conf`. The GPU is reached
through WSL's `/dev/dxg` and Mesa's D3D12 drivers; if gfxstream fails on
them, `ika start --gpu_mode=guest_swiftshader` renders in software.

## Files and folders

Ika keeps its files in `~/ika`:

| Path | What it is |
| --- | --- |
| `ika.ini` | Settings |
| `app-options.ini` | The apps' start options, a section per app: `options =` and the window's display density, `dpi =` (96 to 999; none for the console's) |
| `apps/PACKAGE/` | An app window's size, title and log (`window.log`), and a game's `controller.ini` |
| `apps/icons/` | The icons of the apps in the desktop's menu |
| `apps/Chromium.apk`, `apps/Magisk-*.apk` | Downloads kept for new devices and for `ika root` |
| `ika-backup-*.tgz` | Backups |
| `ikastart.log` | The log of each start |
| `console.log` | The console's log, from its last launch |
| `app-menu.log` | The app menu watcher's log |
| `madbfs.log` | The log of the Android files mount |
| `cuttlefish/instances/cvd-1/` | The VM: its disk overlay and Cuttlefish's logs (`logs/launcher.log`, `kernel.log`, `logcat`) |
| `data-gb`, `serial-number` | The data partition size and the device's serial number |
| `tmp/` | Locks, process IDs and working folders |

Android's files are mounted on `$XDG_RUNTIME_DIR/ika/Android` while Android
runs (`~/ika/Android` without a runtime folder).

On the desktop, the app menu entries are `ika-PACKAGE.desktop` files in
`~/.local/share/applications`, grouped by
`~/.local/share/desktop-directories/ika-android-apps.directory` and
`~/.config/menus/applications-merged/ika-android-apps.menu`, or in GNOME by
the `ika-android-apps` app folder.
