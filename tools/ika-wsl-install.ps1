<#
.SYNOPSIS
Deploys Ika on Windows: a WSL2 Debian 13 (trixie) distribution named Ika,
readied for Ika, with the Ika packages in your Windows home folder installed,
then starts Android.

.DESCRIPTION
Installs Debian's WSL image, the latest from salsa.debian.org, under the name
Ika, with Ika's icon for its Start menu entry and Terminal profile, and in it:
  1. creates a user (named after the Windows user) with passwordless sudo,
     the default user of the distribution, with systemd on;
  2. installs Mesa from trixie-backports (Ika needs 26.1 or newer) and the
     ika-base and ika-lineageos packages (.deb) in -PackageDirectory, the
     newest version of each for the distribution's architecture;
  3. runs ika-wsl-setup, from the package, which readies WSL for Ika: nested
     virtualization, cgroup v2, the groups, the Start menu, the clock;
  4. restarts the distribution, or all of WSL when ika-wsl-setup changed
     .wslconfig (asked first, as that stops every running distribution);
  5. starts Ika, whose console opens in a window.

Run it from PowerShell, in one line:
  irm https://raw.githubusercontent.com/DesktopECHO/ika/main/tools/ika-wsl-install.ps1 | iex
or, with options:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/DesktopECHO/ika/main/tools/ika-wsl-install.ps1))) -Force

.PARAMETER Name
The distribution's name. Default: Ika.

.PARAMETER UserName
The Linux user. Default: the Windows user name, lowercased.

.PARAMETER Location
Where WSL keeps the distribution's disk. Default: WSL's own choice.

.PARAMETER PackageDirectory
The folder holding the ika-base and ika-lineageos packages
(ika-base_VERSION_ARCH.deb, ika-lineageos_VERSION_ARCH.deb). Default: your
Windows home folder (%USERPROFILE%).

.PARAMETER Force
Replaces a distribution of the same name, deleting its files, and restarts
WSL without asking when that is needed.

.PARAMETER NoStart
Installs everything but does not start Ika.
#>
[CmdletBinding()]
param(
    [string]$Name = 'Ika',
    [string]$UserName,
    [string]$Location,
    [string]$PackageDirectory = $env:USERPROFILE,
    [switch]$Force,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
# Invoke-WebRequest's progress bar slows downloads to a crawl
$ProgressPreference = 'SilentlyContinue'
# wsl.exe writes UTF-16 to a pipe unless told otherwise
$env:WSL_UTF8 = '1'

function Write-Step([string]$Text, [switch]$NoNewline) {
    # A middle dot, written as a code point: Windows PowerShell reads a script
    # without a byte order mark as Windows-1252
    Write-Host "$([char]0x00B7) $Text" -ForegroundColor Cyan -NoNewline:$NoNewline
}

function Invoke-Wsl {
    & wsl.exe @args
    if ($LASTEXITCODE -ne 0) {
        throw "wsl.exe $($args -join ' ') failed (exit code $LASTEXITCODE)"
    }
}

# The Linux half of the work, run by phase (see Invoke-Provision)
$Provision = @'
set -euo pipefail

phase="$1"
user="$2"
export DEBIAN_FRONTEND=noninteractive

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

case "${phase}" in
  user)
    # Debian's first-run prompt (/usr/lib/wsl/oobe.sh) skips itself once a
    # user with UID 1000 exists
    if ! getent passwd "${user}" >/dev/null; then
      if getent passwd 1000 >/dev/null; then
        die "UID 1000 is taken by $(getent passwd 1000 | cut -d: -f1)"
      fi
      useradd --create-home --uid 1000 --shell /bin/bash \
        --groups adm,cdrom,sudo,dip,plugdev "${user}"
    fi
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "${user}" >/etc/sudoers.d/90-ika-user
    chmod 0440 /etc/sudoers.d/90-ika-user
    printf '[boot]\nsystemd=true\n\n[user]\ndefault=%s\n' "${user}" >/etc/wsl.conf
    ;;

  install)
    . /etc/os-release
    [[ "${VERSION_CODENAME:-}" == trixie ]] \
      || die "the distribution is ${PRETTY_NAME:-unknown}, not Debian 13 (trixie)"
    # Debian's WSL image lists trixie-backports already
    if ! grep -qs 'trixie-backports' /etc/apt/sources.list /etc/apt/sources.list.d/*; then
      keyring=/usr/share/keyrings/debian-archive-keyring.pgp
      [[ -e "${keyring}" ]] || keyring=/usr/share/keyrings/debian-archive-keyring.gpg
      printf 'Types: deb\nURIs: http://deb.debian.org/debian\nSuites: trixie-backports\nComponents: main\nSigned-By: %s\n' \
        "${keyring}" >/etc/apt/sources.list.d/trixie-backports.sources
    fi
    arch="$(dpkg --print-architecture)"
    # -PackageDirectory, as a Linux path (WSLENV's /p)
    dir="${IKA_PACKAGE_DIR:-}"
    [[ -d "${dir}" ]] || die "the package folder ${dir:-(not given)} cannot be reached from WSL"
    debs=()
    for package in ika-base ika-lineageos; do
      deb="$(find "${dir}" -maxdepth 1 -name "${package}_*_${arch}.deb" | sort -V | tail -n 1)"
      [[ -n "${deb}" ]] || die "${dir} has no ${package} package for ${arch}"
      printf 'Installing %s\n' "${deb##*/}"
      debs+=("${deb}")
    done

    apt-get update
    # One fetch and one transaction: the distribution's updates, Mesa from
    # trixie-backports, Ika's packages and chrony for the clock (below). Ika needs Mesa 26.1 or newer, which
    # trixie has only in backports. NAME/trixie-backports takes these from
    # there alone, where -t would move every installed package that has a
    # backports version; of the rest, Mesa needs only mesa-libgallium from
    # there, at its exact version. SUDO_USER tells ika-base whom to add to
    # Ika's groups.
    SUDO_USER="${user}" apt-get -y --no-install-recommends full-upgrade \
      curl ca-certificates chrony \
      libegl-mesa0/trixie-backports libgbm1/trixie-backports libgl1-mesa-dri/trixie-backports \
      libglx-mesa0/trixie-backports mesa-vulkan-drivers/trixie-backports \
      mesa-libgallium/trixie-backports \
      "${debs[@]}"
    usermod -aG kvm,cvdnetwork,render,video "${user}"

    # The Windows Start menu reads Linux apps from the system's applications
    # directories only, and Ika writes its Android apps' launchers to the
    # user's: link this one to it, as ika-wsl-setup would, unless it is in use
    home="$(getent passwd "${user}" | cut -d: -f6)"
    apps="${home}/.local/share/applications"
    install -d -o "${user}" -g "${user}" "${home}/.local" "${home}/.local/share" "${apps}"
    system_apps=/usr/local/share/applications
    if [[ ! -e "${system_apps}" && ! -L "${system_apps}" ]] || rmdir "${system_apps}" 2>/dev/null; then
      mkdir -p "${system_apps%/*}"
      ln -s "${apps}" "${system_apps}"
    fi

    # Two more of ika-wsl-setup's fixes need nothing from Windows: make them
    # with its own code, so that the next step does not report them missing.
    # FUSE's user_allow_other lets Windows open Android's storage; chrony
    # keeps the clock on Windows' through Hyper-V's PTP device.
    if setup="$(command -v ika-wsl-setup)"; then
      (
        . "${setup}"
        fuse_allows_other || enable_fuse_allow_other
        [[ ! -e "${HYPERV_PTP_DEVICE}" ]] || time_sync_in_place || setup_time_sync
      )
    fi
    ;;

  setup)
    if command -v ika-wsl-setup >/dev/null; then
      # Never builds a kernel; its report says when one is needed
      ika-wsl-setup --no-kernel
    else
      printf 'This Ika release has no ika-wsl-setup; skipping it\n'
    fi
    ;;

  *)
    die "unknown phase ${phase}"
    ;;
esac
'@

# Runs a phase of $Provision in the distribution, as root or as the user,
# showing its output and returning it; a failure throws unless -NoThrow.
# With -Dots the output is shown as a dot for every 100 lines, and its last
# lines only if the phase fails.
function Invoke-Provision([string]$Phase, [string]$As, [switch]$NoThrow, [switch]$Dots) {
    # Windows PowerShell turns a native command's stderr into errors, which
    # would stop the script at apt's first progress line
    $ErrorActionPreference = 'Continue'
    $script = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Provision.Replace("`r`n", "`n")))
    $lines = New-Object System.Collections.Generic.List[string]
    & wsl.exe -d $Name -u $As --exec bash -c "echo $script | base64 -d | bash -s -- $Phase $UserName" 2>&1 |
        ForEach-Object {
            $lines.Add("$_")
            if (-not $Dots) {
                Write-Host $_
            } elseif ($lines.Count % 100 -eq 0) {
                Write-Host '.' -NoNewline
            }
        }
    $exitCode = $LASTEXITCODE
    if ($Dots) {
        Write-Host ''
        if ($exitCode -ne 0) {
            $lines | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
        }
    }
    if ($exitCode -ne 0) {
        if (-not $NoThrow) { throw "Setting up $Name failed in its '$Phase' step (exit code $exitCode)" }
        Write-Warning "The '$Phase' step reported a problem; see its output above."
    }
    $lines
}

# Downloads the newest Debian WSL image for this machine from Debian's
# releases on salsa.debian.org; returns its path
function Get-DebianImage([string]$Directory) {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'AMD64' }
    # Windows' curl.exe: salsa.debian.org answers PowerShell's web client with
    # a bot challenge. The releases come newest first.
    $json = & curl.exe -fsSL 'https://salsa.debian.org/api/v4/projects/debian%2FWSL/releases?per_page=1'
    if ($LASTEXITCODE -ne 0) { throw "Could not read Debian's WSL releases (curl exit code $LASTEXITCODE)" }
    $release = @(($json -join "`n") | ConvertFrom-Json)[0]
    $asset = $release.assets.links | Where-Object { $_.name -like "Debian_WSL_${arch}_*.wsl" } | Select-Object -First 1
    if (-not $asset) { throw "Debian's WSL release $($release.tag_name) has no image for $arch" }
    $path = Join-Path $Directory $asset.name
    Write-Host "Downloading $($asset.name)"
    & curl.exe -fL --retry 3 -o $path $asset.url
    if ($LASTEXITCODE -ne 0) { throw "Could not download $($asset.url) (curl exit code $LASTEXITCODE)" }
    return $path
}

# Gives the distribution's Start menu entry and Terminal profile Ika's icon:
# WSL copied the image's to shortcut.ico beside its disk, where both point
function Set-DistributionIcon {
    $key = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' |
        Where-Object { (Get-ItemProperty $_.PSPath).DistributionName -eq $Name } | Select-Object -First 1
    if (-not $key) { return }
    $target = Join-Path (Get-ItemProperty $key.PSPath).BasePath 'shortcut.ico'
    # A checkout's own copy; none when run as a one-liner (irm ... | iex)
    $local = if ($PSScriptRoot) { Join-Path $PSScriptRoot '..\scrcpy\app\data\icon.ico' }
    if ($local -and (Test-Path -LiteralPath $local)) {
        Copy-Item -LiteralPath $local -Destination $target -Force
    } else {
        Invoke-WebRequest -UseBasicParsing -OutFile $target `
            -Uri 'https://raw.githubusercontent.com/DesktopECHO/ika/main/scrcpy/app/data/icon.ico'
    }
}

# Sets nestedVirtualization=true in .wslconfig's [wsl2]; true when it changed
function Enable-NestedVirtualization {
    $path = Join-Path $env:USERPROFILE '.wslconfig'
    $lines = @()
    if (Test-Path -LiteralPath $path) { $lines = @(Get-Content -LiteralPath $path) }
    $out = New-Object System.Collections.Generic.List[string]
    $section = ''
    $done = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*\[(.+?)\]\s*$') {
            if ($section -eq 'wsl2' -and -not $done) { $out.Add('nestedVirtualization=true'); $done = $true }
            $section = $Matches[1].ToLower()
        } elseif ($section -eq 'wsl2' -and $line -match '^\s*nestedVirtualization\s*=') {
            if ($line -match '=\s*true\s*$') { return $false }
            $line = 'nestedVirtualization=true'
            $done = $true
        }
        $out.Add($line)
    }
    if (-not $done) {
        if ($section -ne 'wsl2') { $out.Add('[wsl2]') }
        $out.Add('nestedVirtualization=true')
    }
    Set-Content -LiteralPath $path -Value $out
    return $true
}

# --- Checks ---------------------------------------------------------------

# Windows' own wsl.exe, without WSL installed, knows no --version
$versionText = ''
if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    $versionText = (& wsl.exe --version 2>$null) -join "`n"
}
if ($versionText -notmatch 'WSL[^:\n]*:\s*(\d+)\.(\d+)\.(\d+)') {
    Write-Step 'Installing WSL (Windows asks for permission)'
    & wsl.exe --install --no-distribution
    Write-Host 'Restart Windows to finish installing WSL, then run this again.'
    return
}
$wslVersion = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
if ($wslVersion -lt [version]'2.4.4') {
    # 2.4.4 installs a distribution under a name of its own
    Write-Step "Updating WSL $wslVersion"
    Invoke-Wsl --update
    if (((& wsl.exe --version 2>$null) -join "`n") -notmatch 'WSL[^:\n]*:\s*(\d+)\.(\d+)\.(\d+)' -or
            [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])" -lt [version]'2.4.4') {
        throw 'WSL is still older than 2.4.4 after "wsl --update"; update it from the Microsoft Store and run this again.'
    }
}

if (-not $UserName) {
    $UserName = $env:USERNAME.ToLower() -replace '[^a-z0-9_-]', ''
    if ($UserName -notmatch '^[a-z_]') { $UserName = "ika$UserName" }
}
if ($UserName -notmatch '^[a-z_][a-z0-9_-]{0,31}$' -or $UserName -eq 'root') {
    throw "'$UserName' cannot be a Linux user name; pass one with -UserName"
}

# The packages, checked before anything is installed
$PackageDirectory = (Resolve-Path -LiteralPath $PackageDirectory).ProviderPath
foreach ($package in 'ika-base', 'ika-lineageos') {
    if (-not (Get-ChildItem -LiteralPath $PackageDirectory -Filter "${package}_*.deb" -File)) {
        throw "$PackageDirectory has no $package package (${package}_VERSION_ARCH.deb); pass the folder with -PackageDirectory"
    }
}
# The install step reads them from there, as a Linux path (WSLENV's /p)
$env:IKA_PACKAGE_DIR = $PackageDirectory
$env:WSLENV = (@($env:WSLENV, 'IKA_PACKAGE_DIR/p') | Where-Object { $_ }) -join ':'

$existing = @(& wsl.exe --list --quiet 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($existing -contains $Name) {
    if (-not $Force) {
        throw "A distribution named $Name exists. Pass -Force to replace it (its files are deleted), or -Name for another name."
    }
    # Unregistering ends Ika's processes without their cleanup. The network
    # bridge of its Android lives on in the network stack WSL's distributions
    # share, without the DHCP server that went with the distribution, and the
    # next Ika, finding the bridge, starts none: its Android got no address.
    Write-Step 'Stopping old Ika instance'
    & wsl.exe -d $Name --exec sh -c 'command -v ika >/dev/null 2>&1 && ika stop >/dev/null 2>&1; true'
    Write-Step 'Removing old Ika instance'
    Invoke-Wsl --unregister $Name
}

# --- Install --------------------------------------------------------------

Write-Step 'Installing Debian base'
$download = Join-Path $env:TEMP "ika-wsl-install-$PID"
New-Item -ItemType Directory -Force -Path $download | Out-Null
try {
    $image = Get-DebianImage $download
    $install = @('--install', '--from-file', $image, '--name', $Name, '--no-launch')
    if ($Location) { $install += @('--location', $Location) }
    Invoke-Wsl @install
} finally {
    Remove-Item -LiteralPath $download -Recurse -Force -ErrorAction SilentlyContinue
}
try {
    Set-DistributionIcon
} catch {
    Write-Warning "Could not give $Name Ika's icon: $_"
}

Write-Step "Creating the user $UserName and turning on systemd"
Invoke-Provision user root | Out-Null
Invoke-Wsl --terminate $Name

# The dots of the install step follow on the same line
Write-Step 'Installing Debian packages, this will take a few minutes...' -NoNewline
Invoke-Provision install root -Dots | Out-Null

$restartWsl = $false
& wsl.exe -d $Name -u root --exec test -e /dev/kvm
if ($LASTEXITCODE -ne 0) {
    # No /dev/kvm: WSL runs without nested virtualization
    if (Enable-NestedVirtualization) {
        Write-Host "Turned on nested virtualization in $env:USERPROFILE\.wslconfig"
        $restartWsl = $true
    } else {
        Write-Warning 'There is no /dev/kvm although nested virtualization is on: the CPU or Windows may not support it.'
    }
}

Write-Step 'Readying WSL for Ika (ika-wsl-setup)'
$setupOutput = Invoke-Provision setup $UserName -NoThrow
if (($setupOutput -join "`n") -match 'wsl --shutdown') { $restartWsl = $true }

if ($restartWsl) {
    Write-Step 'WSL must restart for its new settings, which stops every running distribution'
    if (-not $Force) {
        $answer = Read-Host 'Restart WSL now? [Y/n]'
        if ($answer -and $answer -notmatch '^[Yy]') {
            Write-Host "Run ""wsl --shutdown"" when you can, then ""wsl -d $Name -- ika start""."
            return
        }
    }
    Write-Host 'Restarting WSL...'
    Invoke-Wsl --shutdown
} else {
    # The groups and services take effect at the distribution's next start
    Invoke-Wsl --terminate $Name
}

if ($NoStart) {
    Write-Step "Install complete, start Ika with: wsl -d $Name -- ika start"
    return
}

Write-Step 'Starting Ika, first run takes a moment'
& wsl.exe -d $Name --cd '~' -- ika start
if ($LASTEXITCODE -ne 0) {
    throw "Ika did not start; its log is ~/ika/ikastart.log in $Name"
}
Write-Step 'Install complete, start menu updated'
