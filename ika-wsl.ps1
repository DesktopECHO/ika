<#
.SYNOPSIS
Deploys Ika on Windows: a WSL2 Debian 13 (trixie) distribution named Ika,
readied for Ika, with the Ika packages in your Windows home folder installed,
then starts Android.

.DESCRIPTION
Sets up what WSL2 needs of Windows and is missing (the WSL package, the
Virtual Machine Platform, Windows' hypervisor) behind one permission prompt,
asking for a restart when one is needed, a single one; WSL 1 stays off.
Then installs Debian's WSL image, the latest from salsa.debian.org, under the
name Ika, with Ika's icon for its Start menu entry and Terminal profile, and
in it:
  1. creates a user (named after the Windows user) with passwordless sudo,
     the default user of the distribution, with systemd on;
  2. installs Mesa from trixie-backports (Ika needs 26.1 or newer) and the
     ika-base and ika-lineageos packages (.deb) in -PackageDirectory, the
     newest version of each for the distribution's architecture;
  3. runs ika-wsl-setup, from the package, which readies WSL for Ika: nested
     virtualization, cgroup v2, the groups, the Start menu, the clock, the
     devices' groups; then asks it what is still missing, and warns of
     anything a restart of WSL does not bring;
  4. restarts the distribution, or all of WSL when ika-wsl-setup changed
     .wslconfig (asked first, as that stops every running distribution);
  5. starts Ika, whose console opens in a window. Run outside the desktop
     (Windows' session 0, over SSH for one), it stops WSL instead, unless
     WSLg already runs on a desktop, and leaves Ika to start there.

Run it from PowerShell, in one line:
  irm https://raw.githubusercontent.com/DesktopECHO/ika/main/ika-wsl.ps1 | iex
or, with options:
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/DesktopECHO/ika/main/ika-wsl.ps1))) -Force

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

# Runs one of wsl.exe's own commands (--install, --terminate, --shutdown...),
# showing what it says ("The operation completed successfully.") only when it
# fails
function Invoke-Wsl {
    # Windows PowerShell turns a native command's stderr into errors
    $ErrorActionPreference = 'Continue'
    $output = & wsl.exe @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        $output | ForEach-Object { Write-Host "$_" }
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
    # WSL runs Debian's first-run prompt (/usr/lib/wsl/oobe.sh) at the first
    # shell started without a command. With a user of UID 1000 it creates
    # none, but says "User account already exists, skipping creation". Without
    # the command WSL marks its first run done in silence.
    if [[ -f /etc/wsl-distribution.conf ]]; then
      sed -i '/^\[oobe\]/,/^\[/{/^[[:space:]]*command[[:space:]]*=/d}' /etc/wsl-distribution.conf
    fi
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

  check)
    # What ika-wsl-setup finds missing, a NAME<TAB>reason line each
    if setup="$(command -v ika-wsl-setup)"; then
      ( . "${setup}"; missing_components )
    fi
    ;;

  *)
    die "unknown phase ${phase}"
    ;;
esac
'@

# Runs a phase of $Provision in the distribution, as root or as the user,
# showing its output and returning it; a failure throws unless -NoThrow.
# With -Dots the output is shown as a dot for every 100 lines, with -Quiet
# not at all, and either way its last lines if the phase fails.
function Invoke-Provision([string]$Phase, [string]$As, [switch]$NoThrow, [switch]$Dots, [switch]$Quiet) {
    # Windows PowerShell turns a native command's stderr into errors, which
    # would stop the script at apt's first progress line
    $ErrorActionPreference = 'Continue'
    $script = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Provision.Replace("`r`n", "`n")))
    $lines = New-Object System.Collections.Generic.List[string]
    & wsl.exe -d $Name -u $As --exec bash -c "echo $script | base64 -d | bash -s -- $Phase $UserName" 2>&1 |
        ForEach-Object {
            $lines.Add("$_")
            if ($Dots) {
                if ($lines.Count % 100 -eq 0) { Write-Host '.' -NoNewline }
            } elseif (-not $Quiet) {
                Write-Host $_
            }
        }
    $exitCode = $LASTEXITCODE
    if ($Dots) { Write-Host '' }
    if (($Dots -or $Quiet) -and $exitCode -ne 0) {
        $lines | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
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

# The version of the WSL package, or $null without it: Windows' own wsl.exe,
# which stands in for it until it is installed, knows no --version
function Get-WslVersion {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $null }
    $text = (& wsl.exe --version 2>$null) -join "`n"
    if ($text -notmatch 'WSL[^:\n]*:\s*(\d+)\.(\d+)\.(\d+)') { return $null }
    return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
}

# Downloads the newest WSL package (.msi) for this machine from WSL's
# releases on GitHub; returns its path. The Microsoft Store's is the same
# package; the .msi installs without the Store, and without WSL 1.
function Get-WslPackage([string]$Directory) {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $json = & curl.exe -fsSL 'https://api.github.com/repos/microsoft/WSL/releases/latest'
    if ($LASTEXITCODE -ne 0) { throw "Could not read WSL's releases (curl exit code $LASTEXITCODE)" }
    $release = ($json -join "`n") | ConvertFrom-Json
    $asset = $release.assets | Where-Object { $_.name -like "wsl.*.$arch.msi" } | Select-Object -First 1
    if (-not $asset) { throw "WSL's release $($release.tag_name) has no package for $arch" }
    $path = Join-Path $Directory $asset.name
    Write-Host "Downloading $($asset.name)"
    & curl.exe -fL --retry 3 -o $path $asset.browser_download_url
    if ($LASTEXITCODE -ne 0) { throw "Could not download $($asset.browser_download_url) (curl exit code $LASTEXITCODE)" }
    return $path
}

# Gives the distribution's Terminal profile Ika's icon: WSL copied the image's
# to shortcut.ico beside its disk, where the profile points. The icon comes
# from ika-base, once installed, else from a checkout or from GitHub.
function Set-DistributionIcon {
    $key = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' |
        Where-Object { (Get-ItemProperty $_.PSPath).DistributionName -eq $Name } | Select-Object -First 1
    if (-not $key) { return }
    $target = Join-Path (Get-ItemProperty $key.PSPath).BasePath 'shortcut.ico'
    $sources = @("\\wsl.localhost\$Name\usr\lib\cuttlefish-common\share\icons\ika.ico")
    # A checkout's own copy; none when run as a one-liner (irm ... | iex)
    if ($PSScriptRoot) { $sources += Join-Path $PSScriptRoot 'src\scrcpy\app\data\icon.ico' }
    $local = $sources | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if ($local) {
        Copy-Item -LiteralPath $local -Destination $target -Force
    } else {
        Invoke-WebRequest -UseBasicParsing -OutFile $target `
            -Uri 'https://raw.githubusercontent.com/DesktopECHO/ika/main/src/scrcpy/app/data/icon.ico'
    }
}

# Makes the distribution's Terminal profile open Android's shell (ika shell),
# not the distribution's, named for it: "Android (Ika)". WSL writes the profile
# as a fragment of its own, which another fragment cannot change: the command
# line and the name go in Terminal's settings, in the entry of the profile's
# GUID, as a user's own would (the file
# kept as settings.json.ika-backup). A settings file with comments, which this
# would drop, is left as it is.
function Set-TerminalProfile {
    $fragments = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments'
    $wslProfile = Get-ChildItem (Join-Path $fragments 'Microsoft.WSL') -Filter *.json -ErrorAction SilentlyContinue |
        ForEach-Object { (Get-Content -Raw -LiteralPath $_.FullName | ConvertFrom-Json).profiles } |
        Where-Object { $_.name -eq $Name -and $_.guid -and $_.commandline } | Select-Object -First 1
    if (-not $wslProfile) { return }
    $commandline = "$($wslProfile.commandline) -- ika shell"
    $profileName = "Android ($Name)"
    $files = @(
        'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json',
        'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json',
        'Microsoft\Windows Terminal\settings.json'
    ) | ForEach-Object { Join-Path $env:LOCALAPPDATA $_ } | Where-Object { Test-Path -LiteralPath $_ }
    foreach ($file in $files) {
        $text = Get-Content -Raw -LiteralPath $file
        if ($text -match '(?m)^\s*//') {
            Write-Warning "Not changing $file, which has comments: set the Ika profile's command line to $commandline"
            continue
        }
        $settings = $text | ConvertFrom-Json
        if (-not $settings.profiles -or $settings.profiles -is [array]) { continue }
        $list = @($settings.profiles.list)
        $entry = $list | Where-Object { $_.guid -eq $wslProfile.guid } | Select-Object -First 1
        if ($entry -and $entry.commandline -eq $commandline -and $entry.name -eq $profileName) { continue }
        if (-not $entry) {
            $entry = [pscustomobject]@{ guid = $wslProfile.guid }
            $settings.profiles | Add-Member -NotePropertyName list -NotePropertyValue (@($entry) + $list) -Force
        }
        $entry | Add-Member -NotePropertyName commandline -NotePropertyValue $commandline -Force
        $entry | Add-Member -NotePropertyName name -NotePropertyValue $profileName -Force
        Copy-Item -LiteralPath $file -Destination "$file.ika-backup" -Force
        [IO.File]::WriteAllText($file, ($settings | ConvertTo-Json -Depth 32))
    }
}

# Removes the Start menu shortcut WSL made for the distribution, which opens a
# shell in it: with Ika's icon it looked like a second Ika beside WSLg's entry
# for Ika itself. It runs wsl.exe --distribution-id {ID}.
function Remove-DistributionShortcut {
    $key = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' |
        Where-Object { (Get-ItemProperty $_.PSPath).DistributionName -eq $Name } | Select-Object -First 1
    if (-not $key) { return }
    $id = $key.PSChildName
    $shell = New-Object -ComObject WScript.Shell
    Get-ChildItem (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu') -Recurse -Filter *.lnk |
        Where-Object {
            $link = $shell.CreateShortcut($_.FullName)
            $link.TargetPath -like '*\wsl.exe' -and $link.Arguments -like "*--distribution-id $id*"
        } | Remove-Item -Force
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

# --- Prerequisites --------------------------------------------------------

# WSL2 needs three things of Windows: the WSL package, 2.4.4 or newer (it
# installs a distribution under a name of its own); the Virtual Machine
# Platform; and Windows' hypervisor, which runs once the firmware's
# virtualization is on. Whatever is missing is set up at once, behind one
# permission prompt, so that a single restart finishes it all. WSL 1's
# optional component (Windows Subsystem for Linux) stays off: Ika runs on
# WSL2 only, and Windows' own wsl.exe --install, which would turn it on, is
# not used. Reading all this needs no elevation.
$wslVersion = Get-WslVersion
$needWsl = -not $wslVersion -or $wslVersion -lt [version]'2.4.4'
# InstallState 1 is enabled
$vmPlatform = Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'" -ErrorAction SilentlyContinue
$needVmPlatform = -not $vmPlatform -or $vmPlatform.InstallState -ne 1
$needHypervisor = -not (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
# The firmware's setting reads true only while no hypervisor runs
$firmwareOff = $needHypervisor -and
    -not (Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled

if ($needWsl -or $needVmPlatform -or $needHypervisor) {
    $prerequisites = Join-Path $env:TEMP "ika-wsl-$PID-prerequisites"
    New-Item -ItemType Directory -Force -Path $prerequisites | Out-Null
    try {
        # One script, run elevated, does it all; its result file says what is
        # left: a line "restart" when Windows must restart, or the error
        $result = Join-Path $prerequisites 'result.txt'
        $steps = @()
        if ($needWsl) {
            $msi = Get-WslPackage $prerequisites
            $steps += "Install-Step msiexec.exe '/i ""$($msi -replace "'", "''")"" /qn /norestart' 'Installing WSL'"
        }
        if ($needVmPlatform) {
            $steps += "Install-Step dism.exe '/online /enable-feature /featurename:VirtualMachinePlatform /all /norestart /quiet' 'Turning on the Virtual Machine Platform'"
            $steps += "Add-Content -LiteralPath `$result 'restart'"
        }
        if ($needHypervisor) {
            # Windows starts its hypervisor with the Virtual Machine Platform
            # on, unless told not to
            $steps += "Install-Step bcdedit.exe '/set hypervisorlaunchtype auto' 'Starting Windows'' hypervisor at boot'"
            $steps += "Add-Content -LiteralPath `$result 'restart'"
        }
        $script = @"
`$ErrorActionPreference = 'Stop'
`$result = '$($result -replace "'", "''")'
function Install-Step([string]`$File, [string]`$Arguments, [string]`$Text) {
    Write-Host `$Text
    `$process = Start-Process `$File -ArgumentList `$Arguments -Wait -PassThru -NoNewWindow
    # 3010 and 1641: done, once Windows restarts
    if (`$process.ExitCode -in 3010, 1641) {
        Add-Content -LiteralPath `$result 'restart'
    } elseif (`$process.ExitCode -ne 0) {
        throw "`$Text failed: `$File `$Arguments (exit code `$(`$process.ExitCode))"
    }
}
try {
    $($steps -join "`n    ")
} catch {
    Add-Content -LiteralPath `$result "error: `$_"
    exit 1
}
"@
        Write-Step 'Setting up WSL2 (Windows asks for permission)'
        if ($needWsl) { Write-Host '  the WSL package' }
        if ($needVmPlatform) { Write-Host '  the Virtual Machine Platform' }
        if ($needHypervisor) { Write-Host "  Windows' hypervisor" }
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
        $elevated = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList `
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
        $lines = @(Get-Content -LiteralPath $result -ErrorAction SilentlyContinue)
        $failure = $lines | Where-Object { $_ -like 'error: *' } | Select-Object -First 1
        if ($failure) { throw $failure.Substring(7) }
        if ($elevated.ExitCode -ne 0) { throw "Setting up WSL2 failed (exit code $($elevated.ExitCode))" }
        $restart = $lines -contains 'restart'
    } finally {
        Remove-Item -LiteralPath $prerequisites -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($needWsl) {
        $wslVersion = Get-WslVersion
        if (-not $wslVersion -or $wslVersion -lt [version]'2.4.4') {
            throw 'WSL is not 2.4.4 or newer after installing it; install it from the Microsoft Store and run this again.'
        }
    }
    if ($firmwareOff) {
        Write-Step "Virtualization is off in the PC's firmware"
        Write-Host 'Restart Windows into its UEFI/BIOS settings, turn on SVM Mode (AMD) or Intel'
        Write-Host 'Virtualization Technology (VT-x), then run this again.'
        return
    }
    if ($restart) {
        Write-Step 'Restart Windows to finish setting up WSL2, then run this again.'
        return
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
$download = Join-Path $env:TEMP "ika-wsl-$PID"
New-Item -ItemType Directory -Force -Path $download | Out-Null
try {
    $image = Get-DebianImage $download
    # --version 2: where WSL 1 is on, it may be the default
    $install = @('--install', '--from-file', $image, '--name', $Name, '--version', '2', '--no-launch')
    if ($Location) { $install += @('--location', $Location) }
    Invoke-Wsl @install
} finally {
    Remove-Item -LiteralPath $download -Recurse -Force -ErrorAction SilentlyContinue
}
try {
    Set-TerminalProfile
} catch {
    Write-Warning "Could not make $Name's Terminal profile open Android's shell: $_"
}
try {
    Remove-DistributionShortcut
} catch {
    Write-Warning "Could not remove $Name's shell shortcut from the Start menu: $_"
}

Write-Step "Creating the user $UserName and turning on systemd"
Invoke-Provision user root | Out-Null
Invoke-Wsl --terminate $Name

# The dots of the install step follow on the same line
Write-Step 'Installing Debian packages, this will take a few minutes...' -NoNewline
Invoke-Provision install root -Dots | Out-Null
# After the install: the icon comes from ika-base
try {
    Set-DistributionIcon
} catch {
    Write-Warning "Could not give $Name Ika's icon: $_"
}

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
# Its report of what it fixes wraps badly in the console; what it leaves
# missing is asked for below instead
$setupOutput = Invoke-Provision setup $UserName -NoThrow -Quiet
if (($setupOutput -join "`n") -match 'wsl --shutdown') { $restartWsl = $true }

# What a restart of WSL brings: the kernel's settings, systemd, the time zone.
# Anything else still missing is a fix that did not take.
$byRestart = @('nested-virtualization', 'kvm', 'cgroup2', 'cgroup-cpu', 'systemd', 'timezone')
foreach ($line in Invoke-Provision check $UserName -NoThrow -Quiet) {
    if ($line -notmatch '^([^\t]+)\t(.+)$') { continue }
    if ($restartWsl -and $byRestart -contains $Matches[1]) { continue }
    $reason = $Matches[2]
    if ($Matches[1] -eq 'kernel') { $reason += "; ""wsl -d $Name -- ika-wsl-setup"" builds it" }
    Write-Warning "Not set up: $reason"
}

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

# Run in Windows' session 0, which has no desktop (over SSH, for one), this
# booted WSL's VM there, and with it WSLg's client (msrdc.exe), which shows
# Linux windows and adds their Start menu entries: neither would reach the
# desktop, and Ika's console would not open. Unless WSLg already runs in a
# desktop's session, WSL stops, so that Ika's start from the desktop boots it
# there.
if ((Get-Process -Id $PID).SessionId -eq 0) {
    # Windows hides the path of WSLg's msrdc.exe at times: the name will do
    $desktopWslg = Get-Process msrdc -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -ne 0 }
    if (-not $desktopWslg) {
        # A restart above stopped WSL already
        if (-not $restartWsl) {
            Write-Step "This ran outside the desktop (Windows' session 0, over SSH for one): WSL must stop, which stops every running distribution, for Ika's windows to open on the desktop"
            $stopWsl = $true
            if (-not $Force) {
                $answer = Read-Host 'Stop WSL now? [Y/n]'
                if ($answer -and $answer -notmatch '^[Yy]') { $stopWsl = $false }
            }
            if ($stopWsl) {
                Invoke-Wsl --shutdown
            } else {
                Write-Host 'Run "wsl --shutdown" on the desktop before starting Ika.'
            }
        }
        Write-Step "Install complete, start Ika on the desktop with: wsl -d $Name -- ika start"
        return
    }
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
