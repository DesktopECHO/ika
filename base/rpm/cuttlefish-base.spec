# The version comes from packaging/VERSION; tools/buildutils/build_package.sh
# passes it as ika_version.
%{!?ika_version:%{error:ika_version is not defined; build with tools/buildutils/build_package.sh}}
Name:           ika-base
Version:        %{ika_version}
Release:        1%{?dist}
Summary:        Cuttlefish Android Virtual Device host packages for Fedora
License:        Apache-2.0
URL:            https://github.com/google/android-cuttlefish
Source0:        ika-base-%{version}.tar.gz
# objcopy/nm (find-debuginfo) can't parse the Bazel/Clang-built binaries; skip debug packaging.
%global debug_package %{nil}
# Fedora 44's GNU strip also cannot parse some Bazel/Clang-built Cuttlefish
# binaries, so skip the automatic brp strip passes for this package.
%global __brp_strip %{nil}
%global __brp_strip_comment_note %{nil}
%global __brp_strip_lto %{nil}
# The shared libraries under /usr/lib/cuttlefish-common are private to the
# host tools, found by rpath or dlopen, so they must not satisfy other
# packages' dependencies. A bundled libvirglrenderer.so.1 would otherwise
# stand in for Fedora's virglrenderer, which crosvm links.
%global __provides_exclude_from ^/usr/lib/cuttlefish-common/.*$
# Sonames that only the bundled copies provide. libvirglrenderer.so.1 stays,
# because crosvm links Fedora's virglrenderer; the unversioned
# libvirglrenderer.so comes from the bundled, SONAME-less copy that upstream
# packages for Venus, and only virglrenderer-devel would provide it.
%global __requires_exclude ^((libgfxstream_backend|libvk_swiftshader|libvk_lavapipe|libmem_overrides)\\.so|libvirglrenderer\\.so\\(\\))

BuildRequires:  libaom-devel
BuildRequires:  clang-devel
BuildRequires:  boost-devel >= 1.88
BuildRequires:  cmake
BuildRequires:  fmt-devel
BuildRequires:  fuse3-devel
BuildRequires:  gcc-c++
BuildRequires:  gflags-devel
BuildRequires:  git
BuildRequires:  libtool
BuildRequires:  glog-devel
BuildRequires:  gtest-devel
BuildRequires:  jsoncpp-devel
BuildRequires:  libX11-devel
BuildRequires:  libXcursor-devel
BuildRequires:  libXext-devel
BuildRequires:  libXfixes-devel
BuildRequires:  libXi-devel
BuildRequires:  libXrandr-devel
BuildRequires:  libXScrnSaver-devel
BuildRequires:  libcurl-devel
BuildRequires:  libxkbcommon-devel
BuildRequires:  pkgconfig(libv4l2)
BuildRequires:  libcap-devel
BuildRequires:  libdecor-devel
BuildRequires:  libdrm-devel
BuildRequires:  libva-devel
BuildRequires:  libicu-devel
BuildRequires:  libxcrypt-compat
BuildRequires:  libuuid-devel
BuildRequires:  libxml2-devel
BuildRequires:  libsrtp-devel
BuildRequires:  opus-devel
BuildRequires:  openssl-devel
BuildRequires:  perl-FindBin
BuildRequires:  pkgconf-pkg-config
BuildRequires:  protobuf-c-devel
BuildRequires:  protobuf-compiler
BuildRequires:  protobuf-devel
BuildRequires:  python3
BuildRequires:  systemd-rpm-macros
BuildRequires:  systemd-devel
BuildRequires:  mesa-libgbm-devel
BuildRequires:  virglrenderer-devel
BuildRequires:  vulkan-headers
BuildRequires:  wayland-devel
BuildRequires:  wayland-protocols-devel
BuildRequires:  which
BuildRequires:  xxd
BuildRequires:  xz-devel
BuildRequires:  z3-devel
# scrcpy viewer (Meson C build), folded into ika-base.
BuildRequires:  meson
BuildRequires:  nasm
BuildRequires:  ninja-build
BuildRequires:  wget
BuildRequires:  pkgconfig(gl)
BuildRequires:  alsa-lib-devel
BuildRequires:  pipewire-devel
# Ika's WSL2 helpers (tools/wsl): a Vulkan layer, a libd3d12.so shim, Mesa's
# Dozen driver and libdecor's GTK plugin. See GRAPHICS.md, "WSL2".
BuildRequires:  pkgconfig(DirectX-Headers)
BuildRequires:  python3-mako
BuildRequires:  python3-packaging
BuildRequires:  python3-pyyaml
BuildRequires:  pkgconfig(gtk+-3.0)
BuildRequires:  pkgconfig(xcb)
BuildRequires:  pkgconfig(x11-xcb)
BuildRequires:  pkgconfig(xcb-dri3)
BuildRequires:  pkgconfig(xcb-present)
BuildRequires:  pkgconfig(xcb-sync)
BuildRequires:  pkgconfig(xcb-xfixes)
BuildRequires:  pkgconfig(xcb-randr)
BuildRequires:  pkgconfig(xcb-shm)
BuildRequires:  pkgconfig(xcb-keysyms)
BuildRequires:  pkgconfig(xshmfence)
BuildRequires:  pkgconfig(dbus-1)
BuildRequires:  pkgconfig(zlib)
BuildRequires:  pkgconfig(libudev)
BuildRequires:  pkgconfig(wayland-cursor)

Requires:       acl
Requires:       bsdtar
Requires:       curl
# ika app sync edits desktop menu launchers.
Requires:       desktop-file-utils
# ika app reports progress and errors from menu launchers with notify-send.
Requires:       libnotify
Requires:       dnsmasq
Requires:       iproute
Requires:       libX11
Requires:       libXext
Requires:       lz4
Requires:       lsof
Requires:       mesa-libgbm >= 26.1
Requires:       mesa-libGL >= 26.1
Requires:       glx-utils
Requires:       mesa-vulkan-drivers >= 26.1
Requires:       vulkan-tools
Requires:       net-tools
Requires:       NetworkManager
Requires:       nftables
Requires:       openssl
# ika backup compresses with pigz.
Requires:       pigz
# madbfs mounts Android's storage on the host.
Requires:       fuse3
Requires:       python3
Requires:       python3-requests
Requires:       v4l-utils
# vainfo: ika start checks the host's VA-API decoders.
Requires:       libva-utils
# Fedora's Mesa and Intel iHD VA-API drivers leave out H.264 and HEVC (its
# i965 driver for Haswell and older Intel GPUs decodes H.264). RPM Fusion's
# builds put them back, installed beside Fedora's; dnf pulls them in only when
# the RPM Fusion repositories are enabled and skips them otherwise. Fedora 44
# ships Mesa's VA-API driver in mesa-dri-drivers; there is no mesa-va-drivers.
Recommends:     (mesa-va-drivers-freeworld if mesa-dri-drivers)
Recommends:     (intel-media-driver if libva-intel-media-driver)
Requires:       xdg-utils
# The Startup Options windows (ika app --options, ika options): python3's GTK 3
# bindings draw them, native on Wayland and X11; yad draws its dialogs and a tab
# as a window of its own when the bindings are missing.
Requires:       python3-gobject
Requires:       gtk3
Requires:       yad
# Linked library dependencies are generated from ELF SONAMEs. Keep only the
# scrcpy runtime tools that RPM cannot discover from the packaged binaries.
Requires:       wayland-utils
# SDL loads libdecor at runtime; its GTK plugin (in the libdecor package) draws
# GNOME Wayland title bars in the system light/dark theme.
Requires:       libdecor

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
%autosetup -n ika-base-%{version}

%build
case "%{_arch}" in
  x86_64) bazel_arch=k8 ;;
  aarch64) bazel_arch=aarch64 ;;
  *) echo "Unsupported architecture: %{_arch}" >&2; exit 1 ;;
esac

SOURCE_TARBALL="%{_sourcedir}/ika-base-%{version}.tar.gz"
if [[ ! -f base/cvd/adb/BUILD.bazel || ! -x base/cvd/tools/ensure_bazel_git_mirrors.sh ]]; then
  echo "Repairing incomplete extracted source tree from ${SOURCE_TARBALL}"
  tmp_cvd_extract="$(mktemp -d)"
  rm -rf base/cvd
  tar -xzf "${SOURCE_TARBALL}" -C "${tmp_cvd_extract}" \
    "ika-base-%{version}/base/cvd"
  if [[ ! -x "${tmp_cvd_extract}/ika-base-%{version}/base/cvd/tools/ensure_bazel_git_mirrors.sh" ]]; then
    echo "Source tarball ${SOURCE_TARBALL} does not contain base/cvd/tools/ensure_bazel_git_mirrors.sh." >&2
    echo "Regenerate ${SOURCE_TARBALL} with tools/buildutils/build_package.sh." >&2
    exit 1
  fi
  mkdir -p base
  mv "${tmp_cvd_extract}/ika-base-%{version}/base/cvd" base/cvd
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
SCRCPY_DEPS_WORK_DIR="$WORK_ROOT/scrcpy-deps"
SCRCPY_STATIC_DEPS="$SCRCPY_DEPS_WORK_DIR/install/linux-native-static"
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

SCRCPY_DEPS_WORK_DIR="$SCRCPY_DEPS_WORK_DIR" ../../scrcpy/app/deps/libusb.sh linux native static
SCRCPY_DEPS_WORK_DIR="$SCRCPY_DEPS_WORK_DIR" ../../scrcpy/app/deps/sdl.sh linux native static
SCRCPY_DEPS_WORK_DIR="$SCRCPY_DEPS_WORK_DIR" ../../scrcpy/app/deps/dav1d.sh linux native static
SCRCPY_DEPS_WORK_DIR="$SCRCPY_DEPS_WORK_DIR" ../../scrcpy/app/deps/ffmpeg.sh linux native static

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
    'cuttlefish/package:common' \
    'cuttlefish/package:defaults' \
    'cuttlefish/package:metrics' \
    --spawn_strategy=local \
    --repo_env=TMPDIR="$BAZEL_TMPDIR" \
    --repo_env=CARGO_BAZEL_TIMEOUT="$CARGO_BAZEL_TIMEOUT" \
    --repo_env=GIT_CONFIG_GLOBAL="$BAZEL_GIT_CONFIG" \
    --repo_env=GIT_CONFIG_NOSYSTEM=1 \
    --action_env=PKG_CONFIG_PATH="$SCRCPY_STATIC_DEPS/lib/pkgconfig" \
    --action_env=LIBAVCODEC_STATIC=1 \
    --action_env=LIBAVUTIL_STATIC=1 \
    --action_env=LIBSWSCALE_STATIC=1 \
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
if readelf -d bazel-bin/cuttlefish/package/cuttlefish-common/bin/crosvm | grep -Eq 'Shared library: \[(libav|libsw)'; then
  echo "Error: crosvm still has a shared FFmpeg dependency" >&2
  readelf -d bazel-bin/cuttlefish/package/cuttlefish-common/bin/crosvm | grep 'Shared library' >&2
  exit 1
fi
popd >/dev/null

# Build the scrcpy viewer (folded in from the former ika-scrcpy package). The
# prebuilt scrcpy-server APK is bundled in the source tarball at
# scrcpy/scrcpy-server (refreshed by tools/buildutils/build_package.sh).
meson setup scrcpy _build_scrcpy \
  --pkg-config-path="$SCRCPY_STATIC_DEPS/lib/pkgconfig" \
  -Dc_args="-I$SCRCPY_STATIC_DEPS/include" \
  -Dc_link_args="-L$SCRCPY_STATIC_DEPS/lib" \
    --buildtype=release \
    --prefix=/usr/lib/cuttlefish-common \
    --bindir=bin \
    -Dstatic=true \
    -Dprebuilt_server=scrcpy-server \
    -Dcompile_server=true
meson compile -C _build_scrcpy
if readelf -d _build_scrcpy/app/scrcpy | grep -Eq 'Shared library: \[(libav|libsw)'; then
  echo "Error: scrcpy still has a shared FFmpeg dependency" >&2
  readelf -d _build_scrcpy/app/scrcpy | grep 'Shared library' >&2
  exit 1
fi

# madbfs, which mounts Android's storage on the host; its server is
# built into the ROM. See lineageos/tools/madbfs/README.md.
cmake -S lineageos/tools/madbfs -B _build_madbfs -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build _build_madbfs

# Ika's WSL2 helpers. See GRAPHICS.md, "WSL2".
make -C tools/wsl BUILD="$PWD/_build_wsl" DOWNLOADS="$WORK_ROOT/wsl-downloads"

%install
rm -rf %{buildroot}

case "%{_arch}" in
  x86_64) bazel_arch=k8 ;;
  aarch64) bazel_arch=aarch64 ;;
  *) echo "Unsupported architecture: %{_arch}" >&2; exit 1 ;;
esac

mkdir -p %{buildroot}/usr/lib
cp -a base/cvd/bazel-out/${bazel_arch}-opt/bin/cuttlefish/package/cuttlefish-common %{buildroot}/usr/lib/
# Bazel leaves its tree artifacts read-only; more files are installed below.
chmod -R u+w %{buildroot}/usr/lib/cuttlefish-common
# Upstream's host package ships etc/cvd_config, which Ika's ROM package
# already provides through the link ika-lineageos makes at
# etc/cvd_config. Leave it to the ROM so the two packages don't both
# claim those files.
rm -rf %{buildroot}/usr/lib/cuttlefish-common/etc/cvd_config
mkdir -p %{buildroot}/usr/bin
cp -a base/cvd/bazel-out/${bazel_arch}-opt/bin/cuttlefish/package/cuttlefish-integration/bin/* %{buildroot}/usr/bin/
mkdir -p %{buildroot}/usr/lib/cuttlefish-metrics/bin
cp -a base/cvd/bazel-out/${bazel_arch}-opt/bin/cuttlefish/package/cuttlefish-metrics/bin/metrics_transmitter %{buildroot}/usr/lib/cuttlefish-metrics/bin/

# Install the scrcpy viewer (folded in from the former ika-scrcpy package) into
# the shared cuttlefish-common tree, then expose the "Ika" desktop launcher.
DESTDIR=%{buildroot} meson install -C _build_scrcpy
make -C tools/wsl BUILD="$PWD/_build_wsl" DESTDIR=%{buildroot} install
install -m 0755 _build_madbfs/upstream/madbfs/madbfs _build_madbfs/upstream/madbfs-msg/madbfs-msg \
  %{buildroot}/usr/lib/cuttlefish-common/bin/

install -d %{buildroot}/usr/share/applications
install -d %{buildroot}/usr/share/icons/hicolor/256x256/apps

install -m 0644 tools/ika.desktop %{buildroot}/usr/share/applications/ika.desktop
install -m 0644 tools/ika-install.desktop %{buildroot}/usr/share/applications/ika-install.desktop
install -m 0644 tools/ika-startup-options.desktop %{buildroot}/usr/share/applications/ika-startup-options.desktop
install -m 0644 \
  %{buildroot}/usr/lib/cuttlefish-common/share/icons/hicolor/256x256/apps/scrcpy.png \
  %{buildroot}/usr/share/icons/hicolor/256x256/apps/ika-scrcpy.png
# WSLg looks for icons up to 128x128 only.
install -Dm 0644 tools/ika-scrcpy-128.png \
  %{buildroot}/usr/share/icons/hicolor/128x128/apps/ika-scrcpy.png

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
install -Dpm0755 tools/ika-root %{buildroot}/usr/lib/cuttlefish-common/bin/ika-root
install -Dpm0755 tools/ika-wsl-setup %{buildroot}/usr/bin/ika-wsl-setup
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
# The rules for these devices ran when they appeared, before this package (or
# this version of it) was installed, or in another WSL2 distribution: run them
# again for its groups and ACL entries.
udevadm trigger --action=add --subsystem-match=misc --sysname-match=kvm \
  --sysname-match=vhost-net --sysname-match=vhost-vsock >/dev/null 2>&1 || :
udevadm settle >/dev/null 2>&1 || :
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
/usr/bin/ika-wsl-setup
/usr/bin/cvd
/usr/lib/cuttlefish-common
/usr/share/applications/ika.desktop
/usr/share/applications/ika-install.desktop
/usr/share/applications/ika-startup-options.desktop
/usr/share/icons/hicolor/256x256/apps/ika-scrcpy.png
/usr/share/icons/hicolor/128x128/apps/ika-scrcpy.png
/usr/share/vulkan/implicit_layer.d/VK_LAYER_IKA_dzn_fix.json
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
* Fri Oct 23 2026 DesktopECHO <build@desktopecho.com> - 261023-1
- Add a low-CPU mode for weak hosts (30 Hz display, no window blurs,
  half-length animations), and let the display follow the host's refresh rate
  outside it.
- Give every app's menu entry a "Startup options" window, and Ika's own (ika
  options): fullscreen, keyboard, mouse, gamepad and touch input, a display
  density per app, and for Ika the CPUs, RAM, GPU mode and camera.
- Make the keyboard gamepad behave as a physical one, with analog sticks, the
  mouse as a stick and a key mapping per game; connect a window's gamepads
  only while it has the focus; offer it in TV mode (tv_keyboard_gamepad).
- Open Desktop/TV in a window of its own.
- Say in ika status how the console's frames travel, and log their latency
  with IKA_LATENCY=1.
- Start in gfxstream with OpenGL ES only where gfxstream would pick llvmpipe
  over the GPU (a Haswell GPU).
- Update gfxstream to upstream main of 2026-10-19; keep no idle host copy of
  each guest color buffer and give the renderer's freed heap back after an app
  exits.
- Emulate only linear-tiled ASTC where the host samples ASTC with optimal
  tiling only (Apple silicon), so that textures cost their compressed size.
- Add host_cached_memory for gfxstream's host-visible Vulkan memory.
- Log a video decode error in crosvm's virtio-media decoder and carry on,
  instead of aborting the VM.
- Use Wayland windows on Wayland sessions and X11 windows on X11 sessions.
- Install Chromium without launching it.
- Recover from a host crash that leaves a truncated cuttlefish_config.json,
  and bring the desktop console back as it was after a round trip through TV
  mode.

* Sun Oct 18 2026 DesktopECHO <build@desktopecho.com> - 261018-1
- Update the host tools to the Cuttlefish 1.58 development head.
- Give Android a VA-API video decoder (crosvm --media-decoder=vaapi) when
  the host has a working VA-API driver; hw_video_decode in ika.ini turns it
  off. Depend on vainfo and recommend RPM Fusion's VA-API drivers on Fedora.
- Take compressed frames of up to 8 MB in crosvm's video decoder, and size
  its picture buffers at the visible size (no green band on 1080p video).
- Set the anti-flicker of a camera passed with --camera to the local mains
  frequency ([camera] power_line_frequency in ika.ini).
- Use SkiaVK for Android's UI in the gfxstream ANGLE modes.
- Recover the stale cvd group after a stop and wait out slow boots.
- Disconnect adb on stop; keep 24 hours of the adb log and the last 1,000
  lines of ikastart.log and madbfs.log.
- Open the console at Android's first frame, and cache host probes between
  launches.
- Back guest memory with transparent huge pages.
- Handle EVENT_IDX in vhost-user input, advertise framebuffer fetch only
  when the host has it exactly, and match the guest's GLES version and Vulkan
  driver to the host.
- Fix installing on Fedora (libvirglrenderer.so) and upgrade conflicts over
  etc/cvd_config.

* Fri Oct 16 2026 DesktopECHO <build@desktopecho.com> - 261016-1
- Show app windows on Cuttlefish displays of their own, with the VM's frames
  instead of a video stream; drop VA-API decoding from the display client.
- Follow Android's TV mode in the console: fullscreen, the gamepad as the
  remote, a right click for Back, at 1.5 times the automatic density
  (tv_dpi in ika.ini).
- Keep Ika's defaults in ~/ika/ika.ini, written when missing.
- Add 'ika install' and 'ika remove', and Install in Ika for APK files.
- Add 'ika backup' and 'ika restore'.
- Mount Android's shared storage on ~/ika/Android.
- Talk to Android over native vsock adb.
- Keep pid and lock files in ~/ika/tmp, and the Chromium and Magisk APKs in
  ~/ika/apps.
- Close app windows when Android restarts.
- Fix 'ika reset' crashing GNOME Shell.
- Never block crosvm's GPU worker on a Wayland dispatch, and stop
  advertising host image copy in gfxstream.

* Mon Oct 12 2026 DesktopECHO <build@desktopecho.com> - 261012-1
- Add 'ika root' to root the VM with Magisk, on user and userdebug builds.
- Add 'ika gsf' to show the GSF ID and open Google's uncertified device page.
- Give each device its own serial number, kept across factory resets.
- Add Stop, Restart and Start with Camera to the launcher's right-click
  menu; "Start Ika" replaces "New Window".
- Keep the Chromium APK in ~/ika and skip Chromium's first-run screens.
- Fix starts failing with "Startup Failed." right after a VM stops.
- Fix flashing hanging on x86 VMs with 2 GB of RAM.
- Stop factory resets from filling the host disk.
- Prefer integrated GPUs over CPU Vulkan devices.
- Copy console frames straight into the client's shared memory.
- Detect the display size from DRM when wayland-info finds none, and
  default to 144 DPI otherwise.
- Update crosvm, gfxstream, minigbm and Mesa.
- Pass a host camera to Android with 'ika start --camera'; depend on
  v4l-utils.
- Rebuild the display client on scrcpy 5.0.1.
- Blur the last picture while a window is resized, and move the console's
  resize edges outside the window.
- Decode app window video on the GPU through VA-API where supported.
- Fix clicks in app windows on displays with fractional scaling.
- Fix lost GLES textures on Apple Silicon and pink video playback.
- Default to the gfxstream GPU mode with only a software Vulkan driver.
- Install a Chromium that starts without hardware Vulkan where needed.
- Put new apps in the "Android Apps (Ika)" folder, show notifications on
  every desktop (depend on notify-send) and give app windows their app's
  icon; the desktop entry is now ika.desktop.
- Pass ~/.android/adbkey to user builds so ADB works with authentication.
- Lengthen the boot timeout for older systems.
- Build against pinned static FFmpeg 9.0.2, SDL 3.4.18 and libusb.

* Thu Sep 24 2026 DesktopECHO <build@desktopecho.com> - 260924-1
- Update Ika host package metadata to 260924-1.

* Sat Aug 22 2026 DesktopECHO <build@desktopecho.com> - 260822-1
- Update Ika host package metadata to 260822-1.

* Wed Aug 19 2026 DesktopECHO <build@desktopecho.com> - 260819-1
- Update Ika host package metadata to 260819-1.

* Sun Jul 26 2026 DesktopECHO <build@desktopecho.com> - 260726-1
- Update Ika host package metadata to 260726-1.

* Mon Jul 20 2026 DesktopECHO <build@desktopecho.com> - 260720-1
- Upgrade bundled host Lavapipe to Mesa 26.1.5 and validate the Vulkan ICD.
- Keep scrcpy and crosvm compatible with either Fedora or RPM Fusion FFmpeg.

* Sun Jul 19 2026 DesktopECHO <build@desktopecho.com> - 260719-1
- Update Ika host package metadata to 260719-1.

* Mon Jul 13 2026 DesktopECHO <build@desktopecho.com> - 260713-1
- Update Ika host package metadata to 260713-1.

* Mon Jun 29 2026 DesktopECHO <build@desktopecho.com> - 260629-1
- Fold the scrcpy viewer into ika-base; the standalone ika-scrcpy package is
  retired (Provides/Obsoletes ika-scrcpy and cuttlefish-scrcpy).
* Sun Jun 28 2026 DesktopECHO <build@desktopecho.com> - 260628-6
- Update Cuttlefish host package metadata to 260628-6
