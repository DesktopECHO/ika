#!/usr/bin/env bash
# Rebuilds virtio-media.ko, the guest driver of crosvm's virtio-media devices
# (the hardware video decoder and cameras), from the ROM tree's patched
# external/virtio-media/driver for each GKI in kernel/prebuilts/6.12, and
# writes the binary patches that put the modules into
# kernel/prebuilts/common-modules/virtual-device/6.12.
#
# Google builds the module with the GKI, so a fixed driver needs that kernel:
# the script fetches its source (kernel/common at the commit in the module's
# vermagic) and the toolchain Google used (CLANG_VERSION in
# build.config.constants), and builds vmlinux with the config embedded in the
# prebuilt kernel. The kernel refuses a module whose symbol CRCs differ from
# its own; they come from the DWARF of the kernel's types (gendwarfksyms
# --stable, as Kleaf runs it), and the script fails unless every CRC matches
# the stock module's.
#
# Needs about 15 GB in WORK_DIR, and git, make, python3, pahole and openssl.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
overlay_dir="$(cd "$script_dir/.." && pwd)"
ika_root="$(cd "$overlay_dir/.." && pwd)"
workspace="${WORKSPACE:-$overlay_dir/src}"
work_dir="${WORK_DIR:-${IKA_WORK_ROOT:-$ika_root/ika-work}/virtio-media-module}"
patch_dir="$overlay_dir/patches"
jobs="${JOBS:-$(nproc)}"
kernel_remote="${KERNEL_REMOTE:-https://android.googlesource.com/kernel/common}"
clang_remote="${CLANG_REMOTE:-https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86}"
# The branch of clang_remote the kernel manifest syncs for android16-6.12.
clang_branch="${CLANG_BRANCH:-main-kernel-2025}"
modules_dir="kernel/prebuilts/common-modules/virtual-device/6.12"

usage() {
  cat <<'EOF'
Usage: build_virtio_media_module.sh [x86_64|arm64|arm64-16k|all]...

Builds virtio-media.ko from WORKSPACE/external/virtio-media/driver (with the
patch series applied) for each GKI variant, default all, and rewrites
lineageos/patches/kernel-prebuilts-virtual-device-{x86-64,arm64}-virtio-media.patch.

Environment: WORKSPACE (ROM source tree, default lineageos/src), WORK_DIR
(kernel source, toolchain and builds, default ika-work/virtio-media-module),
JOBS.
EOF
}

# To stderr: functions whose output is captured (fetch_clang) log too.
log() {
  printf '[lineage-desktop] virtio-media: %s\n' "$*" >&2
}

die() {
  printf '[lineage-desktop] virtio-media: error: %s\n' "$*" >&2
  exit 1
}

# Prints "<kernel ARCH> <prebuilt kernel image> <module project> <module path
# in the project>" for a variant.
variant_paths() {
  case "$1" in
    x86_64) echo "x86_64 kernel/prebuilts/6.12/x86_64/kernel-6.12 $modules_dir/x86-64 virtio-media.ko" ;;
    arm64) echo "arm64 kernel/prebuilts/6.12/arm64/kernel-6.12 $modules_dir/arm64 virtio-media.ko" ;;
    arm64-16k) echo "arm64 kernel/prebuilts/6.12/arm64/16k/kernel-6.12 $modules_dir/arm64 16k/virtio-media.ko" ;;
    *) return 1 ;;
  esac
}

# The kernel release a module was built for, from its vermagic.
module_release() {
  grep -a -o -m 1 'vermagic=[^ ]*' "$1" | cut -d= -f2
}

# Checks out kernel/common at the GKI commit of `release`.
fetch_kernel() {
  local release="$1" commit branch
  commit="$(sed -E 's/.*-g([0-9a-f]+)-.*/\1/' <<<"$release")"
  # 6.12.74-android16-6-g... is on android16-6.12.
  branch="$(sed -E 's/^([0-9]+\.[0-9]+)\.[0-9]+-(android[0-9]+)-.*/\2-\1/' <<<"$release")"
  if [[ ! -d "$work_dir/common/.git" ]]; then
    git init -q "$work_dir/common"
    git -C "$work_dir/common" remote add origin "$kernel_remote"
  fi
  if ! git -C "$work_dir/common" cat-file -e "$commit^{commit}" 2>/dev/null; then
    # The commit alone, by the full hash Gitiles gives for it: deepening a
    # shallow clone of kernel/common fails on android.googlesource.com (HTTP 500).
    local full
    full="$(curl -fsS "$kernel_remote/+/$commit?format=JSON" | sed 1d |
      python3 -c 'import json, sys; print(json.load(sys.stdin)["commit"])' 2>/dev/null)" || full=""
    if [[ -n "$full" ]]; then
      log "fetching $full from $kernel_remote"
      git -C "$work_dir/common" fetch -q --depth=1 origin "$full" || true
    fi
  fi
  if ! git -C "$work_dir/common" cat-file -e "$commit^{commit}" 2>/dev/null; then
    log "fetching $branch from $kernel_remote"
    git -C "$work_dir/common" fetch -q --depth=1 origin "$branch"
    local i
    for ((i = 0; i < 20; i++)); do
      git -C "$work_dir/common" cat-file -e "$commit^{commit}" 2>/dev/null && break
      git -C "$work_dir/common" fetch -q --deepen=1000 origin "$branch"
    done
  fi
  git -C "$work_dir/common" cat-file -e "$commit^{commit}" 2>/dev/null ||
    die "commit $commit not found on $branch"
  git -C "$work_dir/common" -c advice.detachedHead=false checkout -q "$commit"
}

# Checks out the CLANG_VERSION toolchain and prints its bin directory.
fetch_clang() {
  local version
  version="$(sed -n 's/^CLANG_VERSION=//p' "$work_dir/common/build.config.constants")"
  [[ -n "$version" ]] || die "no CLANG_VERSION in build.config.constants"
  if [[ ! -x "$work_dir/clang/clang-$version/bin/clang" ]]; then
    log "fetching clang-$version from $clang_remote ($clang_branch)"
    rm -rf "$work_dir/clang"
    git clone -q --depth=1 --filter=blob:none --sparse -b "$clang_branch" \
      "$clang_remote" "$work_dir/clang"
    git -C "$work_dir/clang" sparse-checkout set "clang-$version"
  fi
  [[ -x "$work_dir/clang/clang-$version/bin/clang" ]] || die "clang-$version not found"
  echo "$work_dir/clang/clang-$version/bin"
}

# Fails unless the symbols both modules import have the same CRCs.
check_crcs() {
  python3 - "$@" <<'EOF'
import struct, subprocess, sys, tempfile
objcopy, stock, built = sys.argv[1:4]
def crcs(ko):
    with tempfile.NamedTemporaryFile() as out:
        subprocess.run([objcopy, "-O", "binary", "--only-section=__versions", ko, out.name], check=True)
        data = open(out.name, "rb").read()
    # struct modversion_info: unsigned long crc; char name[56];
    return {data[i + 8:i + 64].split(b"\0")[0].decode(): struct.unpack_from("<Q", data, i)[0] & 0xffffffff
            for i in range(0, len(data), 64)}
a, b = crcs(stock), crcs(built)
bad = sorted(k for k in a.keys() & b.keys() if a[k] != b[k])
for k in bad:
    print("  %s: stock %08x, built %08x" % (k, a[k], b[k]), file=sys.stderr)
for k in sorted(b.keys() - a.keys()):
    print("  new symbol %s (%08x): check it is in the GKI symbol list" % (k, b[k]), file=sys.stderr)
print("  %d of %d symbol CRCs match the stock module" % (len(a.keys() & b.keys()) - len(bad), len(b)), file=sys.stderr)
sys.exit(1 if bad else 0)
EOF
}

build_variant() {
  local variant="$1" arch kernel_image project path release localversion clang_bin out module stock
  read -r arch kernel_image project path < <(variant_paths "$variant") || die "unknown variant: $variant"
  # The module the project ships, before the patch series replaced it.
  stock="$work_dir/stock-$variant.ko"
  git -C "$workspace/$project" show "HEAD:$path" >"$stock"
  release="$(module_release "$stock")"
  [[ -n "$release" ]] || die "no vermagic in the stock $variant module"
  localversion="-${release#*-}"
  log "$variant: building the GKI $release"

  fetch_kernel "$release"
  clang_bin="$(fetch_clang)"
  out="$work_dir/out-$variant"
  mkdir -p "$out"

  local -a make_args=(-C "$work_dir/common" O="$out" ARCH="$arch" LLVM=1 LLVM_IAS=1
    LOCALVERSION= -j"$jobs")
  # The GKI config, but without Rust (it needs Android's rustc), LTO (slow; it
  # changes no CRC) and the lists Kleaf generates (exports trimmed to the symbol
  # list, protected modules), and with the release string of the prebuilt kernel.
  "$work_dir/common/scripts/extract-ikconfig" "$workspace/$kernel_image" >"$out/.config.new" 2>/dev/null ||
    die "no config in $kernel_image"
  if ! cmp -s "$out/.config.new" "$out/.config.gki"; then
    cp "$out/.config.new" "$out/.config.gki"
    cp "$out/.config.new" "$out/.config"
    "$work_dir/common/scripts/config" --file "$out/.config" \
      --disable RUST --disable LTO_CLANG_THIN --disable LTO_CLANG_FULL --enable LTO_NONE \
      --disable TRIM_UNUSED_KSYMS --set-str MODULE_SIG_PROTECT_LIST "" \
      --disable WERROR --disable LOCALVERSION_AUTO --set-str LOCALVERSION "$localversion"
  fi
  # Kleaf's CRCs: about half of them differ without it.
  export KBUILD_GENDWARFKSYMS_STABLE=1
  # Fedora's crypto policy refuses the SHA-1 module signing key the GKI config asks for.
  export OPENSSL_ENABLE_SHA1_SIGNATURES=1
  PATH="$clang_bin:$PATH" make "${make_args[@]}" olddefconfig >/dev/null
  PATH="$clang_bin:$PATH" make "${make_args[@]}" -s vmlinux modules_prepare
  [[ "$(PATH="$clang_bin:$PATH" make "${make_args[@]}" -s kernelrelease)" == "$release" ]] ||
    die "$variant: kernel release does not match $release"
  cp "$out/vmlinux.symvers" "$out/Module.symvers"

  module="$work_dir/module-$variant"
  rm -rf "$module"
  cp -r "$workspace/external/virtio-media/driver" "$module"
  PATH="$clang_bin:$PATH" make "${make_args[@]}" -s M="$module" modules
  "$clang_bin/llvm-strip" --strip-debug "$module/virtio-media.ko"

  check_crcs "$clang_bin/llvm-objcopy" "$stock" "$module/virtio-media.ko" ||
    die "$variant: symbol CRCs differ from the stock module's: wrong toolchain or config?"
  [[ "$(module_release "$module/virtio-media.ko")" == "$release" ]] || die "$variant: vermagic differs"
  log "$variant: $module/virtio-media.ko"
}

# Writes the binary patch replacing virtio-media.ko in one prebuilt project.
write_patch() {
  local project="$1" name="$2" index blob
  shift 2
  index="$(mktemp)"
  rm -f "$index"
  GIT_INDEX_FILE="$index" git -C "$workspace/$project" read-tree HEAD
  local entry
  for entry in "$@"; do
    blob="$(git -C "$workspace/$project" hash-object -w "${entry#*=}")"
    GIT_INDEX_FILE="$index" git -C "$workspace/$project" update-index \
      --cacheinfo "100644,$blob,${entry%%=*}"
  done
  {
    echo "Patch summary: replaces virtio-media.ko with the driver of"
    echo "external-virtio-media-driver-queue-state.patch, rebuilt for the same GKI"
    echo "by lineageos/scripts/build_virtio_media_module.sh."
    echo
    GIT_INDEX_FILE="$index" git -C "$workspace/$project" diff --cached --binary --full-index HEAD
  } >"$patch_dir/$name"
  rm -f "$index"
  log "wrote $patch_dir/$name"
}

main() {
  local -a variants=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      -h|--help) usage; return 0 ;;
      all) variants+=(x86_64 arm64 arm64-16k) ;;
      x86_64|arm64|arm64-16k) variants+=("$arg") ;;
      *) usage >&2; return 2 ;;
    esac
  done
  ((${#variants[@]})) || variants=(x86_64 arm64 arm64-16k)
  [[ -f "$workspace/external/virtio-media/driver/virtio_media_driver.c" ]] ||
    die "no virtio-media driver in $workspace/external/virtio-media"
  mkdir -p "$work_dir"

  local variant
  for variant in "${variants[@]}"; do
    build_variant "$variant"
  done

  if [[ " ${variants[*]} " == *" x86_64 "* ]]; then
    write_patch "$modules_dir/x86-64" kernel-prebuilts-virtual-device-x86-64-virtio-media.patch \
      "virtio-media.ko=$work_dir/module-x86_64/virtio-media.ko"
  fi
  if [[ " ${variants[*]} " == *" arm64 "* && " ${variants[*]} " == *" arm64-16k "* ]]; then
    write_patch "$modules_dir/arm64" kernel-prebuilts-virtual-device-arm64-virtio-media.patch \
      "virtio-media.ko=$work_dir/module-arm64/virtio-media.ko" \
      "16k/virtio-media.ko=$work_dir/module-arm64-16k/virtio-media.ko"
  fi
}

main "$@"
