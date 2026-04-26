Name:           ika-container
Version:        1.51.0
Release:        2%{?dist}
Summary:        Container-oriented Cuttlefish tools for Fedora
License:        Apache-2.0
URL:            https://github.com/google/android-cuttlefish
Source0:        android-cuttlefish-%{version}.tar.gz
%undefine _debugsource_packages

BuildRequires:  git
BuildRequires:  golang
BuildRequires:  systemd-rpm-macros

%description
Builds the podcvd container launcher package for Fedora.

Provides:       cuttlefish-container = %{version}-%{release}
Obsoletes:      cuttlefish-container < %{version}-%{release}

%package -n ika-podcvd
Summary:        Rootless podman launcher for Cuttlefish containers
Requires:       android-tools
Requires:       podman
Requires(post): /usr/bin/systemctl
Requires(preun): /usr/bin/systemctl
Requires(postun): /usr/bin/systemctl
Provides:       cuttlefish-podcvd = %{version}-%{release}
Obsoletes:      cuttlefish-podcvd < %{version}-%{release}

%description -n ika-podcvd
Contains the podcvd binary and the networking preparation service used to run
Cuttlefish instances inside rootless containers.

%prep
%autosetup -n android-cuttlefish-%{version}

%build
pushd container/src/podcvd
go build -v -buildmode=pie -ldflags="-w" ./cmd/podcvd
popd

%install
rm -rf %{buildroot}

install -Dpm0755 container/debian/cuttlefish-podcvd-prerequisites.sh %{buildroot}/usr/lib/cuttlefish-common/bin/cuttlefish-podcvd-prerequisites.sh
install -Dpm0755 container/src/podcvd/podcvd %{buildroot}/usr/lib/cuttlefish-common/bin/podcvd
install -Dpm0644 container/rpm/cuttlefish-podcvd.service %{buildroot}/usr/lib/systemd/system/cuttlefish-podcvd.service
install -Dpm0755 container/rpm/cuttlefish-podcvd.sh %{buildroot}/usr/libexec/cuttlefish/cuttlefish-podcvd
install -Dpm0644 container/rpm/cuttlefish-podcvd.sysconfig %{buildroot}/etc/sysconfig/cuttlefish-podcvd

%post -n ika-podcvd
systemctl daemon-reload >/dev/null 2>&1 || :
systemctl enable --now cuttlefish-podcvd.service >/dev/null 2>&1 || :

%preun -n ika-podcvd
if [ $1 -eq 0 ]; then
  systemctl disable --now cuttlefish-podcvd.service >/dev/null 2>&1 || :
fi

%postun -n ika-podcvd
systemctl daemon-reload >/dev/null 2>&1 || :

%files -n ika-podcvd
%license LICENSE
/etc/sysconfig/cuttlefish-podcvd
/usr/lib/cuttlefish-common/bin/cuttlefish-podcvd-prerequisites.sh
/usr/lib/cuttlefish-common/bin/podcvd
/usr/lib/systemd/system/cuttlefish-podcvd.service
/usr/libexec/cuttlefish/cuttlefish-podcvd

%changelog
* Mon Apr 20 2026 Daniel Milisic <dmilisic@desktopecho.com> - 1.51.0-4
- Rebase Fedora packaging onto android-cuttlefish 1.51.0

* Sat Mar 28 2026 Daniel Milisic <dmilisic@desktopecho.com> - 1.50.0-1
- Port cuttlefish-podcvd packaging to Fedora RPMs
