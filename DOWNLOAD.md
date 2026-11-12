[README](README.md)&nbsp; • &nbsp;**Download**&nbsp; • &nbsp;[Using Ika](USAGE.md)&nbsp; • &nbsp;[Configuration](CONFIGURATION.md)&nbsp; • &nbsp;[Graphics](GRAPHICS.md)&nbsp; • &nbsp;[Building](BUILDING.md)

# Download (Updated 2026-11-12)

Ika installs two packages: `ika-base` is the emulator app, and `ika-lineageos` is the
Android disk image (also known as "The ROM"). Download both for your distribution and architecture. and install them with your package manager. 

On Windows, the install script downloads and installs Ika automatically, see [Windows (WSL2)](#windows-wsl2) below.

> [!NOTE]
> Debian and Ubuntu require Mesa 26.1 or newer, from [Debian trixie-backports](https://backports.debian.org/Instructions/) or the [Kisak Mesa PPA](https://launchpad.net/~kisak/+archive/ubuntu/kisak-mesa), before the Ika packages can be installed.

| **Distribution • Architecture** | **Application** | **Disk Image** |
| --- | --- | --- |
|  |  |  |
| Fedora 44 • x86_64 | [ika-base (183 MB)](https://github.com/DesktopECHO/ika/releases/download/261111/ika-base-261111-1.fc44.x86_64.rpm) | [ika-lineageos (1.47 GB)](https://github.com/DesktopECHO/ika/releases/download/261111/ika-lineageos-261111-1.fc44.x86_64.rpm) |
|  |  |  |
| Fedora 44 • ARM64 | [ika-base (174 MB)](https://github.com/DesktopECHO/ika/releases/download/261111/ika-base-261111-1.fc44.aarch64.rpm) | [ika-lineageos (1.44 GB)](https://github.com/DesktopECHO/ika/releases/download/261111/ika-lineageos-261111-1.fc44.aarch64.rpm) |
|  |  |  |
| Debian 13 / Ubuntu 26.04  •  x86_64 | [ika-base (129 MB)](https://github.com/DesktopECHO/ika/releases/download/261111/ika-base_261111-1_amd64.deb) | [ika-lineageos (1.41 GB)](https://github.com/DesktopECHO/ika/releases/download/261111/ika-lineageos_261111-1_amd64.deb) |
|  |  |  |
| Debian 13 / Ubuntu 26.04 • ARM64 | [ika-base (109 MB)](https://github.com/DesktopECHO/ika/releases/download/261111/ika-base_261111-1_arm64.deb) | [ika-lineageos (1.37 GB)](https://github.com/DesktopECHO/ika/releases/download/261111/ika-lineageos_261111-1_arm64.deb) |
|  |  |  |
| Arch Linux • x86_64 | [ika-base (213 MB)](https://github.com/DesktopECHO/ika/releases/download/261111/ika-base-261111-1-x86_64.pkg.tar.zst) | [ika-lineageos (1.67 GB)](https://github.com/DesktopECHO/ika/releases/download/261111/ika-lineageos-261111-1-x86_64.pkg.tar.zst) |
|  |  |  |
| Arch Linux • ARM64 | [ika-base (129 MB)](https://github.com/DesktopECHO/ika/releases/download/261111/ika-base-261111-1-aarch64.pkg.tar.xz) | [ika-lineageos (1.37 GB)](https://github.com/DesktopECHO/ika/releases/download/261111/ika-lineageos-261111-1-aarch64.pkg.tar.xz) |

To choose the ROM's Google integration, build from source: see
[Building](BUILDING.md).

## Windows (WSL2)

On an x86-64 Windows PC, Ika runs in a WSL2 distribution, and `ika-wsl.ps1`
sets it up. In PowerShell, download the install script:

```powershell
irm https://raw.githubusercontent.com/DesktopECHO/ika/main/ika-wsl.ps1 -OutFile ika-wsl.ps1
```

Then run it:

```powershell
.\ika-wsl.ps1
```

Windows may refuse to run the saved file because of the execution policy.
If it does, start it like this, with any options after it:

```powershell
powershell -ExecutionPolicy Bypass -File .\ika-wsl.ps1
```

The installer handles the rest.  It readies WSL for Ika, installs Debian 13, `ika-base` and `ika-lineageos`, Mesa 26.1, and starts Ika.  [Windows (WSL2)](CONFIGURATION.md#windows-wsl2) in the Configuration guide describes what the installer changes and its options.
