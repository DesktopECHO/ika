#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
overlay_dir="$(cd "$script_dir/../.." && pwd)"
manifest="$overlay_dir/manifests/lineageos-desktop.xml"
output="$overlay_dir/patches/external-mesa3d.patch"
honeykrisp_patch="$overlay_dir/patches/external-mesa3d-honeykrisp-android.patch"
config="$script_dir/aosp_mesa3d.toml"
release="$overlay_dir/../tools/mesa/release.env"

usage() {
  cat <<'EOF'
Usage: regenerate.sh MESA_REPO MESON2HERMETIC_CHECKOUT

Pin external/mesa3d in src/lineageos/manifests/lineageos-desktop.xml to the
Mesa release in src/tools/mesa/release.env, and regenerate
src/lineageos/patches/external-mesa3d.patch, the Android build integration for
it. The patch removes Mesa's android/Android.mk, which Soong's Android.mk
denylist rejects under external/, and adds the Android.bp files meson2hermetic
generates from Mesa's meson.build files with aosp_mesa3d.toml (next to this
script).

MESA_REPO is any Mesa git repository that has the release's tag
(mesa-MESA_VERSION); the script works in a temporary worktree of it. MESON2HERMETIC_CHECKOUT is a checkout of
https://github.com/mesonbuild/meson/pull/15462 (Python 3.11 or newer).

The Apple Vulkan driver (Honeykrisp, vulkan.asahi) needs shader kernels that
Mesa compiles from OpenCL with its own tools, which the Android build cannot
run. The script builds them here with a native Mesa build and adds the
results to the patch, so this host needs what that build needs: meson 1.5 or
newer, ninja, a C and C++ compiler, and the development files of LLVM and
Clang, the SPIRV-LLVM translator, SPIRV-Tools and libclc.

Ika's own Mesa fixes are separate patches in src/lineageos/patches/series and
are not touched. external-mesa3d-honeykrisp-android.patch adds a source file,
so the script applies it before converting and leaves it out of the patch it
writes; the others do not change which build files are generated.
EOF
}

log() {
  printf '[lineage-desktop] %s\n' "$*"
}

die() {
  printf '[lineage-desktop] error: %s\n' "$*" >&2
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
(( $# == 2 )) || { usage >&2; exit 2; }

mesa_repo="$(cd "$1" && pwd)"
meson_dir="$(cd "$2" && pwd)"
[[ -f "$meson_dir/meson.py" ]] || die "no meson.py in $meson_dir"
[[ -f "$config" ]] || die "missing $config"
[[ -f "$honeykrisp_patch" ]] || die "missing $honeykrisp_patch"

# shellcheck source=../../../tools/mesa/release.env
source "$release"
[[ "$MESA_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "no MESA_COMMIT in $release"
tag_commit="$(git -C "$mesa_repo" rev-parse --verify --quiet "refs/tags/mesa-$MESA_VERSION^{commit}")" ||
  die "$mesa_repo does not have the tag mesa-$MESA_VERSION; fetch it first"
[[ "$tag_commit" == "$MESA_COMMIT" ]] ||
  die "mesa-$MESA_VERSION is $tag_commit, not MESA_COMMIT $MESA_COMMIT in $release"
pin="$MESA_COMMIT"

python3 -I - "$manifest" "$pin" <<'PY' || die "no external/mesa3d project in $manifest"
import re
import sys

path, pin = sys.argv[1:]
text = open(path).read()
project = re.compile(r'(<project\b[^>]*\bpath="external/mesa3d"[^>]*\brevision=")[^"]*(")')
text, count = project.subn(lambda m: m.group(1) + pin + m.group(2), text)
if count != 1:
    sys.exit(1)
open(path, "w").write(text)
PY
meson_commit="$(git -C "$meson_dir" rev-parse HEAD)"

work="$(mktemp -d)"
cleanup() {
  git -C "$mesa_repo" worktree remove --force "$work/mesa" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

git -C "$mesa_repo" worktree add --quiet --detach "$work/mesa" "$pin"
version="$(tr -d '[:space:]' < "$work/mesa/VERSION")"
[[ "$version" == "$MESA_VERSION" ]] ||
  die "mesa-$MESA_VERSION's VERSION file says $version"
hermetic="$work/mesa/src/gfxstream/hermetic/android"

# Honeykrisp's Android support adds hk_android.c, which the generated build
# files name. The patch written below is the difference from this tree, so it
# does not repeat the series patch.
git -C "$work/mesa" apply "$honeykrisp_patch" ||
  die "$(basename "$honeykrisp_patch") no longer applies to Mesa $version"
git -C "$work/mesa" add --all
base_tree="$(git -C "$work/mesa" write-tree)"

# The Apple driver's shader kernels: libpoly and libagx are OpenCL compiled by
# mesa_clc and bound by vtn_bindgen2, libagx_shaders is made by asahi_clc, and
# the disassembler's table by a script that reads AGX2.xml from beside itself,
# which Soong's packed Python cannot. Build them natively and use the results
# as sources.
log "building the Apple driver's shader kernels for Mesa $version"
kernels=(
  src/poly/cl/libpoly.cpp src/poly/cl/libpoly.h
  src/asahi/libagx/libagx.cpp src/asahi/libagx/libagx.h
  src/asahi/lib/libagx_shaders.c src/asahi/lib/libagx_shaders.h
  src/asahi/isa/agx2_disasm.c
)
{
  meson setup "$work/native" "$work/mesa" -Dbuildtype=release \
    -Dvulkan-drivers=asahi -Dgallium-drivers= -Dplatforms= -Dglx=disabled \
    -Degl=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
    -Dllvm=enabled -Dshared-llvm=enabled -Dvideo-codecs= -Dtools= &&
    ninja -C "$work/native" "${kernels[@]}"
} > "$work/native.log" 2>&1 || {
  tail -n 40 "$work/native.log" >&2
  die "could not build the Apple driver's shader kernels"
}
[[ -z "$(git -C "$work/mesa" status --porcelain=v1 --untracked-files=all | grep -v '^[AM]  ')" ]] ||
  die "the native Mesa build changed the source tree"
for kernel in "${kernels[@]}"; do
  cp "$work/native/$kernel" "$work/mesa/$kernel"
done

python3 -I - "$work/mesa" <<'PY' || die "could not point the Apple driver's build at the built kernels"
import pathlib
import sys

mesa = pathlib.Path(sys.argv[1])

def edit(path, edits):
    text = (mesa / path).read_text()
    for old, new in edits:
        if text.count(old) != 1:
            sys.exit(f"{path}: expected one {old!r}")
        text = text.replace(old, new)
    (mesa / path).write_text(text)

def cut(path, start, end, new):
    text = (mesa / path).read_text()
    if text.count(start) != 1:
        sys.exit(f"{path}: expected one {start!r}")
    a = text.index(start)
    b = text.find(end, a)
    if b < 0:
        sys.exit(f"{path}: no {end!r} after {start!r}")
    (mesa / path).write_text(text[:a] + new + text[b + len(end):])

# The rules that run the tools become the files they made.
cut("src/poly/cl/meson.build", "libpoly_shaders_spv = custom_target(",
    "  command : [prog_vtn_bindgen2, libpoly_shaders_spv, '@OUTPUT0@', '@OUTPUT1@'],\n)\n",
    "libpoly_shaders = files('libpoly.cpp', 'libpoly.h')\n")
cut("src/asahi/libagx/meson.build", "libagx_spv = custom_target(",
    "  command : [prog_vtn_bindgen2, libagx_spv, '@OUTPUT0@', '@OUTPUT1@'],\n)\n",
    "libagx = files('libagx.cpp', 'libagx.h')\n")
cut("src/asahi/lib/meson.build", "libagx_shaders = custom_target(",
    "  command : [prog_asahi_clc, libagx_spv, '@OUTPUT0@', '@OUTPUT1@'],\n)\n",
    "libagx_shaders = files('libagx_shaders.h', 'libagx_shaders.c')\n")
cut("src/asahi/isa/meson.build", "agx2_disasm_c = custom_target(",
    "  depend_files : files('isa.py'),\n)\n",
    "agx2_disasm_c = files('agx2_disasm.c')\n")

# Soong takes a Python source's path as a module path, where a dot is not
# allowed before the extension.
compiler = mesa / "src/asahi/compiler"
renames = [("agx_opcodes.h.py", "agx_opcodes_h.py"),
           ("agx_opcodes.c.py", "agx_opcodes_c.py"),
           ("agx_builder.h.py", "agx_builder_h.py")]
for old, new in renames:
    (compiler / old).rename(compiler / new)
edit("src/asahi/compiler/meson.build",
     [(f"'{old}'", f"'{new}'") for old, new in renames])

# Android's build makes arithmetic on void pointers an error; the driver uses
# it.
for path in ("src/asahi/compiler/meson.build", "src/asahi/lib/meson.build",
             "src/asahi/vulkan/meson.build"):
    text = (mesa / path).read_text()
    if "'-Wno-c2x-extensions'" not in text:
        sys.exit(f"{path}: no '-Wno-c2x-extensions' to extend")
    (mesa / path).write_text(text.replace(
        "'-Wno-c2x-extensions'",
        "'-Wno-c2x-extensions', '-Wno-gnu-pointer-arith'"))

# The Vulkan driver includes the compiler's generated headers without naming
# them as a dependency; Soong needs them named.
edit("src/asahi/vulkan/meson.build",
     [("  idep_libagx_shaders_h,\n]",
       "  idep_libagx_shaders_h,\n  idep_agx_opcodes_h,\n  idep_agx_builder_h,\n]")])
PY

# The config names its handwritten-module file relative to its own directory.
mkdir "$work/config"
cp "$config" "$hermetic/gfxstream_workaround.txt" "$hermetic/dependencies.toml" "$work/config/"
patch --quiet --forward -p1 -d "$work/config" < "$script_dir/gfxstream_workaround.patch" ||
  die "gfxstream_workaround.patch no longer applies to this Mesa's gfxstream_workaround.txt"
patch --quiet --forward -p1 -d "$work/config" < "$script_dir/dependencies.patch" ||
  die "dependencies.patch no longer applies to this Mesa's dependencies.toml"
# With mesa-clc and precomp-compiler set to "system" in the config, Mesa looks
# its kernel tools up as programs; the build files this makes never run them.
[[ "$(grep '^\[' "$work/config/dependencies.toml" | tail -n 1)" == "[programs]" ]] ||
  die "dependencies.toml no longer ends with its [programs] table"
printf '%s = { version = "%s" }\n' mesa_clc "$MESA_VERSION" vtn_bindgen2 "$MESA_VERSION" \
  asahi_clc "$MESA_VERSION" >> "$work/config/dependencies.toml"

git -C "$work/mesa" rm --quiet android/Android.mk
log "converting Mesa $version (${pin:0:12}) with meson2hermetic ${meson_commit:0:12}"
python3 -I "$meson_dir/meson.py" convert \
  --config "$work/config/aosp_mesa3d.toml" \
  --platforms "$hermetic/platforms.toml" \
  --dependencies "$work/config/dependencies.toml" \
  --project-dir "$work/mesa" > "$work/convert.log" 2>&1 || {
  tail -n 40 "$work/convert.log" >&2
  die "meson convert failed"
}

# meson2hermetic writes every conditional property as select(), but Android
# 16's Soong cannot select cc ldflags or rust flags (plain []string in
# cc/linker.go and rust/compiler.go; the others it selects are configurable).
# Rewrite those selects into the equivalent target blocks, keyed by os or
# os_arch, and stop on any shape that has no exact equivalent.
python3 -I - "$work/mesa" <<'PY' || die "could not rewrite select() for Android 16's Soong"
import pathlib
import re
import sys

NON_CONFIGURABLE = ("ldflags", "flags")
select_re = re.compile(
    r'(?m)^    (?P<prop>%s): select\((?P<on>os\(\)|\(arch\(\), os\(\)\)), \{\n'
    r'(?P<body>(?:        .*\n|            .*\n)*?)'
    r'    \}\),\n' % "|".join(NON_CONFIGURABLE))
case_re = re.compile(
    r'(?m)^        (?P<key>"[^"]+"|\("[^"]+", "[^"]+"\)|default|\(default, default\)): '
    r'(?:\[\],\n|\[\n(?P<values>(?:            "[^"\n]*",\n)+)        \],\n)')
module_re = re.compile(r'(?ms)^[a-z_]+ \{\n.*?^\}\n')
target_key_re = re.compile(r'^(android|linux_glibc|linux_musl)(_(x86_64|x86|arm64|arm))?$')

def fail(message):
    sys.exit(message)

def target_key(key):
    names = re.findall(r'"([^"]+)"', key)
    name = names[0] if len(names) == 1 else f"{names[1]}_{names[0]}"
    if not target_key_re.match(name):
        fail(f"no target block for select key {key}")
    return name

def rewrite_one(text, match):
    prop, body = match.group("prop"), match.group("body")
    entries = []
    consumed = 0
    for case in case_re.finditer(body):
        if case.start() != consumed:
            fail(f"unparsed {prop} select() case: {body[consumed:case.start()]!r}")
        consumed = case.end()
        if "default" in case.group("key"):
            if case.group("values"):
                fail(f"{prop} select() with a non-empty default")
            continue
        if case.group("values"):
            entries.append((target_key(case.group("key")), case.group("values")))
    if consumed != len(body):
        fail(f"unparsed {prop} select() tail: {body[consumed:]!r}")
    block = "".join(
        f"        {key}: {{\n            {prop}: [\n"
        + values.replace("            ", "                ")
        + "            ],\n        },\n"
        for key, values in entries)
    text = text[:match.start()] + text[match.end():]
    existing = re.search(r'(?m)^    target: \{\n', text)
    if existing:
        for key, _ in entries:
            if re.search(r'(?m)^        %s: \{' % key, text):
                fail(f"target block already has {key}")
        return text[:existing.end()] + block + text[existing.end():]
    if not block:
        return text
    closing = text.rindex("}\n")
    return text[:closing] + "    target: {\n" + block + "    },\n" + text[closing:]

def rewrite(module):
    text = module.group(0)
    while match := select_re.search(text):
        text = rewrite_one(text, match)
    # Any select() left on these properties (e.g. "[...] + select(...)") has
    # no rewrite here.
    prop = None
    for line in text.split("\n"):
        start = re.match(r'^    ([a-z_]+): ', line)
        if start:
            prop = start.group(1)
        elif re.match(r'^    \S', line) and not line.startswith("    ]") and not line.startswith("    }"):
            prop = None
        if prop in NON_CONFIGURABLE and "select(" in line:
            fail(f"{prop} select() left in module: {text.splitlines()[1].strip()}")
    return text

for bp in pathlib.Path(sys.argv[1]).rglob("Android.bp"):
    text = bp.read_text()
    new = module_re.sub(rewrite, text)
    if new != text:
        bp.write_text(new)
PY
git -C "$work/mesa" add --all

{
  cat <<EOF
Patch summary:
Android build integration for Mesa $version (${pin:0:12}), generated by
src/lineageos/scripts/mesa3d/regenerate.sh; regenerate it rather than editing it.
The Android.bp files come from Mesa's meson.build files through meson2hermetic
${meson_commit:0:12} with src/lineageos/scripts/mesa3d/aosp_mesa3d.toml, which is
Mesa's AOSP config without the Freedreno/Turnip build and, on the device,
without virtgpu_kumquat (with gfxstream_workaround.patch keeping its Rust
libraries out of the device build) and with Venus (vulkan.virtio, its protocol
headers from external/venus-protocol through dependencies.patch) and with
the Apple driver, Honeykrisp (vulkan.asahi), whose shader kernels
(libpoly, libagx, libagx_shaders, agx2_disasm.c) regenerate.sh built with a
native Mesa build, as the Android build cannot run Mesa's OpenCL tools; its
ldflags and Rust flags select()s become target blocks, as Android 16's Soong
cannot select them. Mesa's android/Android.mk is removed because Soong rejects
Android.mk files under external/. The patch is the difference from the release
with external-mesa3d-honeykrisp-android.patch applied, which adds a source
file the build files name.

EOF
  git -C "$work/mesa" diff --cached --full-index "$base_tree"
} > "$output"

log "wrote $output ($(git -C "$work/mesa" diff --cached --name-only "$base_tree" | wc -l | tr -d ' ') files)"
