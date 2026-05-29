#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
overlay_dir="$(cd "$script_dir/.." && pwd)"

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

validate_zip_file() {
  local zip_file="$1"

  python3 - "$zip_file" <<'PY'
from pathlib import Path
import sys
import zipfile

path = Path(sys.argv[1])
try:
    with zipfile.ZipFile(path) as archive:
        bad_member = archive.testzip()
except zipfile.BadZipFile as exc:
    raise SystemExit(f"{path}: {exc}")

if bad_member:
    raise SystemExit(f"{path}: corrupt zip member {bad_member}")
PY
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

host_is_arm64() {
  case "$(uname -m)" in
    aarch64|arm64)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_source_root_patch_project() {
  [[ "$1" == "." ]]
}

patch_project_dir() {
  local project="$1"
  if is_source_root_patch_project "$project"; then
    printf '%s\n' "$android_root"
  else
    printf '%s/%s\n' "$android_root" "$project"
  fi
}

patch_project_label() {
  local project="$1"
  if is_source_root_patch_project "$project"; then
    printf '%s\n' "source root"
  else
    printf '%s\n' "$project"
  fi
}

git_apply_for_patch_project() {
  local project="$1"
  shift

  if is_source_root_patch_project "$project"; then
    GIT_CEILING_DIRECTORIES="$(dirname "$android_root")" \
      git -C "$android_root" apply "$@"
  else
    git -C "$(patch_project_dir "$project")" apply "$@"
  fi
}

check_single_patch_applied() {
  local project="$1"
  local patch="$2"
  local patch_path project_label

  patch_path="$overlay_dir/$patch"
  project_label="$(patch_project_label "$project")"

  if ! git_apply_for_patch_project "$project" --check --reverse --whitespace=nowarn "$patch_path" >/dev/null 2>&1; then
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

    project_dir="$(patch_project_dir "$project")"
    patch_path="$overlay_dir/$patch"

    require_file "$patch_path"
    if is_source_root_patch_project "$project"; then
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
    project_dir="$(patch_project_dir "$project")"

    if is_source_root_patch_project "$project"; then
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
  local project_dir="$android_root/$project"
  local tmp_dir tmp_worktree combined_patch patch patch_path
  local ok=1

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/lineage-patch-validate.XXXXXX")" || {
    fail "could not create temporary directory for patch validation"
    return
  }
  tmp_worktree="$tmp_dir/worktree"
  combined_patch="$tmp_dir/combined.patch"

  if ! git -C "$project_dir" worktree add --detach --quiet "$tmp_worktree" HEAD >/dev/null 2>&1; then
    fail "could not create temporary worktree for $project"
    rm -rf "$tmp_dir"
    return
  fi

  while IFS= read -r patch; do
    [[ -n "$patch" ]] || continue
    patch_path="$overlay_dir/$patch"
    if ! git -C "$tmp_worktree" apply --index --whitespace=nowarn "$patch_path" >/dev/null 2>&1; then
      fail "patch series does not apply cleanly to $project at $patch"
      ok=0
      break
    fi
  done <<<"$patch_list"

  if (( ok )); then
    git -C "$tmp_worktree" diff --cached --binary HEAD -- > "$combined_patch"
    if [[ ! -s "$combined_patch" ]]; then
      fail "patch series produced no changes for $project"
    elif ! git -C "$project_dir" apply --check --reverse "$combined_patch" >/dev/null 2>&1; then
      fail "patch series is not applied cleanly to $project"
    fi
  fi

  git -C "$project_dir" worktree remove --force "$tmp_worktree" >/dev/null 2>&1 || rm -rf "$tmp_worktree"
  rm -rf "$tmp_dir"
}

check_userdata_policy() {
  local shared_device="$android_root/device/google/cuttlefish/shared/device.mk"
  local arm_board="$android_root/device/google/cuttlefish/vsoc_arm64_pgagnostic/BoardConfig.mk"
  local x86_board="$android_root/device/google/cuttlefish/vsoc_x86_64_sandybridge/BoardConfig.mk"

  require_file "$shared_device"
  require_file "$arm_board"
  require_file "$x86_board"

  grep -Eq '^[[:space:]]*TARGET_USERDATAIMAGE_PARTITION_SIZE[[:space:]]*\?=[[:space:]]*66571993088[[:space:]]*$' "$shared_device" || \
    fail "userdata size is not the expected 62 GiB default in $shared_device"
  grep -Eq '^[[:space:]]*TARGET_USERDATAIMAGE_FILE_SYSTEM_TYPE[[:space:]]*:=[[:space:]]*f2fs[[:space:]]*$' "$arm_board" || \
    fail "ARM64 userdata is not f2fs in $arm_board"
  grep -Eq '^[[:space:]]*TARGET_USERDATAIMAGE_FILE_SYSTEM_TYPE[[:space:]]*:=[[:space:]]*f2fs[[:space:]]*$' "$x86_board" || \
    fail "x86-64 userdata is not f2fs in $x86_board"

  if grep -R --include='*.mk' --include='BoardConfig*.mk' \
      --exclude-dir='.git' --exclude-dir='out' --exclude-dir='src' \
      -E '^[[:space:]]*TARGET_USERDATAIMAGE_PARTITION_SIZE[[:space:]]*:=' \
      "$overlay_dir" >/dev/null 2>&1; then
    fail "overlay contains a hard userdata partition size override"
  fi
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

check_arm64_clang_compat() {
  host_is_arm64 || return 0
  target_enabled arm64 || return 0

  local arm64_root="$android_root/prebuilts/clang/host/linux-arm64"
  local x86_root="$android_root/prebuilts/clang/host/linux-x86"
  local clang_dir payload found=0

  [[ -d "$arm64_root" ]] || {
    fail "missing ARM64 Clang prebuilt directory: $arm64_root"
    return 0
  }
  [[ -d "$x86_root" ]] || {
    fail "missing linux-x86 Clang metadata directory: $x86_root"
    return 0
  }

  for clang_dir in "$arm64_root"/clang-r*; do
    [[ -d "$clang_dir" ]] || continue
    found=1
    payload="${clang_dir##*/}"

    require_file "$clang_dir/bin/clang"
    require_file "$clang_dir/include/c++/v1/string"
    require_file "$clang_dir/android_libc++/platform/aarch64/include/c++/v1/__config_site"

    if [[ ! -e "$x86_root/$payload" ]]; then
      fail "missing ARM64 Clang Soong compatibility path: prebuilts/clang/host/linux-x86/$payload"
      continue
    fi
    require_file "$x86_root/$payload/include/c++/v1/string"
    require_file "$x86_root/$payload/android_libc++/platform/aarch64/include/c++/v1/__config_site"
  done

  (( found )) || fail "no clang-r* payload found in $arm64_root"
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
    "$android_root/frameworks/libs/native_bridge_support/android_api/libc/Android.bp"
  do
    require_file "$required"
  done

  grep -q 'ro.dalvik.vm.native.bridge=libndk_translation.so' \
    "$overlay_dir/config/x86_arm_native_bridge.mk" || \
    fail "x86 native bridge product properties are missing"
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
check_arm64_clang_compat
check_patch_series
check_userdata_policy
check_microg_prebuilts
check_webview_prebuilts
check_native_bridge
check_desktop_flags
check_no_phone_defaults
check_product_makefiles

if (( failures > 0 )); then
  exit 1
fi

log "ok"
