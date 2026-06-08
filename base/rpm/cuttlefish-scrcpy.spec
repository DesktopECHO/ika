Name:           ika-scrcpy
Version:        3.3.4
Release:        5%{?dist}
Summary:        scrcpy Android screen mirroring tool for Cuttlefish
License:        Apache-2.0
URL:            https://github.com/Genymobile/scrcpy
Source0:        android-cuttlefish-1.53.0.tar.gz
%global debug_package %{nil}

BuildRequires:  gcc
BuildRequires:  meson
BuildRequires:  ninja-build
BuildRequires:  pkgconf-pkg-config
BuildRequires:  libavcodec-free-devel
BuildRequires:  libavformat-free-devel
BuildRequires:  libavutil-free-devel
BuildRequires:  libswresample-free-devel
BuildRequires:  SDL3-devel
BuildRequires:  libusb1-devel
BuildRequires:  vulkan-headers
BuildRequires:  libicu-devel

Requires:       ika-base
Requires:       libavcodec-free
Requires:       libavformat-free
Requires:       libavutil-free
Requires:       libswresample-free
Requires:       SDL3
Requires:       libusb1

%description
Contains scrcpy, a command-line Android screen mirroring and control tool,
installed for use with Cuttlefish Android Virtual Devices under
/usr/lib/cuttlefish-common.

Provides:       cuttlefish-scrcpy = %{version}-%{release}
Obsoletes:      cuttlefish-scrcpy < %{version}-%{release}

%prep
%autosetup -n android-cuttlefish-1.53.0

%build
meson setup scrcpy _build_scrcpy \
    --buildtype=release \
    --prefix=/usr/lib/cuttlefish-common \
    --bindir=bin \
    -Dprebuilt_server=scrcpy-server \
    -Dcompile_server=true
meson compile -C _build_scrcpy

%install
rm -rf %{buildroot}
DESTDIR=%{buildroot} meson install -C _build_scrcpy

install -d %{buildroot}/usr/share/applications
install -d %{buildroot}/usr/share/icons/hicolor/256x256/apps

install -m 0644 \
  %{buildroot}/usr/lib/cuttlefish-common/share/applications/scrcpy.desktop \
  %{buildroot}/usr/share/applications/ika-scrcpy.desktop
install -m 0644 \
  %{buildroot}/usr/lib/cuttlefish-common/share/icons/hicolor/256x256/apps/scrcpy.png \
  %{buildroot}/usr/share/icons/hicolor/256x256/apps/ika-scrcpy.png

sed -i \
  -e 's#^Exec=.*#Exec=ika start#' \
  -e 's#^Name=.*#Name=Ika#' \
  -e 's#^Icon=.*#Icon=ika-scrcpy#' \
  -e '/^StartupNotify=/a StartupWMClass=scrcpy' \
  %{buildroot}/usr/share/applications/ika-scrcpy.desktop

%files
%license scrcpy/LICENSE
/usr/lib/cuttlefish-common/bin/scrcpy
/usr/lib/cuttlefish-common/share/applications/scrcpy-console.desktop
/usr/lib/cuttlefish-common/share/applications/scrcpy.desktop
/usr/lib/cuttlefish-common/share/bash-completion/completions/scrcpy
/usr/lib/cuttlefish-common/share/icons/hicolor/256x256/apps/scrcpy.png
/usr/lib/cuttlefish-common/share/man/man1/scrcpy.1*
/usr/lib/cuttlefish-common/share/scrcpy/scrcpy-server
/usr/lib/cuttlefish-common/share/zsh/site-functions/_scrcpy
/usr/share/applications/ika-scrcpy.desktop
/usr/share/icons/hicolor/256x256/apps/ika-scrcpy.png

%changelog
* Tue May 26 2026 DesktopECHO <build@desktopecho.com> - 3.3.4-4
- Bump generated RPM release to revision 4

* Sun May 24 2026 DesktopECHO <build@desktopecho.com> - 3.3.4-3
- Bump generated RPM release to revision 3

* Thu Apr 09 2026 Daniel Milisic <dmilisic@desktopecho.com> - 3.3.4-1
- Package scrcpy as cuttlefish-scrcpy RPM
