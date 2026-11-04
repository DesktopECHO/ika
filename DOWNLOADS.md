[README](README.md) | [Using Ika](USAGE.md) | [Configuration](CONFIGURATION.md) | [Graphics](GRAPHICS.md) | [Building](BUILDING.md) | **Downloads**

# Downloads (Updated 2026-11-04)

Ika is two packages: `ika-base`, the application, and `ika-lineageos`, the
Android disk image. Download both for your distribution and architecture,
then install them as the [README](README.md#install) shows. On Windows, the
installer downloads and installs them: see [Windows (WSL2)](#windows-wsl2)
below.

> [!NOTE]
> Debian and Ubuntu need Mesa 26.1 or newer, from [Debian trixie-backports](https://backports.debian.org/Instructions/) or the [Kisak Mesa PPA](https://launchpad.net/~kisak/+archive/ubuntu/kisak-mesa), before the Ika packages are installed.

| **Distribution • Architecture** | **Application** | **Disk Image** |
| --- | --- | --- |
|  |  |  |
| Fedora 44 • x86_64 | [ika-base (184 MB)](https://github.com/DesktopECHO/ika/releases/download/261101/ika-base-261101-1.fc44.x86_64.rpm) | [ika-lineageos (1.47 GB)](https://github.com/DesktopECHO/ika/releases/download/261101/ika-lineageos-261101-1.fc44.x86_64.rpm) |
|  |  |  |
| Fedora 44 • ARM64 | [ika-base (174 MB)](https://github.com/DesktopECHO/ika/releases/download/261101/ika-base-261101-1.fc44.aarch64.rpm) | [ika-lineageos (1.46 GB)](https://github.com/DesktopECHO/ika/releases/download/261101/ika-lineageos-261101-1.fc44.aarch64.rpm) |
|  |  |  |
| Debian 13 / Ubuntu 26.04  •  x86_64 | [ika-base (129 MB)](https://github.com/DesktopECHO/ika/releases/download/261101/ika-base_261101-1_amd64.deb) | [ika-lineageos (1.41 GB)](https://github.com/DesktopECHO/ika/releases/download/261101/ika-lineageos_261101-1_amd64.deb) |
|  |  |  |
| Debian 13 / Ubuntu 26.04 • ARM64 | [ika-base (109 MB)](https://github.com/DesktopECHO/ika/releases/download/261101/ika-base_261101-1_arm64.deb) | [ika-lineageos (1.38 GB)](https://github.com/DesktopECHO/ika/releases/download/261101/ika-lineageos_261101-1_arm64.deb) |
|  |  |  |
| Arch Linux • x86_64 | [ika-base (213 MB)](https://github.com/DesktopECHO/ika/releases/download/261101/ika-base-261101-1-x86_64.pkg.tar.zst) | [ika-lineageos (1.67 GB)](https://github.com/DesktopECHO/ika/releases/download/261101/ika-lineageos-261101-1-x86_64.pkg.tar.zst) |
|  |  |  |
| Arch Linux • ARM64 | [ika-base (129 MB)](https://github.com/DesktopECHO/ika/releases/download/261101/ika-base-261101-1-aarch64.pkg.tar.xz) | [ika-lineageos (1.38 GB)](https://github.com/DesktopECHO/ika/releases/download/261101/ika-lineageos-261101-1-aarch64.pkg.tar.xz) |

To choose the ROM's Google integration, build from source: see
[Building](BUILDING.md).

## Windows (WSL2)

On an x86-64 Windows PC, Ika runs in a WSL2 distribution, and `ika-wsl.ps1`
sets it up. Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/DesktopECHO/ika/main/ika-wsl.ps1 | iex
```

The installer handles the rest, with no download of yours: the Debian 13
packages, `ika-base` and `ika-lineageos`, come from the latest release (over
a gigabyte) into `%TEMP%`, and a run that finds them there already uses
them. On any other kind of PC it stops before it changes anything. It adds what WSL2 needs of Windows and is missing (the WSL
package, the Virtual Machine Platform and Windows' hypervisor) behind one
permission prompt; if Windows must restart, it says so: restart, then run the
same line again. If virtualization is off in the PC's firmware, it tells you
to turn on SVM Mode (AMD) or Intel Virtualization Technology in the UEFI/BIOS
settings. It then installs Debian 13 as a distribution named Ika, with a user
named after your Windows user, installs Mesa 26.1 or newer and the two
packages in it, readies WSL for Ika, and starts Ika, whose console opens in a
window. Allow a few minutes. Later, start Ika from the Start menu, or from
PowerShell with `wsl -d Ika -- ika start`.

[Windows (WSL2)](CONFIGURATION.md#windows-wsl2) in the Configuration guide
describes what the installer changes and its options.
