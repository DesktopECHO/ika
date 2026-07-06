#!/usr/bin/env bash
set -euo pipefail

# This validator lives in scripts/lib/ but is invoked as a standalone executable
# (not sourced). script_dir is .../scripts/lib; the overlay root is two levels up.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
overlay_dir="$(cd "$script_dir/../.." && pwd)"

source "$script_dir/common.sh"
source "$script_dir/patch_series.sh"

usage() {
  cat <<'EOF'
Usage: validate_build_inputs.sh ANDROID_ROOT [arm64|x86_64]...

Validate the LineageOS Desktop source tree before compiling release images.
This is a build-time guard only; it does not inspect a booted device.
EOF
}

log() {
  printf '[lineage-desktop] validate: %s\n' "$*"
}

failures=0
fail() {
  printf '[lineage-desktop] validate: error: %s\n' "$*" >&2
  failures=$((failures + 1))
}

require_file() {
  [[ -f "$1" ]] || fail "missing file: $1"
}

require_arm64_elf() {
  local path="$1"
  local label="$2"

  require_file "$path"
  [[ -x "$path" ]] || fail "$label is not executable: $path"
  if command -v readelf >/dev/null 2>&1; then
    readelf -h "$path" 2>/dev/null | grep -Eq 'Machine:[[:space:]]+AArch64' || \
      fail "$label is not an ARM64 ELF executable: $path"
  elif command -v file >/dev/null 2>&1; then
    file -Lb "$path" 2>/dev/null | grep -Eiq 'aarch64|arm64|AArch64' || \
      fail "$label is not an ARM64 executable: $path"
  else
    fail "cannot verify ARM64 executable architecture for $label; install readelf or file"
  fi
}

zipalign_tool() {
  local out_zipalign="$android_root/out/host/$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m | sed 's/aarch64/arm64/;s/x86_64/x86/')/bin/zipalign"
  local source_tree_zipalign="$android_root/prebuilts/sdk/tools/linux/bin/zipalign"

  if [[ -x "$out_zipalign" ]]; then
    printf '%s\n' "$out_zipalign"
    return 0
  fi
  if [[ -x "$source_tree_zipalign" ]]; then
    printf '%s\n' "$source_tree_zipalign"
    return 0
  fi
  command -v zipalign 2>/dev/null
}

readelf_tool() {
  command -v llvm-readelf 2>/dev/null || command -v readelf 2>/dev/null
}

report_apk_16k_audit_issue() {
  local policy="$1"
  local label="$2"
  local apk="$3"
  local detail="$4"

  case "$policy" in
    allow_compat)
      log "warning: $label will rely on 16 KB app compat if booted on a 16 KB kernel: $detail ($apk)"
      ;;
    fail)
      fail "$label is not 16 KB clean: $detail ($apk)"
      ;;
    *)
      fail "internal error: unknown APK 16 KB audit policy '$policy' for $apk"
      ;;
  esac
}

audit_apk_16k_alignment() {
  target_enabled arm64 || return 0

  local apk="$1"
  local label="$2"
  local policy="$3"
  local zipalign readelf tmp_dir output rel so alignments
  local -a compat_libs=()

  [[ -f "$apk" ]] || return 0

  zipalign="$(zipalign_tool || true)"
  if [[ -z "$zipalign" ]]; then
    fail "zipalign is required for ARM64 APK 16 KB alignment audit"
    return 0
  fi

  if ! output="$("$zipalign" -c -P 16 -v 4 "$apk" 2>&1)"; then
    report_apk_16k_audit_issue "$policy" "$label" "$apk" \
      "zipalign -c -P 16 -v 4 failed: $(printf '%s\n' "$output" | tail -n 1)"
  fi

  readelf="$(readelf_tool || true)"
  if [[ -z "$readelf" ]]; then
    fail "llvm-readelf or readelf is required for ARM64 APK native-library page-size audit"
    return 0
  fi

  tmp_dir="$(mktemp -d)"
  if ! python3 - "$apk" "$tmp_dir" <<'PY'
from pathlib import Path
import re
import sys
import zipfile

apk = Path(sys.argv[1])
out = Path(sys.argv[2])
lib_re = re.compile(r"^lib/arm64-v8a/[^/]+\.so$")

with zipfile.ZipFile(apk) as archive:
    for info in archive.infolist():
        if not lib_re.match(info.filename):
            continue
        dest = out / info.filename
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(archive.read(info))
PY
  then
    fail "failed to extract native libraries for APK 16 KB audit: $apk"
    rm -rf "$tmp_dir"
    return 0
  fi

  while IFS= read -r -d '' so; do
    rel="${so#$tmp_dir/}"
    if ! alignments="$("$readelf" -lW "$so" 2>/dev/null | awk '$1 == "LOAD" { print $NF }' | sort -u | xargs)"; then
      fail "failed to inspect ELF program headers in $apk:$rel"
      continue
    fi
    if grep -Eq '(^|[[:space:]])(0x0*1000|4096)($|[[:space:]])' <<<"$alignments"; then
      compat_libs+=("$rel align=$alignments")
    fi
  done < <(find "$tmp_dir" -type f -name '*.so' -print0)

  rm -rf "$tmp_dir"

  if (( ${#compat_libs[@]} > 0 )); then
    report_apk_16k_audit_issue "$policy" "$label" "$apk" \
      "4 KB LOAD alignment: ${compat_libs[*]}"
  fi
}

normalize_targets() {
  if (( $# == 0 )); then
    printf '%s\n' arm64 x86_64
    return
  fi

  local target
  for target in "$@"; do
    case "$target" in
      all)
        printf '%s\n' arm64 x86_64
        ;;
      arm64|aarch64)
        printf '%s\n' arm64
        ;;
      x86_64|x86-64|amd64)
        printf '%s\n' x86_64
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        fail "unknown target '$target'; expected arm64 or x86_64"
        ;;
    esac
  done | awk '!seen[$0]++'
}

target_enabled() {
  local wanted="$1"
  local target
  for target in "${targets[@]}"; do
    [[ "$target" == "$wanted" ]] && return 0
  done
  return 1
}

check_single_patch_applied() {
  local project="$1"
  local patch="$2"
  local patch_path project_label

  patch_path="$overlay_dir/$patch"
  project_label="$(patch_series_project_label "$project")"

  if ! patch_series_git_apply "$android_root" "$project" --check --reverse --whitespace=nowarn "$patch_path" >/dev/null 2>&1; then
    fail "patch is not applied cleanly to $project_label: $patch"
  fi
}

check_patch_series() {
  local series="$overlay_dir/patches/series"
  require_file "$series"
  [[ -d "$android_root/.repo" ]] || fail "ANDROID_ROOT does not look like a repo checkout: $android_root"

  local line project patch extra project_dir patch_path
  local -a projects=()
  declare -A seen_projects=()
  declare -A project_patch_count=()
  declare -A project_patch_list=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "${line//[[:space:]]/}" ]] || continue
    [[ "${line:0:1}" == "#" ]] && continue

    read -r project patch extra <<<"$line"
    if [[ -z "${project:-}" || -z "${patch:-}" || -n "${extra:-}" ]]; then
      fail "invalid patch series line: $line"
      continue
    fi

    project_dir="$(patch_series_project_dir "$android_root" "$project")"
    patch_path="$overlay_dir/$patch"

    require_file "$patch_path"
    if patch_series_is_source_root "$project"; then
      if [[ ! -d "$project_dir" ]]; then
        fail "patched source root is missing: $project_dir"
        continue
      fi
    elif [[ ! -d "$project_dir/.git" ]]; then
      fail "patched project is missing or not a git checkout: $project"
      continue
    fi

    if [[ -z "${seen_projects[$project]:-}" ]]; then
      projects+=("$project")
      seen_projects[$project]=1
    fi

    project_patch_count[$project]=$(( ${project_patch_count[$project]:-0} + 1 ))
    project_patch_list[$project]+="$patch"$'\n'
  done < "$series"

  for project in "${projects[@]}"; do
    project_dir="$(patch_series_project_dir "$android_root" "$project")"

    if patch_series_is_source_root "$project"; then
      while IFS= read -r patch; do
        [[ -n "$patch" ]] || continue
        check_single_patch_applied "$project" "$patch"
      done <<<"${project_patch_list[$project]}"
      continue
    fi

    if (( ${project_patch_count[$project]} == 1 )); then
      patch="${project_patch_list[$project]%$'\n'}"
      check_single_patch_applied "$project" "$patch"
      continue
    fi

    check_project_patch_series "$project" "${project_patch_list[$project]}"
  done
}

check_project_patch_series() {
  local project="$1"
  local patch_list="$2"

  # patch_series_already_applied (lib/patch_series.sh) reverse-checks every
  # patch in this project's stack against the live tree. The apply step is
  # responsible for resetting managed projects before reapplying the series, so
  # validation can stay read-only and partial-clone friendly.
  patch_series_already_applied "$android_root" "$overlay_dir" "$project" "$patch_list" || \
    fail "patch series is not applied cleanly to $project"
}

check_patched_xml_resource_references() {
  local series="$overlay_dir/patches/series"
  require_file "$series"
  [[ -f "$series" ]] || return 0

  log "checking patched XML resource references"
  local checker_output
  if ! checker_output="$(python3 - "$android_root" "$overlay_dir" "$series" 2>&1 <<'PY'
from pathlib import Path
import re
import sys

android_root = Path(sys.argv[1])
overlay_dir = Path(sys.argv[2])
series = Path(sys.argv[3])

diff_re = re.compile(r"^diff --git a/(.+?) b/(.+)$")
xml_ref_re = re.compile(r"@xml/([A-Za-z0-9_.]+)")


def is_source_root_project(project: str) -> bool:
    return project == "."


def project_dir(project: str) -> Path:
    return android_root if is_source_root_project(project) else android_root / project


def changed_xml_files(project: str, patch_rel: str) -> set[Path]:
    patch_path = overlay_dir / patch_rel
    root = project_dir(project)
    changed: set[Path] = set()
    try:
        lines = patch_path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError as exc:
        raise SystemExit(f"failed to read patch {patch_rel}: {exc}")

    for line in lines:
        match = diff_re.match(line)
        if not match:
            continue
        rel = match.group(2)
        if rel == "/dev/null":
            continue
        if not rel.endswith(".xml"):
            continue
        parts = Path(rel).parts
        if "res" not in parts:
            continue
        path = root / rel
        if path.is_file():
            changed.add(path)
    return changed


def xml_resource_names(root: Path) -> set[str]:
    res_dir = root / "res"
    names: set[str] = set()
    if not res_dir.is_dir():
        return names
    for xml_dir in res_dir.glob("xml*"):
        if not xml_dir.is_dir():
            continue
        for path in xml_dir.glob("*.xml"):
            names.add(path.stem)
    return names


def iter_series_entries():
    for raw in series.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 2:
            continue
        yield parts[0], parts[1]


bad: list[str] = []
patched_files: dict[Path, set[Path]] = {}

for project, patch_rel in iter_series_entries():
    root = project_dir(project)
    files = changed_xml_files(project, patch_rel)
    if files:
        patched_files.setdefault(root, set()).update(files)

for root, files in patched_files.items():
    known_xml = xml_resource_names(root)
    if not known_xml:
        continue
    for path in sorted(files):
        try:
            lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
        except OSError:
            continue
        try:
            display_path = path.relative_to(android_root).as_posix()
        except ValueError:
            display_path = path.as_posix()
        for lineno, line in enumerate(lines, 1):
            for ref in xml_ref_re.findall(line):
                if ref not in known_xml:
                    bad.append(
                        f"{display_path}:{lineno}: missing local @xml/{ref} "
                        f"(expected res/xml*/{ref}.xml)"
                    )

if bad:
    print("patched XML files reference missing local XML resources:", file=sys.stderr)
    for item in bad[:80]:
        print(item, file=sys.stderr)
    if len(bad) > 80:
        print(f"... {len(bad) - 80} more", file=sys.stderr)
    raise SystemExit(1)
PY
)"; then
    fail "$checker_output"
  else
    log "patched XML resource references ok"
  fi
}

check_userdata_policy() {
  local shared_device="$android_root/device/google/cuttlefish/shared/device.mk"
  local arm_board="$android_root/device/google/cuttlefish/ika_arm64/BoardConfig.mk"
  local x86_board="$android_root/device/google/cuttlefish/ika_x86_64/BoardConfig.mk"

  require_file "$shared_device"
  require_file "$arm_board"
  require_file "$x86_board"

  grep -Eq '^[[:space:]]*TARGET_USERDATAIMAGE_PARTITION_SIZE[[:space:]]*\?=[[:space:]]*65498251264[[:space:]]*$' "$shared_device" || \
    fail "userdata size is not the expected 61 GiB default in $shared_device"
  grep -Eq '^[[:space:]]*TARGET_USERDATAIMAGE_FILE_SYSTEM_TYPE[[:space:]]*:=[[:space:]]*ext4[[:space:]]*$' "$arm_board" || \
    fail "ARM64 userdata is not ext4 in $arm_board"
  grep -Eq '^[[:space:]]*TARGET_USERDATAIMAGE_FILE_SYSTEM_TYPE[[:space:]]*:=[[:space:]]*ext4[[:space:]]*$' "$x86_board" || \
    fail "x86-64 userdata is not ext4 in $x86_board"

  if grep -R --include='*.mk' --include='BoardConfig*.mk' \
      --exclude-dir='.git' --exclude-dir='out' --exclude-dir='src' \
      -E '^[[:space:]]*TARGET_USERDATAIMAGE_PARTITION_SIZE[[:space:]]*:=' \
      "$overlay_dir" >/dev/null 2>&1; then
    fail "overlay contains a hard userdata partition size override"
  fi
}

check_x86_64_64_bit_only_product() {
  target_enabled x86_64 || return 0

  local x86_board="$android_root/device/google/cuttlefish/ika_x86_64/BoardConfig.mk"
  local x86_product="$android_root/device/google/cuttlefish/ika_x86_64/desktop/aosp_cf.mk"

  require_file "$x86_board"
  require_file "$x86_product"

  grep -Eq '^[[:space:]]*TARGET_ARCH[[:space:]]*:=[[:space:]]*x86_64[[:space:]]*$' "$x86_board" || \
    fail "x86-64 BoardConfig must use TARGET_ARCH := x86_64: $x86_board"
  grep -Eq '^[[:space:]]*TARGET_CPU_ABI[[:space:]]*:=[[:space:]]*x86_64[[:space:]]*$' "$x86_board" || \
    fail "x86-64 BoardConfig must use TARGET_CPU_ABI := x86_64: $x86_board"
  if grep -Eq '^[[:space:]]*TARGET_2ND_|^[[:space:]]*TARGET_NATIVE_BRIDGE_2ND_' "$x86_board"; then
    fail "x86-64 product must stay 64-bit-only; remove TARGET_2ND_* and TARGET_NATIVE_BRIDGE_2ND_* from $x86_board"
  fi
  grep -Fq 'core_64_bit_only.mk' "$x86_product" || \
    fail "x86-64 product must inherit core_64_bit_only.mk: $x86_product"
}

check_arm64_min_arch_variant() {
  target_enabled arm64 || return 0

  local arm_board="$android_root/device/google/cuttlefish/ika_arm64/BoardConfig.mk"

  require_file "$arm_board"

  grep -Eq '^[[:space:]]*TARGET_ARCH[[:space:]]*:=[[:space:]]*arm64[[:space:]]*$' "$arm_board" || \
    fail "ARM64 BoardConfig must use TARGET_ARCH := arm64: $arm_board"
  grep -Eq '^[[:space:]]*TARGET_CPU_ABI[[:space:]]*:=[[:space:]]*arm64-v8a[[:space:]]*$' "$arm_board" || \
    fail "ARM64 BoardConfig must use TARGET_CPU_ABI := arm64-v8a: $arm_board"
  grep -Eq '^[[:space:]]*TARGET_ARCH_VARIANT[[:space:]]*:=[[:space:]]*armv8-2a[[:space:]]*$' "$arm_board" || \
    fail "ARM64 ROM must target minimum ARMv8.2-A devices with TARGET_ARCH_VARIANT := armv8-2a: $arm_board"
}

check_unscoped_x86_flags() {
  case "${VALIDATE_X86_FLAGS:-1}" in
    0|false|no|off)
      log "x86 flag validation skipped by VALIDATE_X86_FLAGS=0"
      return 0
      ;;
  esac

  local project_list="$android_root/.repo/project.list"
  require_file "$project_list"
  [[ -f "$project_list" ]] || return 0

  log "checking for unscoped x86-only compiler flags"
  local checker_output
  if ! checker_output="$(python3 - "$android_root" "$project_list" 2>&1 <<'PY'
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
import os
import re
import subprocess
import sys

android_root = Path(sys.argv[1])
project_list = Path(sys.argv[2])

x86_flag_re = re.compile(
    r'(?<![A-Za-z0-9_])'
    r'-m(?:'
    r'sse[0-9.]*|ssse3|mmx|avx[A-Za-z0-9.]*|aes|pclmul|popcnt|'
    r'xsave(?:opt|c)?|f16c|fma|rtm|bmi2?|lzcnt|movbe|cx16|sha'
    r')'
    r'(?![A-Za-z0-9_.-])'
)
git_grep_x86_flag_re = (
    r'-m(sse[0-9.]*|ssse3|mmx|avx[A-Za-z0-9.]*|aes|pclmul|popcnt|'
    r'xsave(opt|c)?|f16c|fma|rtm|bmi2?|lzcnt|movbe|cx16|sha)'
)
bp_label_re = re.compile(r'([A-Za-z0-9_]+)\s*:\s*\{')
make_assign_re = re.compile(r'\s*([A-Za-z0-9_.$(){}+-]+)\s*(?::=|\+=|=)\s*(.*)')
make_if_re = re.compile(r'\s*(ifn?eq|ifdef|ifndef)\b(.*)')
make_else_re = re.compile(r'\s*else\b')
make_endif_re = re.compile(r'\s*endif\b')


def strip_bp_comment(line: str) -> str:
    # Android.bp files do not need x86-flag strings inside comments checked.
    return line.split("//", 1)[0]


def strip_make_comment(line: str) -> str:
    escaped = False
    for index, char in enumerate(line):
        if char == "\\" and not escaped:
            escaped = True
            continue
        if char == "#" and not escaped:
            return line[:index]
        escaped = False
    return line


def x86_context(text: str) -> bool:
    lowered = text.lower()
    return any(token in lowered for token in ("x86", "i386", "i486", "i586", "i686"))


def is_build_file(path: Path) -> bool:
    name = path.name
    return name.endswith(".bp") or name.endswith(".mk") or name.startswith("BoardConfig")


def grep_project(project: str) -> list[Path]:
    project_dir = android_root / project
    if not (project_dir / ".git").exists():
        return []
    try:
        result = subprocess.run(
            [
                "git",
                "-C",
                str(project_dir),
                "grep",
                "-l",
                "-I",
                "-E",
                git_grep_x86_flag_re,
                "--",
                "*.bp",
                "*.mk",
                "BoardConfig*",
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return []
    if result.returncode not in (0, 1):
        return []

    paths = []
    for raw in result.stdout.splitlines():
        rel = raw.decode("utf-8", "surrogateescape")
        path = project_dir / rel
        if path.is_file() and is_build_file(path):
            paths.append(path)
    return paths


def x86_flag_jobs() -> int:
    raw = os.environ.get("VALIDATE_X86_FLAGS_JOBS")
    if raw:
        try:
            return max(1, int(raw))
        except ValueError:
            return 1
    return max(1, min(8, os.cpu_count() or 4))


def iter_candidate_files():
    projects = [
        line.strip()
        for line in project_list.read_text(encoding="utf-8", errors="ignore").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    seen: set[Path] = set()
    with ThreadPoolExecutor(max_workers=x86_flag_jobs()) as executor:
        futures = [executor.submit(grep_project, project) for project in projects]
        for future in as_completed(futures):
            for path in future.result():
                if path in seen:
                    continue
                seen.add(path)
                yield path


def check_bp(path: Path, rel_path: str, bad: list[str]) -> None:
    stack: list[str | None] = []
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return

    path_is_x86_scoped = x86_context(rel_path)
    for lineno, line in enumerate(lines, 1):
        code = strip_bp_comment(line)
        labels = list(bp_label_re.finditer(code))
        for match in labels:
            stack.append(match.group(1))
        stack.extend([None] * max(0, code.count("{") - len(labels)))

        if x86_flag_re.search(code):
            scoped = path_is_x86_scoped or any(label and x86_context(label) for label in stack)
            if not scoped:
                bad.append(f"{rel_path}:{lineno}: x86-only compiler flag is not under an x86/x86_64 scope: {line.strip()}")

        for _ in range(code.count("}")):
            if stack:
                stack.pop()


def check_make(path: Path, rel_path: str, bad: list[str]) -> None:
    try:
        lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except OSError:
        return

    path_is_x86_scoped = x86_context(rel_path)
    condition_stack: list[str] = []
    current_var = ""

    for lineno, line in enumerate(lines, 1):
        code = strip_make_comment(line).rstrip()
        if make_endif_re.match(code):
            if condition_stack:
                condition_stack.pop()
        elif make_else_re.match(code):
            pass
        else:
            if_match = make_if_re.match(code)
            if if_match:
                condition_stack.append(code)

        assign = make_assign_re.match(code)
        if assign:
            current_var = assign.group(1)

        if x86_flag_re.search(code):
            context = " ".join([rel_path, current_var, *condition_stack[-4:]])
            if not (path_is_x86_scoped or x86_context(context)):
                bad.append(f"{rel_path}:{lineno}: x86-only compiler flag is not under an x86/x86_64 scope: {line.strip()}")

        if not code.endswith("\\") and not assign:
            current_var = ""


bad: list[str] = []
for path in iter_candidate_files():
    try:
        rel_path = path.relative_to(android_root).as_posix()
    except ValueError:
        rel_path = str(path)
    if path.name.endswith(".bp"):
        check_bp(path, rel_path, bad)
    else:
        check_make(path, rel_path, bad)

if bad:
    print("unscoped x86-only compiler flags found; move these under x86/x86_64 target/arch scopes:", file=sys.stderr)
    for item in bad[:80]:
        print(item, file=sys.stderr)
    if len(bad) > 80:
        print(f"... {len(bad) - 80} more", file=sys.stderr)
    raise SystemExit(1)
PY
)"; then
    fail "$checker_output"
  else
  log "x86 flag validation ok"
  fi
}

check_bison_genrules() {
  case "${VALIDATE_BISON_GENRULES:-1}" in
    0|false|no|off)
      log "Bison genrule validation skipped by VALIDATE_BISON_GENRULES=0"
      return 0
      ;;
  esac

  log "checking Bison genrules for packaged data-dir wiring"

  local bp rel line_no line
  while IFS= read -r -d '' bp; do
    rel="${bp#$android_root/}"
    while IFS=: read -r line_no line; do
      [[ "$line" == *'BISON_PKGDATADIR'* ]] && continue
      fail "Bison genrule does not set BISON_PKGDATADIR: $rel:$line_no"
    done < <(grep -nF '$(location bison)' "$bp" || true)
  done < <(
    find "$android_root" \
      -path "$android_root/.repo" -prune -o \
      -path "$android_root/out" -prune -o \
      -type f -name Android.bp -print0
  )
}

check_trusty_arm64_host_link_config() {
  host_is_arm64 || return 0
  target_enabled arm64 || return 0

  case "${VALIDATE_TRUSTY_ARM64_HOST_LINK:-1}" in
    0|false|no|off)
      log "Trusty ARM64 host link validation skipped by VALIDATE_TRUSTY_ARM64_HOST_LINK=0"
      return 0
      ;;
  esac

  log "checking Trusty ARM64 host link configuration"

  local envsetup lk_engine kernel_compile kernel_host_test kernel_host_tool
  envsetup="$android_root/trusty/vendor/google/aosp/scripts/envsetup.sh"
  lk_engine="$android_root/external/trusty/lk/engine.mk"
  kernel_compile="$android_root/trusty/kernel/make/generic_compile.mk"
  kernel_host_test="$android_root/trusty/kernel/make/host_test.mk"
  kernel_host_tool="$android_root/trusty/kernel/make/host_tool.mk"

  require_file "$envsetup"
  require_file "$lk_engine"
  require_file "$kernel_compile"
  require_file "$kernel_host_test"
  require_file "$kernel_host_tool"

  grep -Fq 'TRUSTY_HOST_PREBUILT_TAG=linux-arm64' "$envsetup" || \
    fail "Trusty envsetup does not select linux-arm64 host prebuilts on ARM64: ${envsetup#$android_root/}"
  grep -Fq 'TRUSTY_RUST_HOST_TRIPLE=aarch64-unknown-linux-musl' "$envsetup" || \
    fail "Trusty envsetup does not select the ARM64 Rust host triple: ${envsetup#$android_root/}"
  grep -Fq 'TRUSTY_CLANG_HOST_TARGET_FLAGS="--target=aarch64-unknown-linux-musl"' "$envsetup" || \
    fail "Trusty envsetup does not set ARM64 Clang host target flags: ${envsetup#$android_root/}"
  grep -Fq 'TRUSTY_CLANG_HOST_LINK_FLAGS="${TRUSTY_CLANG_HOST_TARGET_FLAGS} --rtlib=compiler-rt --unwindlib=libunwind"' "$envsetup" || \
    fail "Trusty envsetup does not set ARM64 Clang runtime link flags: ${envsetup#$android_root/}"
  grep -Fq 'TRUSTY_CLANG_HOST_RUST_LINK_ARGS="-B ${TRUSTY_TOP}/prebuilts/clang/host/linux-arm64/${TRUSTY_BUILD_CLANG_VERSION}/bin -fuse-ld=lld"' "$envsetup" || \
    fail "Trusty envsetup does not set ARM64 Rust host linker args: ${envsetup#$android_root/}"
  grep -Fq 'export GLOBAL_HOST_RUST_LINK_ARGS="${TRUSTY_CLANG_HOST_RUST_LINK_ARGS}"' "$envsetup" || \
    fail "Trusty envsetup does not export Rust host linker args for proc-macro links: ${envsetup#$android_root/}"

  grep -Fq 'GLOBAL_HOST_RUST_LINK_ARGS ?= -B $(CLANG_BINDIR) -B $(CLANG_HOST_SEARCHDIR) \' "$lk_engine" || \
    fail "Trusty lk does not preserve default Rust host linker args with ?=: ${lk_engine#$android_root/}"
  grep -Fq 'TOOLCHAIN_DEFINES += CLANG_HOST_TARGET_FLAGS=' "$lk_engine" || \
    fail "Trusty lk toolchain config does not track CLANG_HOST_TARGET_FLAGS: ${lk_engine#$android_root/}"
  grep -Fq 'TOOLCHAIN_DEFINES += CLANG_HOST_LINK_FLAGS=' "$lk_engine" || \
    fail "Trusty lk toolchain config does not track CLANG_HOST_LINK_FLAGS: ${lk_engine#$android_root/}"
  grep -Fq 'GENERIC_FLAGS += $(CLANG_HOST_TARGET_FLAGS) --sysroot $(CLANG_HOST_SYSROOT)' "$kernel_compile" || \
    fail "Trusty kernel host compiles do not use CLANG_HOST_TARGET_FLAGS: ${kernel_compile#$android_root/}"
  grep -Fq 'HOST_LDFLAGS := $(CLANG_HOST_LINK_FLAGS) -B$(CLANG_BINDIR) -B$(CLANG_HOST_SEARCHDIR) \' "$kernel_host_test" || \
    fail "Trusty kernel host tests do not use CLANG_HOST_LINK_FLAGS: ${kernel_host_test#$android_root/}"
  grep -Fq 'HOST_LDFLAGS += $(CLANG_HOST_LINK_FLAGS) -B$(CLANG_BINDIR) -B$(CLANG_HOST_SEARCHDIR) \' "$kernel_host_tool" || \
    fail "Trusty kernel host tools do not use CLANG_HOST_LINK_FLAGS: ${kernel_host_tool#$android_root/}"
}

check_arm64_clang_compat() {
  host_is_arm64 || return 0
  target_enabled arm64 || return 0

  local arm64_root="$android_root/prebuilts/clang/host/linux-arm64"
  local clang_bp="$arm64_root/Android.bp"
  local trusty_bp="$android_root/trusty/vendor/google/aosp/scripts/Android.bp"
  local module="trusty_dirgroup_prebuilts_clang_host_linux-arm64"
  local clang_dir listed_payload found=0

  [[ -d "$arm64_root" ]] || {
    fail "missing ARM64 Clang prebuilt directory: $arm64_root"
    return 0
  }
  [[ ! -L "$arm64_root" ]] || \
    fail "ARM64 Clang prebuilt directory must be real, not a symlink: prebuilts/clang/host/linux-arm64 -> $(readlink "$arm64_root")"

  for clang_dir in "$arm64_root"/clang-r*; do
    [[ -d "$clang_dir" ]] || continue
    found=1

    require_arm64_elf "$clang_dir/bin/clang" "ARM64 Clang"
    require_arm64_elf "$clang_dir/bin/clang++" "ARM64 Clang++"
    require_file "$clang_dir/include/c++/v1/string"
    require_file "$clang_dir/android_libc++/platform/aarch64/include/c++/v1/__config_site"
  done

  (( found )) || fail "no clang-r* payload found in $arm64_root"

  require_file "$clang_bp"
  grep -Fq "name: \"$module\"" "$clang_bp" || \
    fail "ARM64 Clang prebuilt is missing Trusty dirgroup module: ${clang_bp#$android_root/}"
  listed_payload="$(sed -n 's/.*dirs: \["\(clang-r[^"]*\)"\].*/\1/p' "$clang_bp" | tail -n 1)"
  [[ -n "$listed_payload" && -d "$arm64_root/$listed_payload" ]] || \
    fail "ARM64 Clang Trusty dirgroup points at a missing payload: ${clang_bp#$android_root/}"
  grep -Fqx "        \":$module\"," "$trusty_bp" || \
    fail "Trusty sandbox inputs are missing ARM64 Clang dirgroup: ${trusty_bp#$android_root/}"
}

check_arm64_native_host_prebuilts() {
  host_is_arm64 || return 0
  target_enabled arm64 || return 0

  local rust_version rust_root rustc clang_tools_root tool ninja_path page_size
  rust_version="$(rust_prebuilt_version "$android_root")"
  [[ -n "$rust_version" ]] || {
    fail "failed to detect Rust prebuilt version"
    return 0
  }

  rust_root="$android_root/prebuilts/rust/linux-arm64"
  if [[ -L "$rust_root" ]]; then
    fail "ARM64 Rust prebuilt must be real, not a symlink: prebuilts/rust/linux-arm64 -> $(readlink "$rust_root")"
  fi
  rustc="$rust_root/$rust_version/bin/rustc"
  require_arm64_elf "$rustc" "ARM64 Rust rustc"
  for triple in aarch64-unknown-linux-gnu aarch64-unknown-linux-musl; do
    [[ -d "$rust_root/$rust_version/lib/rustlib/$triple/lib" ]] || \
      fail "ARM64 Rust prebuilt is missing $triple stdlib: $rust_root/$rust_version"
  done

  require_arm64_elf "$android_root/prebuilts/go/linux-arm64/bin/go" "ARM64 Go"
  ninja_path="$android_root/prebuilts/build-tools/linux-arm64/bin/ninja"
  require_arm64_elf "$ninja_path" "ARM64 Ninja"
  page_size="$(getconf PAGESIZE 2>/dev/null || true)"
  if [[ -n "$page_size" && "$page_size" != "4096" ]]; then
    if command -v ninja >/dev/null 2>&1; then
      log "ARM64 host page size is $page_size; system Ninja fallback is available"
    else
      fail "ARM64 host page size is $page_size; install a system ninja package for the native ARM64 fallback"
    fi
  fi
  require_arm64_elf "$android_root/prebuilts/cmake/linux-arm64/bin/cmake" "ARM64 CMake"
  require_arm64_elf "$android_root/prebuilts/jdk/jdk21/linux-arm64/bin/javac" "ARM64 JDK 21 javac"
  require_arm64_elf "$android_root/prebuilts/jdk/jdk21/linux-arm64/bin/jlink" "ARM64 JDK 21 jlink"
  require_file "$android_root/prebuilts/jdk/jdk8/linux-arm64/jre/lib/rt.jar"

  clang_tools_root="$android_root/prebuilts/clang-tools/linux-arm64"
  if [[ -L "$clang_tools_root" ]]; then
    fail "ARM64 clang-tools prebuilt must be real, not a symlink: prebuilts/clang-tools/linux-arm64 -> $(readlink "$clang_tools_root")"
  fi
  for tool in bindgen cxx_extractor header-abi-diff header-abi-dumper header-abi-linker ide_query_cc_analyzer proto_metadata_plugin protoc_extractor; do
    [[ -e "$clang_tools_root/bin/$tool" ]] || continue
    require_arm64_elf "$clang_tools_root/bin/$tool" "ARM64 clang-tools $tool"
  done
  require_arm64_elf "$clang_tools_root/bin/header-abi-dumper" "ARM64 clang-tools header-abi-dumper"
}

check_arm64_bootanimation_mogrify() {
  host_is_arm64 || return 0
  target_enabled arm64 || return 0

  case "${VALIDATE_BOOTANIMATION_MOGRIFY:-1}" in
    0|false|no|off)
      log "bootanimation mogrify validation skipped by VALIDATE_BOOTANIMATION_MOGRIFY=0"
      return 0
      ;;
  esac

  log "checking ARM64 host bootanimation mogrify fallback"

  local script prebuilt
  script="$android_root/vendor/lineage/bootanimation/gen-bootanimation.sh"
  prebuilt="$android_root/prebuilts/tools-lineage/linux-x86/bin/mogrify"

  require_file "$script"
  require_file "$prebuilt"

  if [[ -f "$prebuilt" ]] && ! readelf -h "$prebuilt" 2>/dev/null | grep -Eq 'Machine:[[:space:]]+AArch64'; then
    grep -Fq 'resolve_mogrify()' "$script" || \
      fail "bootanimation script does not fall back from the x86 mogrify prebuilt: ${script#$android_root/}"
    command -v mogrify >/dev/null 2>&1 || \
      fail "ARM64 host bootanimation fallback requires native mogrify; install ImageMagick"
  fi
}

check_no_arm64_x86_prebuilt_substitutions() {
  host_is_arm64 || return 0
  target_enabled arm64 || return 0

  local link target
  while IFS= read -r link; do
    [[ "$(basename "$link")" == "linux-arm64" ]] || continue
    target="$(readlink "$link")"
    case "$target" in
      *linux-x86*|*x86_64*|*x86-64*)
        fail "ARM64 prebuilt path points at an x86 prebuilt: ${link#$android_root/} -> $target"
        ;;
    esac
  done < <(find "$android_root/prebuilts" -path '*linux-arm64*' -type l -print 2>/dev/null)
}

check_microg_prebuilts() {
  case "${INCLUDE_MICROG:-1}" in
    0|false|no|off)
      log "microG validation skipped by INCLUDE_MICROG=0"
      return 0
      ;;
  esac

  local partner="$android_root/vendor/partner_gms"
  local apk
  for apk in \
    "$partner/GmsCore/GmsCore.apk" \
    "$partner/FakeStore/FakeStore.apk" \
    "$partner/GsfProxy/GsfProxy.apk" \
    "$partner/FDroid/FDroid.apk" \
    "$partner/FDroidPrivilegedExtension/FDroidPrivilegedExtension.apk"
  do
    require_file "$apk"
    if [[ -f "$apk" ]]; then
      if head -c 128 "$apk" | grep -q 'git-lfs.github.com/spec'; then
        fail "APK is still a Git LFS pointer: $apk"
      elif ! validate_zip_file "$apk" >/dev/null 2>&1; then
        fail "invalid APK zip: $apk"
      else
        audit_apk_16k_alignment "$apk" "third-party microG prebuilt $(basename "$apk")" allow_compat
      fi
    fi
  done
}

check_webview_prebuilts() {
  local arch apk
  for arch in "${targets[@]}"; do
    case "$arch" in
      arm64) apk="$android_root/external/chromium-webview/prebuilt/arm64/webview.apk" ;;
      x86_64) apk="$android_root/external/chromium-webview/prebuilt/x86_64/webview.apk" ;;
      *) continue ;;
    esac

    require_file "$apk"
    if [[ -f "$apk" ]]; then
      if head -c 128 "$apk" | grep -q 'git-lfs.github.com/spec'; then
        fail "WebView prebuilt is still a Git LFS pointer: $apk"
      elif ! validate_zip_file "$apk" >/dev/null 2>&1; then
        fail "invalid WebView prebuilt APK: $apk"
      elif [[ "$arch" == "arm64" ]]; then
        audit_apk_16k_alignment "$apk" "ARM64 WebView prebuilt" fail
      fi
    fi
  done
}

check_native_bridge() {
  target_enabled x86_64 || return 0

  case "${INCLUDE_X86_ARM_NATIVE_BRIDGE:-1}" in
    0|false|no|off)
      log "native bridge validation skipped by INCLUDE_X86_ARM_NATIVE_BRIDGE=0"
      return 0
      ;;
  esac

  local bridge="$android_root/vendor/lineage_desktop/prebuilts/native_bridge"
  local system="$bridge/system"
  local vulkaninfo_bp="$overlay_dir/tools/vulkaninfo/Android.bp"
  local vulkaninfo_wrapper="$overlay_dir/tools/vulkaninfo/vulkaninfo_arm64.sh"
  local required
  for required in \
    "$bridge/Android.bp" \
    "$bridge/manifest.json" \
    "$system/bin/ndk_translation_program_runner_binfmt_misc_arm64" \
    "$system/etc/binfmt_misc/arm64_dyn" \
    "$system/etc/binfmt_misc/arm64_exe" \
    "$system/etc/init/ndk_translation.rc" \
    "$system/etc/ld.config.arm64.txt" \
    "$system/lib64/libndk_translation.so" \
    "$android_root/frameworks/libs/native_bridge_support/android_api/libc/Android.bp" \
    "$vulkaninfo_bp" \
    "$vulkaninfo_wrapper"
  do
    require_file "$required"
  done

  grep -q 'ro.dalvik.vm.native.bridge=libndk_translation.so' \
    "$overlay_dir/config/x86_arm_native_bridge.mk" || \
    fail "x86 native bridge product properties are missing"
  grep -Fq 'vulkaninfo.native_bridge:64' "$overlay_dir/config/x86_arm_native_bridge.mk" || \
    fail "x86 native bridge diagnostic vulkaninfo package is missing"
  if [[ "$(grep -Fc 'system_ext_specific: true' "$vulkaninfo_bp")" -lt 2 ]]; then
    fail "vulkaninfo diagnostics must install to system_ext, outside generic_system's /system artifact path"
  fi
  grep -Fq '/system_ext/bin/arm64/vulkaninfo /system_ext/bin/arm64/vulkaninfo' "$vulkaninfo_wrapper" || \
    fail "x86 native bridge vulkaninfo wrapper must run the system_ext arm64 guest binary"
}

check_desktop_flags() {
  local checker="$overlay_dir/scripts/check_desktop_flags.sh"
  require_file "$checker"
  if [[ -x "$checker" ]]; then
    # Surface diagnostics directly so callers can see which flag is missing,
    # not just that "validation failed".
    local checker_output
    if ! checker_output="$("$checker" "$android_root" 2>&1)"; then
      fail "required desktop aconfig flags are not all enabled:"
      printf '%s\n' "$checker_output" >&2
    fi
  else
    fail "desktop flag checker is not executable: $checker"
  fi
}

# Negative checks: assert phone-flavored defaults are NOT present in the
# desktop overlay or its inherited base. These guards keep the tablet-shaped
# app compatibility surface enforced under rebases that might re-introduce
# phone surfaces.
#
# Note on `set -e` interaction: every grep below uses `if grep ...; then`
# (not `grep && fail`) so that a "no match" exit code (1) is consumed by the
# `if`, and the function still returns 0 on the all-clear path. A trailing
# `return 0` is defensive against future edits.
check_no_phone_defaults() {
  local product_mk
  product_mk="$overlay_dir/config/common_desktop_mode_only.mk"

  if ! grep -Eq '^[[:space:]]*PRODUCT_CHARACTERISTICS[[:space:]]*:?=[[:space:]]*tablet' "$product_mk"; then
    fail "PRODUCT_CHARACTERISTICS=tablet is missing in $product_mk"
  fi
  if grep -Eq '^[[:space:]]*PRODUCT_CHARACTERISTICS[[:space:]]*:?=[[:space:]]*phone' "$product_mk"; then
    fail "PRODUCT_CHARACTERISTICS=phone appears in $product_mk"
  fi

  local desktop_android_info="$android_root/device/google/cuttlefish/shared/desktop/android-info.txt"
  local desktop_device_vendor="$android_root/device/google/cuttlefish/shared/desktop/device_vendor.mk"
  require_file "$desktop_android_info"
  require_file "$desktop_device_vendor"
  if ! grep -Eq '^[[:space:]]*config=tablet[[:space:]]*$' "$desktop_android_info"; then
    fail "desktop Cuttlefish android-info.txt does not select config=tablet"
  fi
  if ! grep -Eq '^[[:space:]]*TARGET_BOARD_INFO_FILE[[:space:]]*\?=[[:space:]]*device/google/cuttlefish/shared/desktop/android-info\.txt[[:space:]]*$' "$desktop_device_vendor"; then
    fail "desktop device_vendor.mk does not point TARGET_BOARD_INFO_FILE at shared/desktop/android-info.txt"
  fi

  local framework_res="$overlay_dir/overlays/framework-res/res/values/config.xml"
  if [[ -f "$framework_res" ]]; then
    if grep -Eq '"config_voice_capable">[[:space:]]*true' "$framework_res"; then
      fail "config_voice_capable is true in $framework_res; desktop has no telephony"
    fi
    if grep -Eq '"config_sms_capable">[[:space:]]*true' "$framework_res"; then
      fail "config_sms_capable is true in $framework_res"
    fi
    if grep -Eq '"config_mobile_data_capable">[[:space:]]*true' "$framework_res"; then
      fail "config_mobile_data_capable is true in $framework_res"
    fi
  fi

  local settings_provider="$overlay_dir/overlays/SettingsProvider/res/values/defaults.xml"
  if [[ -f "$settings_provider" ]]; then
    if grep -Eq '"def_lockscreen_disabled">[[:space:]]*false' "$settings_provider"; then
      fail "def_lockscreen_disabled is false in $settings_provider (desktop ships without a lockscreen)"
    fi
  fi

  return 0
}

# Verify the lunch combos declared in AndroidProducts.mk actually point at
# product makefiles we ship.
check_product_makefiles() {
  local products_mk="$overlay_dir/AndroidProducts.mk"
  require_file "$products_mk"

  local mk
  while IFS= read -r mk; do
    [[ -z "$mk" ]] && continue
    require_file "$overlay_dir/$mk"
  done < <(awk '
    /PRODUCT_MAKEFILES/ { capturing=1 }
    capturing {
      n = split($0, parts, /[ \t\\]+/)
      for (i = 1; i <= n; i++) {
        if (parts[i] ~ /\$\(LOCAL_DIR\)\//) {
          path = parts[i]
          sub(/\$\(LOCAL_DIR\)\//, "", path)
          print path
        }
      }
      if ($0 !~ /\\$/) capturing=0
    }
  ' "$products_mk")

  return 0
}

check_zipalign_rom_package() {
  local common_mk="$overlay_dir/config/common_desktop_mode_only.mk"
  require_file "$common_mk"
  [[ -f "$common_mk" ]] || return 0

  grep -Eq '(^|[[:space:]\\])zipalign([[:space:]\\]|$)' "$common_mk" || \
    fail "zipalign is not included in the shared desktop ROM package list: $common_mk"
}

check_arm64_page_size_product_defaults() {
  target_enabled arm64 || return 0

  local arm64_mk="$overlay_dir/products/lineage_desktop_cf_arm64_pgagnostic.mk"
  local x86_mk="$overlay_dir/products/lineage_desktop_cf_x86_64.mk"

  require_file "$arm64_mk"
  [[ -f "$arm64_mk" ]] || return 0

  grep -Eq '^[[:space:]]*PRODUCT_CHECK_PREBUILT_MAX_PAGE_SIZE[[:space:]]*:?=[[:space:]]*true' "$arm64_mk" || \
    fail "ARM64 product must enable PRODUCT_CHECK_PREBUILT_MAX_PAGE_SIZE: $arm64_mk"
  grep -Eq '^[[:space:]]*bionic\.linker\.16kb\.app_compat\.enabled[[:space:]]*=[[:space:]]*true' "$arm64_mk" || \
    fail "ARM64 product must default-enable linker 16 KB app compat: $arm64_mk"
  grep -Eq '^[[:space:]]*pm\.16kb\.app_compat\.disabled[[:space:]]*=[[:space:]]*false' "$arm64_mk" || \
    fail "ARM64 product must default-enable PackageManager 16 KB app compat: $arm64_mk"

  if [[ -f "$x86_mk" ]] && grep -Eq '16kb\.app_compat|PRODUCT_CHECK_PREBUILT_MAX_PAGE_SIZE' "$x86_mk"; then
    fail "4K/16K app compat defaults must stay ARM64-only, but x86 product contains them: $x86_mk"
  fi
}

check_vulkan_header_version() {
  local expected_version=341
  local header="$android_root/external/vulkan-headers/include/vulkan/vulkan_core.h"
  local registry="$android_root/external/vulkan-headers/registry/vk.xml"

  require_file "$header"
  require_file "$registry"
  [[ -f "$header" && -f "$registry" ]] || return 0

  grep -Eq "^[[:space:]]*#define[[:space:]]+VK_HEADER_VERSION[[:space:]]+$expected_version[[:space:]]*$" "$header" || \
    fail "external/vulkan-headers is not at VK_HEADER_VERSION $expected_version: $header"
  grep -Eq "<name>VK_HEADER_VERSION</name>[[:space:]]+$expected_version</type>" "$registry" || \
    fail "external/vulkan-headers registry is not at VK_HEADER_VERSION $expected_version: $registry"

  return 0
}

check_vulkan_ndk_abi_dumps() {
  local arch api dump enum
  local -a required_enums=(
    'name: "VK_FORMAT_ASTC_3x3x3_UNORM_BLOCK_EXT"'
    'name: "VK_PIPELINE_BIND_POINT_DATA_GRAPH_ARM"'
    'name: "VK_ERROR_VALIDATION_FAILED"'
    'name: "VK_ERROR_PRESENT_TIMING_QUEUE_FULL_EXT"'
  )
  local -a required_api28_enums=(
    'name: "VK_EXTERNAL_MEMORY_HANDLE_TYPE_OH_NATIVE_BUFFER_BIT_OHOS"'
  )

  for arch in arm64 x86_64; do
    target_enabled "$arch" || continue

    for api in 24 25 26 27 28 29 30 31 32 33 34 35 36; do
      dump="$android_root/prebuilts/abi-dumps/ndk/$api/$arch/libvulkan/abi.stg"
      require_file "$dump"
      [[ -f "$dump" ]] || continue

      for enum in "${required_enums[@]}"; do
        grep -Fq "$enum" "$dump" || \
          fail "$arch libvulkan NDK $api ABI dump is not refreshed for Vulkan 1.4.341: missing $enum in $dump"
      done

      if (( api >= 28 )); then
        for enum in "${required_api28_enums[@]}"; do
          grep -Fq "$enum" "$dump" || \
            fail "$arch libvulkan NDK $api ABI dump is not refreshed for Vulkan 1.4.341: missing $enum in $dump"
        done
      fi
    done
  done
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
  usage
  exit 0
fi

if (( $# < 1 )); then
  usage >&2
  exit 2
fi

android_root="$(cd "$1" && pwd)"
shift
mapfile -t targets < <(normalize_targets "$@")

check_unscoped_x86_flags
check_bison_genrules
check_trusty_arm64_host_link_config
check_arm64_clang_compat
check_arm64_native_host_prebuilts
check_arm64_bootanimation_mogrify
check_no_arm64_x86_prebuilt_substitutions
check_patch_series
check_patched_xml_resource_references
check_userdata_policy
check_x86_64_64_bit_only_product
check_arm64_min_arch_variant
check_microg_prebuilts
check_webview_prebuilts
check_native_bridge
check_desktop_flags
check_no_phone_defaults
check_product_makefiles
check_zipalign_rom_package
check_arm64_page_size_product_defaults
check_vulkan_header_version
check_vulkan_ndk_abi_dumps

if (( failures > 0 )); then
  exit 1
fi

log "ok"
