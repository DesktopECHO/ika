**README** | [Using Ika](USAGE.md) | [Configuration](CONFIGURATION.md) | [Graphics](GRAPHICS.md) | [Building](BUILDING.md) | [Downloads](DOWNLOADS.md) | [Changelog](CHANGELOG.md)

<img width="1920" height="1080" alt="Ika Virtual Desktop" src="https://github.com/user-attachments/assets/ad0213c3-6a9d-45bc-9468-dcdd82abca26" />

# イカ · Ika Virtual Desktop

**Ika** _/ee-kah/_, Japanese for squid or cuttlefish, runs Android on your
Linux desktop: LineageOS 23.2 (Android 16), built as a desktop operating
system, in a [Cuttlefish](https://source.android.com/setup/create/cuttlefish)
virtual machine, with its apps in windows of their own.

## Features

- **A desktop Android:** LineageOS 23.2 with resizable app windows, a taskbar
  and split screen, and a TV mode with Android TV's interface.
- **The console:** Android's desktop in a window of your Linux desktop. Its
  display follows the window's size at the host's density, pixel for pixel.
- **App windows:** each Android app can open in a window of its own, from your
  desktop's app menu, where Ika lists every Android app.
- **Start options per app:** the window's display density, fullscreen, the
  keyboard, the mouse and gamepads passed through to Android, the keyboard as
  a gamepad, and touch input.
- **GPU acceleration:** OpenGL ES 3.2 and Vulkan on the host's GPU, through
  gfxstream.
- **Your files:** Android's storage is mounted on the host, in the file
  manager's sidebar, while Ika runs.
- **Camera:** a webcam, or a Mac's FaceTime camera, as Android's camera.
- **Backups:** your apps, files and settings, saved and restored with one
  command.
- **Root:** `ika root` roots Android with Magisk.
- **Your choice of Google:** builds with microG, with MindTheGapps (Google
  Play), or with no Google services at all.
- **Many hosts:** x86-64 and ARM64, Apple Silicon included, on Fedora,
  Debian, Ubuntu and Arch Linux, in X11 and Wayland sessions.

## Requirements

- An x86-64 or ARM64 computer with hardware virtualization (KVM), and 4 GB of
  memory or more.
- Fedora 44, Debian 13, Ubuntu 26.04 or Arch Linux. On Apple Silicon, Fedora
  Asahi Remix with its 16 KB-page kernel.
- Mesa 26.1 or newer. Debian 13 gets it from
  [trixie-backports](https://backports.debian.org/Instructions/), Ubuntu from
  the [Kisak Mesa PPA](https://launchpad.net/~kisak/+archive/ubuntu/kisak-mesa);
  Fedora 44 and Arch Linux have it.
- A GPU with a Vulkan driver, for the best performance. Without one, Ika
  renders with the CPU's software driver and runs in a lighter
  [low-CPU mode](CONFIGURATION.md#low-cpu-mode).

## Install

1. Download `ika-base` and `ika-lineageos` for your distribution and
   architecture from the [Downloads](DOWNLOADS.md) page, or
   [build them from source](BUILDING.md).
2. Install both:

   ```bash
   # Fedora
   sudo dnf install ./ika-base-*.rpm ./ika-lineageos-*.rpm
   # Debian, Ubuntu
   sudo apt install ./ika-base_*.deb ./ika-lineageos_*.deb
   # Arch Linux
   sudo pacman -U ./ika-base-*.pkg.tar.zst ./ika-lineageos-*.pkg.tar.zst
   ```

3. Reboot after the first install. The packages add you to the `kvm`,
   `cvdnetwork`, `render` and `video` groups and set up the host's devices and
   limits, which take effect at the next boot; logging out is not enough.
   Updates need no reboot.
4. Start Ika from your desktop's app menu, or with `ika start`.

## First steps

- `ika start` boots Android and opens the console, Android's desktop in a
  window. The first start takes longer, as Android sets itself up.
- Your Android apps appear in your desktop's app menu under
  **Android Apps (Ika)**. Each opens in a window of its own; right-click one
  for its **Startup options**.
- `ika stop` stops Android, and `ika help` lists every command.

[Using Ika](USAGE.md) explains the console, app windows, input and gamepads,
TV mode and the everyday commands.

## Documentation

| Page | Contents |
| --- | --- |
| [Using Ika](USAGE.md) | The console, app windows, start options, keyboard, mouse and gamepads, TV mode, files, camera, apps, backups, root |
| [Configuration](CONFIGURATION.md) | Every command and option, `ika.ini`, environment variables, defaults, files |
| [Graphics](GRAPHICS.md) | GPU modes, Vulkan, Apple Silicon, graphics troubleshooting |
| [Building](BUILDING.md) | Building the ROM and the packages from source, on x86-64 and ARM64 |
| [Downloads](DOWNLOADS.md) | Prebuilt packages |
| [Changelog](CHANGELOG.md) | Changes in each release |
| [lineageos/README.md](lineageos/README.md) | The LineageOS Desktop ROM: its products, source layout and build |
| [scrcpy/IKA.md](scrcpy/IKA.md) | Ika's changes to scrcpy, the console's client |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute |

<img width="1920" height="1080" alt="Ika screenshot" src="https://github.com/user-attachments/assets/c63c8d08-d11b-4ec0-956a-d2c0220b963a" />
