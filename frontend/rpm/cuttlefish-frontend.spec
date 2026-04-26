Name:           ika-frontend
Version:        1.51.0
Release:        2%{?dist}
Summary:        Frontend and orchestration packages for Cuttlefish on Fedora
License:        Apache-2.0
URL:            https://github.com/google/android-cuttlefish
Source0:        android-cuttlefish-%{version}.tar.gz
%undefine _debugsource_packages

BuildRequires:  curl
BuildRequires:  git
BuildRequires:  golang
BuildRequires:  npm
BuildRequires:  protobuf-compiler
BuildRequires:  protobuf-devel
BuildRequires:  systemd-rpm-macros

%description
Builds the operator and orchestration packages used to interact with
Cuttlefish instances.

Provides:       cuttlefish-frontend = %{version}-%{release}
Obsoletes:      cuttlefish-frontend < %{version}-%{release}

%package -n ika-user
Summary:        Operator service for browser access to Cuttlefish
Requires:       ika-base = %{version}-%{release}
Requires:       openssl
Requires(post): /usr/sbin/useradd
Requires(post): /usr/bin/systemctl
Requires(preun): /usr/bin/systemctl
Requires(postun): /usr/bin/systemctl
Provides:       cuttlefish-user = %{version}-%{release}
Obsoletes:      cuttlefish-user < %{version}-%{release}

%description -n ika-user
Contains the host operator service that exposes the browser-facing control
plane for Cuttlefish.

%package -n ika-orchestration
Summary:        Host Orchestrator service for Cuttlefish
Requires:       ika-user = %{version}-%{release}
Requires:       nginx
Requires:       openssl
Requires:       systemd-journal-remote
Requires(post): /usr/sbin/useradd
Requires(post): /usr/sbin/usermod
Requires(post): /usr/bin/systemctl
Requires(preun): /usr/bin/systemctl
Requires(postun): /usr/bin/systemctl
Provides:       cuttlefish-orchestration = %{version}-%{release}
Obsoletes:      cuttlefish-orchestration < %{version}-%{release}

%description -n ika-orchestration
Contains the Host Orchestrator service and nginx configuration used to expose
artifact and log access for Cuttlefish.

%prep
%autosetup -n android-cuttlefish-%{version}

%build
pushd frontend
src/goutil src/host_orchestrator build -v -buildmode=pie -ldflags="-w"
src/goutil src/operator build -v -buildmode=pie -ldflags="-w"
./build-webui.sh
popd

%install
rm -rf %{buildroot}

install -Dpm0755 frontend/src/operator/operator %{buildroot}/usr/lib/cuttlefish-common/bin/operator
install -Dpm0755 frontend/src/host_orchestrator/host_orchestrator %{buildroot}/usr/lib/cuttlefish-common/bin/host_orchestrator
mkdir -p %{buildroot}/usr/share/cuttlefish-common/operator
cp -a frontend/src/operator/webui/dist/static %{buildroot}/usr/share/cuttlefish-common/operator/
cp -a frontend/src/operator/intercept %{buildroot}/usr/share/cuttlefish-common/operator/

install -Dpm0644 frontend/rpm/cuttlefish-operator.service %{buildroot}/usr/lib/systemd/system/cuttlefish-operator.service
install -Dpm0755 frontend/rpm/cuttlefish-operator.sh %{buildroot}/usr/libexec/cuttlefish/cuttlefish-operator
install -Dpm0755 frontend/rpm/cuttlefish-operator-prepare.sh %{buildroot}/usr/libexec/cuttlefish/cuttlefish-operator-prepare
install -Dpm0644 frontend/rpm/cuttlefish-operator.sysconfig %{buildroot}/etc/sysconfig/cuttlefish-operator

install -Dpm0644 frontend/rpm/cuttlefish-host_orchestrator.service %{buildroot}/usr/lib/systemd/system/cuttlefish-host_orchestrator.service
install -Dpm0755 frontend/rpm/cuttlefish-host_orchestrator.sh %{buildroot}/usr/libexec/cuttlefish/cuttlefish-host_orchestrator
install -Dpm0755 frontend/rpm/cuttlefish-host_orchestrator-prepare.sh %{buildroot}/usr/libexec/cuttlefish/cuttlefish-host_orchestrator-prepare
install -Dpm0644 frontend/rpm/cuttlefish-host_orchestrator.sysconfig %{buildroot}/etc/sysconfig/cuttlefish-host_orchestrator
install -Dpm0644 frontend/host/packages/cuttlefish-orchestration/etc/nginx/sites-available/cuttlefish-orchestration.conf %{buildroot}/etc/nginx/conf.d/cuttlefish-orchestration.conf

mkdir -p %{buildroot}/usr/bin
ln -sfn ../lib/cuttlefish-common/bin/host_orchestrator %{buildroot}/usr/bin/cvd_host_orchestrator
ln -sfn ../lib/cuttlefish-common/bin/cvd %{buildroot}/usr/bin/fetch_cvd

%post -n ika-user
if ! getent passwd _cutf-operator >/dev/null 2>&1; then
  useradd -r -M -d /var/empty -g cvdnetwork _cutf-operator >/dev/null 2>&1 || :
fi
usermod -a -G video,render _cutf-operator >/dev/null 2>&1 || :
systemctl daemon-reload >/dev/null 2>&1 || :
systemctl enable --now cuttlefish-operator.service >/dev/null 2>&1 || :

%post -n ika-orchestration
if ! getent passwd httpcvd >/dev/null 2>&1; then
  useradd -r -M -d /var/empty httpcvd >/dev/null 2>&1 || :
fi
usermod -a -G cvdnetwork,kvm,video,render httpcvd >/dev/null 2>&1 || :
systemctl daemon-reload >/dev/null 2>&1 || :

%preun -n ika-user
if [ $1 -eq 0 ]; then
  systemctl disable --now cuttlefish-operator.service >/dev/null 2>&1 || :
fi

%preun -n ika-orchestration
if [ $1 -eq 0 ]; then
  systemctl disable --now cuttlefish-host_orchestrator.service >/dev/null 2>&1 || :
fi

%postun -n ika-user
systemctl daemon-reload >/dev/null 2>&1 || :

%postun -n ika-orchestration
systemctl daemon-reload >/dev/null 2>&1 || :

%files -n ika-user
%license LICENSE
/etc/sysconfig/cuttlefish-operator
/usr/bin/cvd_host_orchestrator
/usr/lib/cuttlefish-common/bin/operator
/usr/lib/systemd/system/cuttlefish-operator.service
/usr/libexec/cuttlefish/cuttlefish-operator
/usr/libexec/cuttlefish/cuttlefish-operator-prepare
/usr/share/cuttlefish-common/operator

%files -n ika-orchestration
%license LICENSE
/etc/nginx/conf.d/cuttlefish-orchestration.conf
/etc/sysconfig/cuttlefish-host_orchestrator
/usr/bin/fetch_cvd
/usr/lib/cuttlefish-common/bin/host_orchestrator
/usr/lib/systemd/system/cuttlefish-host_orchestrator.service
/usr/libexec/cuttlefish/cuttlefish-host_orchestrator
/usr/libexec/cuttlefish/cuttlefish-host_orchestrator-prepare

%changelog
* Mon Apr 20 2026 Daniel Milisic <dmilisic@desktopecho.com> - 1.51.0-4
- Rebase Fedora packaging onto android-cuttlefish 1.51.0

* Sat Mar 28 2026 Daniel Milisic <dmilisic@desktopecho.com> - 1.50.0-1
- Port frontend packaging and services to Fedora RPMs
