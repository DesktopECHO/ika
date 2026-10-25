#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
overlay_dir="$(cd "$script_dir/../.." && pwd)"
manifest="$overlay_dir/manifests/lineageos-desktop.xml"
output="$overlay_dir/patches/external-mesa3d.patch"
config="$script_dir/aosp_mesa3d.toml"

usage() {
  cat <<'EOF'
Usage: regenerate.sh MESA_REPO MESON2HERMETIC_CHECKOUT

Regenerate patches/external-mesa3d.patch, the Android build integration for
the Mesa commit pinned in manifests/lineageos-desktop.xml. The patch removes
Mesa's android/Android.mk, which Soong's Android.mk denylist rejects under
external/, and adds the Android.bp files meson2hermetic generates from Mesa's
meson.build files with aosp_mesa3d.toml (next to this script).

MESA_REPO is any Mesa git repository that has the pinned commit; the script
works in a temporary worktree of it. MESON2HERMETIC_CHECKOUT is a checkout of
https://github.com/mesonbuild/meson/pull/15462 (Python 3.11 or newer).

Ika's own Mesa fixes are separate patches in patches/series and are not
touched; they do not change the generated build files.
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

pin="$(python3 -I - "$manifest" <<'PY'
import sys
import xml.etree.ElementTree as ET

for project in ET.parse(sys.argv[1]).getroot().iter("project"):
    if project.get("path") == "external/mesa3d":
        print(project.get("revision", ""))
        break
PY
)"
[[ "$pin" =~ ^[0-9a-f]{40}$ ]] || die "no external/mesa3d revision in $manifest"
git -C "$mesa_repo" cat-file -e "$pin^{commit}" 2>/dev/null ||
  die "$mesa_repo does not have the pinned Mesa commit $pin; fetch it first"
meson_commit="$(git -C "$meson_dir" rev-parse HEAD)"

work="$(mktemp -d)"
cleanup() {
  git -C "$mesa_repo" worktree remove --force "$work/mesa" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

git -C "$mesa_repo" worktree add --quiet --detach "$work/mesa" "$pin"
version="$(tr -d '[:space:]' < "$work/mesa/VERSION")"
hermetic="$work/mesa/src/gfxstream/hermetic/android"

# The config names its handwritten-module file relative to its own directory.
mkdir "$work/config"
cp "$config" "$hermetic/gfxstream_workaround.txt" "$hermetic/dependencies.toml" "$work/config/"
patch --quiet --forward -p1 -d "$work/config" < "$script_dir/gfxstream_workaround.patch" ||
  die "gfxstream_workaround.patch no longer applies to this Mesa's gfxstream_workaround.txt"
patch --quiet --forward -p1 -d "$work/config" < "$script_dir/dependencies.patch" ||
  die "dependencies.patch no longer applies to this Mesa's dependencies.toml"

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
lineageos/scripts/mesa3d/regenerate.sh; regenerate it rather than editing it.
The Android.bp files come from Mesa's meson.build files through meson2hermetic
${meson_commit:0:12} with lineageos/scripts/mesa3d/aosp_mesa3d.toml, which is
Mesa's AOSP config without the Freedreno/Turnip build and, on the device,
without virtgpu_kumquat (with gfxstream_workaround.patch keeping its Rust
libraries out of the device build) and with Venus (vulkan.virtio, its protocol
headers from external/venus-protocol through dependencies.patch); its
ldflags and Rust flags select()s become target blocks, as Android 16's Soong
cannot select them. Mesa's android/Android.mk is removed because Soong rejects
Android.mk files under external/.

EOF
  git -C "$work/mesa" diff --cached --full-index
} > "$output"

log "wrote $output ($(git -C "$work/mesa" diff --cached --name-only | wc -l | tr -d ' ') files)"
