Name:           ika-integration-gigabyte-arm64
Version:        1.53.0
Release:        4%{?dist}
Summary:        Gigabyte Ampere integration package for Cuttlefish on Fedora
License:        Apache-2.0
URL:            https://github.com/google/android-cuttlefish
Source0:        android-cuttlefish-%{version}.tar.gz

ExclusiveArch:  aarch64

BuildRequires:  systemd-rpm-macros

Requires:       dkms
Requires:       glibc-devel
Requires:       java-latest-openjdk-devel
Requires:       libglvnd-devel
Requires:       lzop
Requires:       ntpsec
Requires:       pkgconf-pkg-config

%description
Contains Gigabyte Ampere host integration files and version metadata for
Cuttlefish deployments on Fedora.

Provides:       cuttlefish-integration-gigabyte-arm64 = %{version}-%{release}
Obsoletes:      cuttlefish-integration-gigabyte-arm64 < %{version}-%{release}

%prep
%autosetup -n android-cuttlefish-%{version}

%build
pushd cuttlefish-integration-gigabyte-arm64
./update_version_info.sh
popd

%install
rm -rf %{buildroot}

install -Dpm0644 cuttlefish-integration-gigabyte-arm64/etc/security/limits.d/95-cuttlefish-integration-gigabyte-arm64-nofile.conf %{buildroot}/etc/security/limits.d/95-cuttlefish-integration-gigabyte-arm64-nofile.conf
install -Dpm0644 cuttlefish-integration-gigabyte-arm64/usr/lib/NetworkManager/conf.d/cuttlefish-integration-gigabyte-arm64.conf %{buildroot}/usr/lib/NetworkManager/conf.d/cuttlefish-integration-gigabyte-arm64.conf
install -Dpm0644 cuttlefish-integration-gigabyte-arm64/usr/lib/modules-load.d/cuttlefish-integration-gigabyte-arm64.conf %{buildroot}/usr/lib/modules-load.d/cuttlefish-integration-gigabyte-arm64.conf
install -Dpm0644 cuttlefish-integration-gigabyte-arm64/usr/share/cuttlefish-integration-gigabyte-arm64-use-google-ntp %{buildroot}/usr/share/cuttlefish-integration-gigabyte-arm64/use-google-ntp
install -Dpm0644 cuttlefish-integration-gigabyte-arm64/usr/share/version_info %{buildroot}/usr/share/cuttlefish-integration-gigabyte-arm64/version_info
install -Dpm0644 cuttlefish-integration-gigabyte-arm64/etc/ntpsec/ntp.d/google-time-server.conf %{buildroot}/etc/ntpsec/ntp.d/google-time-server.conf

%files
%license LICENSE
/etc/ntpsec/ntp.d/google-time-server.conf
/etc/security/limits.d/95-cuttlefish-integration-gigabyte-arm64-nofile.conf
/usr/lib/NetworkManager/conf.d/cuttlefish-integration-gigabyte-arm64.conf
/usr/lib/modules-load.d/cuttlefish-integration-gigabyte-arm64.conf
/usr/share/cuttlefish-integration-gigabyte-arm64

%changelog
* Tue May 26 2026 DesktopECHO <build@desktopecho.com> - 1.53.0-4
- Bump generated RPM release to revision 4

* Sun May 24 2026 DesktopECHO <build@desktopecho.com> - 1.53.0-3
- Bump generated RPM release to revision 3

* Tue May 19 2026 DesktopECHO <build@desktopecho.com> - 1.53.0-1
- Rebase Fedora packaging onto android-cuttlefish 1.53.0

* Mon Apr 20 2026 Daniel Milisic <dmilisic@desktopecho.com> - 1.51.0-4
- Rebase Fedora packaging onto android-cuttlefish 1.51.0

* Sat Mar 28 2026 Daniel Milisic <dmilisic@desktopecho.com> - 1.50.0-1
- Port Gigabyte integration packaging to Fedora RPMs
