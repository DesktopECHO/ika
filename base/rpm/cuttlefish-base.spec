Name:           ika-base
Version:        260713
Release:        1%{?dist}
Summary:        Cuttlefish Android Virtual Device host packages for Fedora
License:        Apache-2.0
URL:            https://github.com/google/android-cuttlefish
Source0:        android-cuttlefish-%{version}.tar.gz
# objcopy/nm (find-debuginfo) can't parse the Bazel/Clang-built binaries; skip debug packaging.
%global debug_package %{nil}
# Fedora 44's GNU strip also cannot parse some Bazel/Clang-built Cuttlefish
# binaries, so skip the automatic brp strip passes for this package.
%global __brp_strip %{nil}
%global __brp_strip_comment_note %{nil}
%global __brp_strip_lto %{nil}

BuildRequires:  libaom-devel
BuildRequires:  clang-devel
BuildRequires:  cmake
BuildRequires:  fmt-devel
BuildRequires:  gcc-c++
BuildRequires:  gflags-devel
BuildRequires:  git
BuildRequires:  glog-devel
BuildRequires:  gtest-devel
BuildRequires:  jsoncpp-devel
BuildRequires:  libX11-devel
BuildRequires:  libXext-devel
BuildRequires:  libcurl-devel
BuildRequires:  libavdevice-free-devel
BuildRequires:  libcap-devel
BuildRequires:  libdrm-devel
BuildRequires:  libicu-devel
BuildRequires:  libxcrypt-compat
BuildRequires:  libuuid-devel
BuildRequires:  libxml2-devel
BuildRequires:  libsrtp-devel
BuildRequires:  libswscale-free-devel
BuildRequires:  opus-devel
BuildRequires:  openssl-devel
BuildRequires:  perl-FindBin
BuildRequires:  pkgconf-pkg-config
BuildRequires:  protobuf-c-devel
BuildRequires:  protobuf-compiler
BuildRequires:  protobuf-devel
BuildRequires:  python3
BuildRequires:  systemd-rpm-macros
BuildRequires:  mesa-libgbm-devel
BuildRequires:  virglrenderer-devel
BuildRequires:  vulkan-headers
BuildRequires:  wayland-devel
BuildRequires:  which
BuildRequires:  xxd
BuildRequires:  xz-devel
BuildRequires:  z3-devel
# scrcpy viewer (Meson C build), folded into ika-base.
BuildRequires:  meson
BuildRequires:  ninja-build
BuildRequires:  SDL3-devel
BuildRequires:  pipewire-devel
BuildRequires:  libusb1-devel
BuildRequires:  libavcodec-free-devel
BuildRequires:  libavformat-free-devel
BuildRequires:  libavutil-free-devel
BuildRequires:  libswresample-free-devel

Requires:       bsdtar
Requires:       curl
Requires:       dnsmasq
Requires:       iproute
Requires:       libcap
Requires:       libdrm
Requires:       libX11
Requires:       libXext
Requires:       lz4
Requires:       mesa-libgbm >= 26.1
Requires:       mesa-libGL >= 26.1
Requires:       glx-utils
Requires:       mesa-vulkan-drivers >= 26.1
Requires:       vulkan-tools
Requires:       net-tools
Requires:       NetworkManager
Requires:       nftables
Requires:       openssl
Requires:       python3
Requires:       python3-requests
Requires:       virglrenderer
Requires:       xdg-utils
Requires:       xz-libs
# scrcpy viewer runtime dependencies, folded into ika-base.
Requires:       wayland-utils
Requires:       SDL3
Requires:       pipewire-libs
Requires:       libusb1
Requires:       libavcodec-free
Requires:       libavformat-free
Requires:       libavutil-free
Requires:       libswresample-free

Requires(post): /usr/sbin/groupadd
Requires(post): /usr/sbin/usermod
Requires(post): /usr/sbin/setcap
Requires(post): /usr/sbin/sysctl
Requires(post): /usr/bin/systemctl
Requires(posttrans): /usr/sbin/setcap
Requires(preun): /usr/bin/systemctl
Requires(postun): /usr/bin/systemctl

%description
Contains the base host-side binaries, networking helpers, and system services
required to boot and manage Cuttlefish Android Virtual Devices on Fedora.

Provides:       cuttlefish-base = %{version}-%{release}
Obsoletes:      cuttlefish-base < %{version}-%{release}
# The standalone scrcpy viewer package is now folded into ika-base. Retire both
# the ika and legacy cuttlefish names so upgrades remove the old package.
Provides:       ika-scrcpy = %{version}-%{release}
Obsoletes:      ika-scrcpy < %{version}-%{release}
Provides:       cuttlefish-scrcpy = %{version}-%{release}
Obsoletes:      cuttlefish-scrcpy < %{version}-%{release}

%package -n ika-common
Summary:        Compatibility metapackage for Cuttlefish host packages
Requires:       ika-base = %{version}-%{release}
Requires:       ika-defaults = %{version}-%{release}
Requires:       ika-user = %{version}-%{release}
Provides:       cuttlefish-common = %{version}-%{release}
Obsoletes:      cuttlefish-common < %{version}-%{release}

%description -n ika-common
Compatibility metapackage ensuring the primary host-side Cuttlefish packages
are installed together.

%package -n ika-integration
Summary:        Cloud integration utilities for Cuttlefish
Requires:       ika-base = %{version}-%{release}
%ifarch aarch64
Requires:       qemu-system-aarch64-core
%endif
%ifarch x86_64
Requires:       qemu-system-x86-core
%endif
Provides:       cuttlefish-integration = %{version}-%{release}
Obsoletes:      cuttlefish-integration < %{version}-%{release}

%description -n ika-integration
Contains cloud-oriented integration helpers and metadata-driven defaults for
Cuttlefish deployments.

%package -n ika-defaults
Summary:        Optional Cuttlefish defaults override file
Requires:       ika-base = %{version}-%{release}
Requires:       ika-integration = %{version}-%{release}
Provides:       cuttlefish-defaults = %{version}-%{release}
Obsoletes:      cuttlefish-defaults < %{version}-%{release}

%description -n ika-defaults
Provides an optional override file for Cuttlefish defaults in a standard Fedora
configuration path.

%package -n ika-metrics
Summary:        Metrics transmission support for Cuttlefish
Requires:       ika-base = %{version}-%{release}
Provides:       cuttlefish-metrics = %{version}-%{release}
Obsoletes:      cuttlefish-metrics < %{version}-%{release}

%description -n ika-metrics
Contains the metrics transmitter binary used by Cuttlefish.

%prep
%autosetup -n android-cuttlefish-%{version}

%build
case "%{_arch}" in
  x86_64) bazel_arch=k8 ;;
  aarch64) bazel_arch=aarch64 ;;
  *) echo "Unsupported architecture: %{_arch}" >&2; exit 1 ;;
esac

SOURCE_TARBALL="%{_sourcedir}/android-cuttlefish-%{version}.tar.gz"
if [[ ! -f base/cvd/adb/BUILD.bazel || ! -x base/cvd/tools/ensure_bazel_git_mirrors.sh ]]; then
  echo "Repairing incomplete extracted source tree from ${SOURCE_TARBALL}"
  tmp_cvd_extract="$(mktemp -d)"
  rm -rf base/cvd
  tar -xzf "${SOURCE_TARBALL}" -C "${tmp_cvd_extract}" \
    "android-cuttlefish-%{version}/base/cvd"
  if [[ ! -x "${tmp_cvd_extract}/android-cuttlefish-%{version}/base/cvd/tools/ensure_bazel_git_mirrors.sh" ]]; then
    echo "Source tarball ${SOURCE_TARBALL} does not contain base/cvd/tools/ensure_bazel_git_mirrors.sh." >&2
    echo "Regenerate ${SOURCE_TARBALL} with tools/buildutils/build_package.sh." >&2
    exit 1
  fi
  mkdir -p base
  mv "${tmp_cvd_extract}/android-cuttlefish-%{version}/base/cvd" base/cvd
  rm -rf "${tmp_cvd_extract}"
fi
if [[ ! -x base/cvd/tools/ensure_bazel_git_mirrors.sh ]]; then
  echo "Missing base/cvd/tools/ensure_bazel_git_mirrors.sh after source repair." >&2
  echo "Regenerate ${SOURCE_TARBALL} with tools/buildutils/build_package.sh." >&2
  exit 1
fi

{ set +x; } 2>/dev/null
readonly package_output_root="base/cvd/bazel-out/${bazel_arch}-opt/bin/cuttlefish/package"
pushd base/cvd >/dev/null
# Keep download/build caches persistent across rpmbuild runs so external
# repositories are fetched once and then reused on slow connections. Default
# under the repository's ika-work directory.
REPO_ROOT="$(realpath ../..)"
WORK_ROOT="${IKA_WORK_ROOT:-$REPO_ROOT/ika-work}"
BAZEL_CACHE_ROOT="${CUTTLEFISH_BAZEL_CACHE_ROOT:-$WORK_ROOT/cuttlefish-bazel}"
BAZEL_OUTPUT_USER_ROOT="${CUTTLEFISH_BAZEL_OUTPUT_USER_ROOT:-$WORK_ROOT}"
BAZEL_REPOSITORY_CACHE="$BAZEL_CACHE_ROOT/repository"
BAZEL_DISK_CACHE="$BAZEL_CACHE_ROOT/disk"
BAZEL_DISTDIR="$BAZEL_CACHE_ROOT/distdir"
BAZEL_TMPDIR="${CUTTLEFISH_BAZEL_TMPDIR:-$BAZEL_CACHE_ROOT/tmp}"
BAZEL_GIT_MIRROR_ROOT="$BAZEL_CACHE_ROOT/git-mirrors"
BAZEL_GIT_CONFIG="$BAZEL_CACHE_ROOT/gitconfig"
CARGO_BAZEL_TIMEOUT="${CARGO_BAZEL_TIMEOUT:-1800}"
mkdir -p "$BAZEL_OUTPUT_USER_ROOT" "$BAZEL_REPOSITORY_CACHE" "$BAZEL_DISK_CACHE" "$BAZEL_DISTDIR" "$BAZEL_TMPDIR" "$BAZEL_GIT_MIRROR_ROOT"
# Keep Bazel's output tree and crate_universe temp workspaces out of the
# rpmbuild BUILD directory. That directory is transient and can hit space
# limits while external git repos are materialized.
export TMPDIR="$BAZEL_TMPDIR"

# Shut down stale Bazel servers from earlier or concurrent builds that share
# this --output_user_root. Two servers racing on the shared caches and the
# in-tree sources trip --guard_against_concurrent_changes and cause transient
# "file not found" build failures.
CUTTLEFISH_BAZEL_OUTPUT_USER_ROOT="$BAZEL_OUTPUT_USER_ROOT" \
  ./tools/kill_stale_bazel_servers.sh || \
  echo "Warning: stale Bazel server cleanup failed; continuing." >&2

retry_count=0
max_retries=9
retry_delay=60
while true; do
  # Pre-populate mirrors for the most expensive and flaky git_repository
  # fetches so retries happen before the long Bazel build starts.
  if CUTTLEFISH_BAZEL_GIT_MIRROR_ROOT="$BAZEL_GIT_MIRROR_ROOT" \
    CUTTLEFISH_BAZEL_GIT_CONFIG="$BAZEL_GIT_CONFIG" \
    ./tools/ensure_bazel_git_mirrors.sh && \
    GIT_CONFIG_GLOBAL="$BAZEL_GIT_CONFIG" GIT_CONFIG_NOSYSTEM=1 \
    DISABLE_BAZEL_WRAPPER=yes USE_BAZEL_VERSION=8.5.1 \
    bazel --output_user_root="$BAZEL_OUTPUT_USER_ROOT" build -c opt \
    --noshow_loading_progress \
    --show_progress_rate_limit=30 \
    --progress_report_interval=30 \
    --ui_actions_shown=1 \
    --curses=no \
    --color=no \
    --repository_cache="$BAZEL_REPOSITORY_CACHE" \
    --disk_cache="$BAZEL_DISK_CACHE" \
    --distdir="$BAZEL_DISTDIR" \
    --cxxopt=-Wno-deprecated-declarations \
    --host_cxxopt=-Wno-deprecated-declarations \
    --cxxopt=-Wno-error=deprecated-declarations \
    --host_cxxopt=-Wno-error=deprecated-declarations \
    --cxxopt=-Wno-thread-safety-reference-return \
    --host_cxxopt=-Wno-thread-safety-reference-return \
    --conlyopt=-Wno-error=incompatible-pointer-types-discards-qualifiers \
    --host_conlyopt=-Wno-error=incompatible-pointer-types-discards-qualifiers \
    'cuttlefish/package:cvd' \
    'cuttlefish/package:defaults' \
    'cuttlefish/package:metrics' \
    --spawn_strategy=local \
    --repo_env=TMPDIR="$BAZEL_TMPDIR" \
    --repo_env=CARGO_BAZEL_TIMEOUT="$CARGO_BAZEL_TIMEOUT" \
    --repo_env=GIT_CONFIG_GLOBAL="$BAZEL_GIT_CONFIG" \
    --repo_env=GIT_CONFIG_NOSYSTEM=1 \
    --workspace_status_command=../stamp_helper.sh \
    --build_tag_filters=-clang-tidy; then
    break
  fi

  # If the build working tree has disappeared (e.g. the extracted source dir was
  # removed out from under us), retrying is futile and would just burn the
  # remaining attempts. Bail out immediately.
  if [[ ! -x ./tools/ensure_bazel_git_mirrors.sh ]]; then
    echo "Build working tree is gone (./tools/ensure_bazel_git_mirrors.sh missing); aborting without further retries." >&2
    exit 1
  fi

  retry_count=$((retry_count + 1))
  if [ "$retry_count" -ge "$max_retries" ]; then
    echo "Bazel build failed after ${retry_count} attempts." >&2
    exit 1
  fi

  echo "Bazel build failed, retrying in ${retry_delay}s (${retry_count}/${max_retries})..." >&2
  sleep "$retry_delay"
done
popd >/dev/null

# Build the scrcpy viewer (folded in from the former ika-scrcpy package). The
# prebuilt scrcpy-server APK is bundled in the source tarball at
# scrcpy/scrcpy-server (refreshed by tools/buildutils/build_package.sh).
meson setup scrcpy _build_scrcpy \
    --buildtype=release \
    --prefix=/usr/lib/cuttlefish-common \
    --bindir=bin \
    -Dprebuilt_server=scrcpy-server \
    -Dcompile_server=true
meson compile -C _build_scrcpy

%install
rm -rf %{buildroot}

case "%{_arch}" in
  x86_64) bazel_arch=k8 ;;
  aarch64) bazel_arch=aarch64 ;;
  *) echo "Unsupported architecture: %{_arch}" >&2; exit 1 ;;
esac

mkdir -p %{buildroot}/usr/lib
cp -a base/cvd/bazel-out/${bazel_arch}-opt/bin/cuttlefish/package/cuttlefish-common %{buildroot}/usr/lib/
mkdir -p %{buildroot}/usr/bin
cp -a base/cvd/bazel-out/${bazel_arch}-opt/bin/cuttlefish/package/cuttlefish-integration/bin/* %{buildroot}/usr/bin/
mkdir -p %{buildroot}/usr/lib/cuttlefish-metrics/bin
cp -a base/cvd/bazel-out/${bazel_arch}-opt/bin/cuttlefish/package/cuttlefish-metrics/bin/metrics_transmitter %{buildroot}/usr/lib/cuttlefish-metrics/bin/

# Install the scrcpy viewer (folded in from the former ika-scrcpy package) into
# the shared cuttlefish-common tree, then expose the "Ika" desktop launcher.
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

# Bazel package outputs are copied with their original mode bits, which can
# leave files read-only in BUILDROOT. Keep staging copies writable so any later
# packaging step can adjust them without mutating the source artifacts.
find %{buildroot}/usr/lib/cuttlefish-common \
     %{buildroot}/usr/lib/cuttlefish-metrics \
     %{buildroot}/usr/bin \
     \( -type f -o -type d \) -exec chmod u+w '{}' ';'

rm -rf %{buildroot}/usr/lib/cuttlefish-common/bin/cvd.repo_mapping
rm -rf %{buildroot}/usr/lib/cuttlefish-common/bin/cvd.runfiles*
rm -rf %{buildroot}/usr/lib/cuttlefish-common/bin/crosvm.repo_mapping
rm -rf %{buildroot}/usr/lib/cuttlefish-common/bin/crosvm.runfiles*
rm -rf %{buildroot}/usr/bin/cf_defaults.repo_mapping
rm -rf %{buildroot}/usr/bin/cf_defaults.runfiles*
rm -rf %{buildroot}/usr/lib/cuttlefish-metrics/bin/metrics_transmitter.repo_mapping
rm -rf %{buildroot}/usr/lib/cuttlefish-metrics/bin/metrics_transmitter.runfiles*

chmod -x %{buildroot}/usr/lib/cuttlefish-common/bin/*.json
chmod -x %{buildroot}/usr/lib/cuttlefish-common/bin/mke2fs.conf
find %{buildroot}/usr/lib/cuttlefish-common/etc -type f -exec chmod -x '{}' ';'
find %{buildroot}/usr/lib/cuttlefish-common/usr/share/webrtc/assets -type f -exec chmod -x '{}' ';'

install -Dpm0755 base/host/deploy/capability_query.py %{buildroot}/usr/lib/cuttlefish-common/bin/capability_query.py
install -Dpm0755 tools/getchromium %{buildroot}/usr/lib/cuttlefish-common/bin/getchromium
install -Dpm0755 tools/ika %{buildroot}/bin/ika
install -Dpm0644 base/host/packages/cuttlefish-base/etc/NetworkManager/conf.d/99-cuttlefish.conf %{buildroot}/etc/NetworkManager/conf.d/99-cuttlefish.conf
install -Dpm0644 base/rpm/99-cuttlefish.conf %{buildroot}/etc/sysctl.d/99-cuttlefish.conf
install -Dpm0644 base/host/packages/cuttlefish-base/etc/modules-load.d/cuttlefish-common.conf %{buildroot}/etc/modules-load.d/cuttlefish-common.conf
install -Dpm0644 base/host/packages/cuttlefish-base/etc/security/limits.d/1_cuttlefish.conf %{buildroot}/etc/security/limits.d/1_cuttlefish.conf
install -Dpm0755 base/rpm/cuttlefish-ulimit.sh %{buildroot}/etc/profile.d/cuttlefish-ulimit.sh
install -Dpm0644 base/rpm/70-cuttlefish-base.rules %{buildroot}/usr/lib/udev/rules.d/70-cuttlefish-base.rules
install -Dpm0644 base/rpm/cuttlefish-host-resources.service %{buildroot}/usr/lib/systemd/system/cuttlefish-host-resources.service
install -Dpm0755 base/rpm/cuttlefish-host-resources.sh %{buildroot}/usr/libexec/cuttlefish/cuttlefish-host-resources
install -Dpm0755 base/rpm/cuttlefish-add-user-to-groups.sh %{buildroot}/usr/libexec/cuttlefish/cuttlefish-add-user-to-groups
install -Dpm0644 base/rpm/cuttlefish-host-resources.sysconfig %{buildroot}/etc/sysconfig/cuttlefish-host-resources
install -Dpm0644 base/rpm/cuttlefish.xml %{buildroot}/etc/firewalld/zones/cuttlefish.xml
install -Dpm0644 base/rpm/cuttlefish-tmpfiles.conf %{buildroot}/usr/lib/tmpfiles.d/cuttlefish.conf

install -Dpm0644 base/rpm/71-cuttlefish-integration.rules %{buildroot}/usr/lib/udev/rules.d/71-cuttlefish-integration.rules
install -Dpm0644 base/host/packages/cuttlefish-integration/etc/modprobe.d/cuttlefish-integration.conf %{buildroot}/etc/modprobe.d/cuttlefish-integration.conf
install -Dpm0644 base/host/packages/cuttlefish-integration/etc/rsyslog.d/91-cuttlefish.conf %{buildroot}/etc/rsyslog.d/91-cuttlefish.conf
install -Dpm0644 base/host/packages/cuttlefish-integration/etc/ssh/sshd_config.cuttlefish %{buildroot}/etc/ssh/sshd_config.d/cuttlefish.conf
install -Dpm0644 base/rpm/cuttlefish-defaults.service %{buildroot}/usr/lib/systemd/system/cuttlefish-defaults.service
install -Dpm0755 base/rpm/cuttlefish-defaults.sh %{buildroot}/usr/libexec/cuttlefish/cuttlefish-defaults
install -Dpm0644 base/rpm/cuttlefish-integration.sysconfig %{buildroot}/etc/sysconfig/cuttlefish-integration

install -d %{buildroot}/etc/cuttlefish-common
: > %{buildroot}/etc/cuttlefish-common/cf_defaults

mkdir -p %{buildroot}/usr/lib/cuttlefish-common/bin/aarch64-linux-gnu
mkdir -p %{buildroot}/usr/lib/cuttlefish-common/bin/x86_64-linux-gnu
mkdir -p %{buildroot}/usr/lib/cuttlefish-common/lib64
ln -sfn ../graphics_detector %{buildroot}/usr/lib/cuttlefish-common/bin/aarch64-linux-gnu/gfxstream_graphics_detector
ln -sfn ../libvk_swiftshader.so %{buildroot}/usr/lib/cuttlefish-common/bin/aarch64-linux-gnu/libvk_swiftshader.so
ln -sfn ../graphics_detector %{buildroot}/usr/lib/cuttlefish-common/bin/x86_64-linux-gnu/gfxstream_graphics_detector
ln -sfn ../bin/libvk_swiftshader.so %{buildroot}/usr/lib/cuttlefish-common/lib64/vulkan.pastel.so

# Expose cvd on PATH to match upstream's /usr/bin/cvd symlink (Debian
# cuttlefish-base.links). Upstream docs and tooling assume `cvd` is invokable
# directly; without this symlink only the ika wrapper finds it.
install -d %{buildroot}/usr/bin
ln -sfn ../lib/cuttlefish-common/bin/cvd %{buildroot}/usr/bin/cvd

%post
if ! getent group cvdnetwork >/dev/null 2>&1; then
  groupadd -r cvdnetwork >/dev/null 2>&1 || :
fi
if ! getent group kvm >/dev/null 2>&1; then
  groupadd -r kvm >/dev/null 2>&1 || :
fi
mkdir -p /var/empty
systemd-tmpfiles --create /usr/lib/tmpfiles.d/cuttlefish.conf >/dev/null 2>&1 || :
setcap cap_net_admin,cap_net_bind_service,cap_net_raw=+ep /usr/lib/cuttlefish-common/bin/cvdalloc >/dev/null 2>&1 || :
/usr/sbin/sysctl --system >/dev/null 2>&1 || :
/usr/libexec/cuttlefish/cuttlefish-add-user-to-groups || :
udevadm control --reload >/dev/null 2>&1 || :
systemctl daemon-reload >/dev/null 2>&1 || :
# Enable host-resources so host setup runs on every boot -- notably tune_udmabuf,
# which raises the udmabuf caps the gfxstream Vulkan host-visible path needs (the
# sysfs params reset to kernel defaults each boot, so a one-shot does not stick).
# The service does no networking; guest networking is per-user cvdalloc.
systemctl enable --now cuttlefish-host-resources.service >/dev/null 2>&1 || :
required_nofile=524288
required_rtprio=10
current_soft_nofile="$(ulimit -Sn 2>/dev/null || echo 0)"
current_hard_nofile="$(ulimit -Hn 2>/dev/null || echo 0)"
current_soft_rtprio="$(ulimit -Sr 2>/dev/null || echo 0)"
current_hard_rtprio="$(ulimit -Hr 2>/dev/null || echo 0)"
case "$current_soft_nofile" in
  unlimited) current_soft_nofile="$required_nofile" ;;
esac
case "$current_hard_nofile" in
  unlimited) current_hard_nofile="$required_nofile" ;;
esac
case "$current_soft_rtprio" in
  unlimited) current_soft_rtprio="$required_rtprio" ;;
esac
case "$current_hard_rtprio" in
  unlimited) current_hard_rtprio="$required_rtprio" ;;
esac
if [ "${current_soft_nofile:-0}" -lt "$required_nofile" ] || \
   [ "${current_hard_nofile:-0}" -lt "$required_nofile" ] || \
   [ "${current_soft_rtprio:-0}" -lt "$required_rtprio" ] || \
   [ "${current_hard_rtprio:-0}" -lt "$required_rtprio" ]; then
  echo "Cuttlefish installed nofile=524288 and rtprio=10 for @cvdnetwork in /etc/security/limits.d/1_cuttlefish.conf." >&2
  echo "A new login session may be required before 'ulimit -n' and 'ulimit -r' reflect the higher limits." >&2
fi
# Reload firewalld to apply the cuttlefish zone (allows DHCP on bridge interfaces)
if systemctl is-active --quiet firewalld 2>/dev/null; then
  firewall-cmd --reload >/dev/null 2>&1 || :
fi

%posttrans
setcap cap_net_admin,cap_net_bind_service,cap_net_raw=+ep /usr/lib/cuttlefish-common/bin/cvdalloc >/dev/null 2>&1 || :

%post -n ika-defaults
systemctl daemon-reload >/dev/null 2>&1 || :

%preun
if [ $1 -eq 0 ]; then
  systemctl disable --now cuttlefish-host-resources.service >/dev/null 2>&1 || :
  # Reload firewalld to remove the cuttlefish zone on uninstall
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --reload >/dev/null 2>&1 || :
  fi
fi

%preun -n ika-defaults
if [ $1 -eq 0 ]; then
  systemctl disable --now cuttlefish-defaults.service >/dev/null 2>&1 || :
fi

%postun
systemctl daemon-reload >/dev/null 2>&1 || :

%postun -n ika-defaults
systemctl daemon-reload >/dev/null 2>&1 || :

%files
%license LICENSE
/bin/ika
/usr/bin/cvd
/usr/lib/cuttlefish-common
/usr/share/applications/ika-scrcpy.desktop
/usr/share/icons/hicolor/256x256/apps/ika-scrcpy.png
%config(noreplace) /etc/firewalld/zones/cuttlefish.xml
/etc/NetworkManager/conf.d/99-cuttlefish.conf
%config(noreplace) /etc/sysctl.d/99-cuttlefish.conf
/etc/modules-load.d/cuttlefish-common.conf
/etc/profile.d/cuttlefish-ulimit.sh
/etc/security/limits.d/1_cuttlefish.conf
/etc/sysconfig/cuttlefish-host-resources
/usr/lib/systemd/system/cuttlefish-host-resources.service
/usr/lib/tmpfiles.d/cuttlefish.conf
/usr/lib/udev/rules.d/70-cuttlefish-base.rules
/usr/libexec/cuttlefish/cuttlefish-host-resources
/usr/libexec/cuttlefish/cuttlefish-add-user-to-groups

%files -n ika-common
%license LICENSE

%files -n ika-integration
%license LICENSE
/usr/bin/cf_defaults
/etc/modprobe.d/cuttlefish-integration.conf
/etc/rsyslog.d/91-cuttlefish.conf
/etc/ssh/sshd_config.d/cuttlefish.conf
/usr/lib/udev/rules.d/71-cuttlefish-integration.rules

%files -n ika-defaults
%license LICENSE
%config(noreplace) /etc/cuttlefish-common/cf_defaults
/etc/sysconfig/cuttlefish-integration
/usr/lib/systemd/system/cuttlefish-defaults.service
/usr/libexec/cuttlefish/cuttlefish-defaults

%files -n ika-metrics
%license LICENSE
/usr/lib/cuttlefish-metrics

%changelog
* Mon Jul 13 2026 DesktopECHO <build@desktopecho.com> - 260713-1
- Update Ika host package metadata to 260713-1.

* Mon Jun 29 2026 DesktopECHO <build@desktopecho.com> - 260629-1
- Fold the scrcpy viewer into ika-base; the standalone ika-scrcpy package is
  retired (Provides/Obsoletes ika-scrcpy and cuttlefish-scrcpy).
* Sun Jun 28 2026 DesktopECHO <build@desktopecho.com> - 260628-6
- Update Cuttlefish host package metadata to 260628-6
