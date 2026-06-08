Name:           ika-lineageos
Version:        20260420
Release:        5%{?dist}
Summary:        LineageOS for Cuttlefish host
License:        Apache-2.0
URL:            https://github.com/google/android-cuttlefish
Source0:        android-cuttlefish-1.53.0.tar.gz
ExclusiveArch:  aarch64 x86_64
%global debug_package %{nil}
AutoReqProv:    no

Requires:       ika-base

%ifarch aarch64
%global ika_arch arm64
%else
%global ika_arch x86_64
%endif

%description
Contains LineageOS 23 for use by this Cuttlefish workflow, installed under
/usr/share/cuttlefish-common/lineageos.

Provides:       cuttlefish-lineageos = %{version}-%{release}
Obsoletes:      cuttlefish-lineageos < %{version}-%{release}

%prep
%autosetup -n android-cuttlefish-1.53.0

%install
rm -rf %{buildroot}

mkdir -p %{buildroot}/usr/share/cuttlefish-common
cp -a lineageos-%{ika_arch} %{buildroot}/usr/share/cuttlefish-common/lineageos
find %{buildroot}/usr/share/cuttlefish-common/lineageos -type d ! -type l -exec chmod 755 '{}' +
find %{buildroot}/usr/share/cuttlefish-common/lineageos ! -type l -exec chmod u+w '{}' +
find %{buildroot}/usr/share/cuttlefish-common/lineageos ! -type l -exec chmod g=u '{}' +
find %{buildroot}/usr/share/cuttlefish-common/lineageos -type d ! -type l -exec chmod a+rx '{}' +

%files
%license LICENSE
%defattr(-,root,kvm,-)
/usr/share/cuttlefish-common/lineageos

%post
manifest=%{_localstatedir}/lib/cuttlefish-lineageos/created-symlinks
mkdir -p "$(dirname "$manifest")"
if [ "$1" -eq 1 ]; then
  : > "$manifest"
else
  touch "$manifest"
fi

cd /usr/share/cuttlefish-common/lineageos || exit 0
find etc usr -mindepth 1 | while read -r path; do
  target="/usr/lib/cuttlefish-common/${path}"
  source="/usr/share/cuttlefish-common/lineageos/${path}"
  if [ ! -e "${target}" ]; then
    mkdir -p "$(dirname "${target}")"
    ln -s "${source}" "${target}"
    grep -Fxq "${target}" "$manifest" || printf '%s\n' "${target}" >> "$manifest"
  fi
done

%postun
if [ "$1" -eq 0 ]; then
  manifest=%{_localstatedir}/lib/cuttlefish-lineageos/created-symlinks
  if [ -f "$manifest" ]; then
    tac "$manifest" | while read -r target; do
      expected="/usr/share/cuttlefish-common/lineageos/${target#/usr/lib/cuttlefish-common/}"
      if [ -L "$target" ] && [ "$(readlink "$target")" = "$expected" ]; then
        rm -f "$target"
      fi
    done
    rm -f "$manifest"
  fi
fi

%changelog
* Tue May 26 2026 DesktopECHO <build@desktopecho.com> - 20260420-4
- Bump generated RPM release to revision 4

* Sun May 24 2026 DesktopECHO <build@desktopecho.com> - 20260420-3
- Bump generated RPM release to revision 3

* Tue Mar 31 2026 Daniel Milisic <dmilisic@desktopecho.com> - 20260401-1
- Package LineageOS as standalone RPM
