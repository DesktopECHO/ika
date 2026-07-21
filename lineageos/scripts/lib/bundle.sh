#!/usr/bin/env bash
# Cuttlefish bundle assembly for the LineageOS Desktop build engine: zip/tar and
# host-package validation, AVB testkey repair, fetcher-config + release-metadata
# emission, and package_cvd_bundle. Source only (defines functions). Relies on
# engine globals + core primitives at call time.

desktop_launcher_target_files_exclusive() {
  local target_files_zip="$1"
  [[ -f "$target_files_zip" && -s "$target_files_zip" ]] || return 1

  python3 - "$target_files_zip" <<'PY'
import sys
import zipfile

target_files = sys.argv[1]
required = "SYSTEM_EXT/priv-app/Launcher3QuickStep/Launcher3QuickStep.apk"
stale_prefixes = (
    "SYSTEM_EXT/priv-app/Launcher3/",
    "SYSTEM_EXT/priv-app/Launcher3Go/",
    "SYSTEM_EXT/priv-app/Launcher3QuickStepGo/",
    "SYSTEM_OTHER/system_ext/priv-app/Launcher3/",
    "SYSTEM_OTHER/system_ext/priv-app/Launcher3Go/",
    "SYSTEM_OTHER/system_ext/priv-app/Launcher3QuickStepGo/",
)
stale_product_overlays = (
    "PRODUCT/overlay/Launcher3__",
    "PRODUCT/overlay/Launcher3Go__",
    "PRODUCT/overlay/Launcher3QuickStepGo__",
)

try:
    with zipfile.ZipFile(target_files) as archive:
        names = set(archive.namelist())
except zipfile.BadZipFile:
    raise SystemExit(1)

if required not in names:
    raise SystemExit(1)

for name in names:
    if any(name.startswith(prefix) for prefix in stale_prefixes):
        raise SystemExit(1)
    if any(name.startswith(prefix) for prefix in stale_product_overlays):
        raise SystemExit(1)
PY
}

# Inspect the assembled archive rather than trusting module selection: the
# x86-64 image must contain the complete modern GMS set and the matching GSF.
mindthegapps_gsf_target_files_exclusive() {
  local arch="$1"
  local target_files_zip="$2"
  local gsf_source gms_source=""

  [[ -f "$target_files_zip" && -s "$target_files_zip" ]] || return 1

  case "$arch" in
    arm64)
      gsf_source="$workspace/vendor/gapps/common/proprietary/system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk"
      ;;
    x86_64)
      gsf_source="$workspace/vendor/gapps/common/proprietary/system_ext/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk"
      gms_source="$workspace/vendor/gapps/x86_64/proprietary/product/priv-app/GmsCore"
      ;;
    *) return 1 ;;
  esac

  python3 - "$target_files_zip" "$arch" "$gsf_source" "$gms_source" <<'PY'
import hashlib
from pathlib import Path, PurePosixPath
import sys
import zipfile

target_files, arch, gsf_source, gms_source = sys.argv[1:]
gsf_entry = "SYSTEM_EXT/priv-app/GoogleServicesFramework/GoogleServicesFramework.apk"
partition_prefixes = ("SYSTEM/", "SYSTEM_EXT/", "PRODUCT/", "VENDOR/", "SYSTEM_OTHER/")
gms_names = (
    "GmsCore.apk",
    "split_AdsDynamite_installtime.apk",
    "split_CronetDynamite_installtime.apk",
    "split_DynamiteLoader_installtime.apk",
    "split_DynamiteModulesA_installtime.apk",
    "split_DynamiteModulesC_installtime.apk",
    "split_GoogleCertificates_installtime.apk",
    "split_MapsDynamite_installtime.apk",
    "split_MeasurementDynamite_installtime.apk",
    "split_config.en.apk",
    "split_config.ldpi.apk",
    "split_config.mdpi.apk",
    "split_config.hdpi.apk",
    "split_config.xhdpi.apk",
    "split_config.xxhdpi.apk",
    "split_config.xxxhdpi.apk",
)

def digest(data):
    return hashlib.sha256(data).hexdigest()

try:
    with zipfile.ZipFile(target_files) as archive:
        names = archive.namelist()
        gsf_entries = sorted(
            name for name in names
            if name.startswith(partition_prefixes)
            and PurePosixPath(name).name == "GoogleServicesFramework.apk"
        )
        if gsf_entries != [gsf_entry]:
            raise ValueError(f"expected only {gsf_entry}, found {gsf_entries}")

        packaged_gsf = archive.read(gsf_entry)
        expected_gsf = Path(gsf_source).read_bytes()
        if digest(packaged_gsf) != digest(expected_gsf):
            raise ValueError("packaged GSF does not match the selected prebuilt")

        if arch == "x86_64":
            if digest(expected_gsf) != "41c0d547ac1466e87ccf783e36192cacbda0f6010128327a2503b4330dc8b534":
                raise ValueError("x86-64 image does not use the pinned Android 16 GSF")

            expected_entries = [f"PRODUCT/priv-app/GmsCore/{name}" for name in gms_names]
            packaged_entries = sorted(
                name for name in names
                if name.startswith("PRODUCT/priv-app/GmsCore/") and name.endswith(".apk")
            )
            if packaged_entries != sorted(expected_entries):
                raise ValueError(
                    f"expected GMS APKs {sorted(expected_entries)}, found {packaged_entries}"
                )

            for name, entry in zip(gms_names, expected_entries):
                expected_gms = (Path(gms_source) / name).read_bytes()
                packaged_gms = archive.read(entry)
                if digest(packaged_gms) != digest(expected_gms):
                    raise ValueError(f"packaged {name} does not match its Google-signed prebuilt")
except (OSError, ValueError, zipfile.BadZipFile, KeyError) as exc:
    print(f"MindTheGapps package selection error: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

valid_targz_archive() {
  local path="$1"
  [[ -f "$path" && -s "$path" ]] || return 1
  tar -tzf "$path" >/dev/null 2>&1
}

critical_host_package_zero_entries() {
  local host_package="$1"

  tar -tzvf "$host_package" 2>/dev/null | awk '
    $1 ~ /^-/ && $3 == 0 {
      name = $6
      sub(/^\.\//, "", name)
      if (name == "bin/crosvm" ||
          name == "bin/extract-ikconfig" ||
          name == "bin/extract-vmlinux") {
        print name
      }
    }
  '
}

cvd_host_package_critical_tools_complete() {
  local host_package="$1"
  [[ -f "$host_package" && -s "$host_package" ]] || return 1

  local bad_entries
  bad_entries="$(critical_host_package_zero_entries "$host_package")" || return 1
  [[ -z "$bad_entries" ]]
}

repair_zero_size_cvd_host_package() {
  local host_package="$1"
  [[ -f "$host_package" ]] || return 0

  local bad_entries
  bad_entries="$(critical_host_package_zero_entries "$host_package")" || return 0
  [[ -n "$bad_entries" ]] || return 0

  log "removing Cuttlefish host package with zero-size critical tool(s): ${bad_entries//$'\n'/, }"
  rm -f "$host_package" "${host_package%.tar.gz}.stamp"
  rm -rf "${host_package%.tar.gz}"
}

valid_pem_private_key() {
  local path="$1"
  [[ -s "$path" ]] && grep -q 'BEGIN RSA PRIVATE KEY' "$path"
}

rom_avb_private_key() {
  local bits="$1"
  local key="$workspace/external/avb/test/data/testkey_rsa${bits}.pem"

  [[ -f "$key" ]] || die "missing ROM AVB test private key: $key"
  valid_pem_private_key "$key" || die "invalid ROM AVB test private key: $key"
  printf '%s\n' "$key"
}

repair_cvd_host_package_avb_keys() {
  local host_package="$1"
  local tmp_dir tmp_package bits src dest repaired=0

  valid_targz_archive "$host_package" || \
    die "invalid Cuttlefish host package: $host_package"

  tmp_dir="$(mktemp -d)"
  if ! tar -xzf "$host_package" -C "$tmp_dir"; then
    rm -rf "$tmp_dir"
    die "failed to extract Cuttlefish host package: $host_package"
  fi

  mkdir -p "$tmp_dir/etc"
  for bits in 2048 4096; do
    src="$(rom_avb_private_key "$bits")"
    dest="$tmp_dir/etc/cvd_avb_testkey_rsa${bits}.pem"
    if valid_pem_private_key "$dest"; then
      continue
    fi
    log "repairing $(basename "$host_package"): etc/cvd_avb_testkey_rsa${bits}.pem"
    install -m 0644 "$src" "$dest"
    repaired=1
  done

  if (( repaired )); then
    tmp_package="${host_package}.tmp"
    if ! tar -czf "$tmp_package" -C "$tmp_dir" .; then
      rm -rf "$tmp_dir"
      rm -f "$tmp_package"
      die "failed to rewrite Cuttlefish host package: $host_package"
    fi
    mv "$tmp_package" "$host_package"
  fi

  for bits in 2048 4096; do
    dest="$tmp_dir/etc/cvd_avb_testkey_rsa${bits}.pem"
    valid_pem_private_key "$dest" || {
      rm -rf "$tmp_dir"
      die "Cuttlefish host package still has an invalid AVB key: $host_package:etc/cvd_avb_testkey_rsa${bits}.pem"
    }
  done
  rm -rf "$tmp_dir"
}

valid_zip_container() {
  local path="$1"
  [[ -f "$path" && -s "$path" ]] || return 1
  python3 - "$path" <<'PY'
from pathlib import Path
import sys
import zipfile

path = Path(sys.argv[1])
try:
    with zipfile.ZipFile(path) as archive:
        if not archive.namelist():
            raise SystemExit(1)
except zipfile.BadZipFile:
    raise SystemExit(1)
PY
}

bundle_dir_complete() {
  local bundle_dir="$1"
  shift

  [[ -d "$bundle_dir" ]] || return 1

  local member
  for member in "build-info.json" "build-info.txt" "$@"; do
    [[ -e "$bundle_dir/$member" ]] || return 1
  done

  [[ -s "$bundle_dir/testcases/vulkan/CtsDeqpTestCases.apk" ]] || return 1
  [[ -x "$bundle_dir/testcases/vulkan/deqp-binary" ]] || return 1

  desktop_android_info_selects_tablet "$bundle_dir/android-info.txt"
}

vulkan_test_outputs_complete() {
  local product_out="$1"
  local apk binary

  apk="$(find "$product_out/testcases/com.drawelements.deqp" -type f \
    -name 'com.drawelements.deqp.apk' -print -quit 2>/dev/null || true)"
  binary="$(find "$product_out/testcases/deqp-binary" -type f \
    -name 'deqp-binary*' -print -quit 2>/dev/null || true)"

  [[ -n "$apk" && -s "$apk" && -n "$binary" && -s "$binary" && -x "$binary" ]]
}

built_target_outputs_complete() {
  local product="$1"
  local product_out="$2"
  local host_package="$3"
  shift 3

  [[ -d "$product_out" ]] || return 1
  valid_targz_archive "$host_package" || return 1
  cvd_host_package_critical_tools_complete "$host_package" || return 1

  local target_files="$product_out/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip"
  valid_zip_container "$target_files" || return 1
  desktop_launcher_outputs_exclusive "$product_out" "$target_files" || return 1
  desktop_android_info_selects_tablet "$product_out/android-info.txt" || return 1

  local f
  for f in "$@"; do
    [[ -f "$product_out/$f" && -s "$product_out/$f" ]] || return 1
  done
}

remove_packaged_target_outputs() {
  local product="$1"
  local product_out="$2"
  local host_package="$3"
  shift 3

  local target_files_dir="$product_out/obj/PACKAGING/target_files_intermediates"
  rm -f \
    "$host_package" \
    "$target_files_dir/${product}-target_files.zip" \
    "$target_files_dir/${product}-target_files.zip.list" \
    "$target_files_dir/${product}-target_files.zip.list.list" \
    "$target_files_dir/${product}-target_files-signed.zip"
  rm -rf "$target_files_dir/${product}-target_files"
  rm -rf "$product_out/obj/PACKAGING/signed_images"

  local f
  for f in "$@"; do
    rm -f "$product_out/$f"
  done
}

remove_target_image_outputs_for_headroom() {
  local product_out="$1"
  [[ -d "$product_out" ]] || return 0

  rm -f \
    "$product_out/system.img" \
    "$product_out/system_ext.img" \
    "$product_out/product.img" \
    "$product_out/vendor.img" \
    "$product_out/system_other.img" \
    "$product_out/odm.img" \
    "$product_out/odm_dlkm.img" \
    "$product_out/system_dlkm.img" \
    "$product_out/vendor_dlkm.img"
  rm -f \
    "$product_out"/obj/PACKAGING/system_intermediates/*.img \
    "$product_out"/obj/PACKAGING/system_ext_intermediates/*.img \
    "$product_out"/obj/PACKAGING/product_intermediates/*.img \
    "$product_out"/obj/PACKAGING/vendor_intermediates/*.img
  find "$workspace/out/soong/.intermediates/device/google/cuttlefish/build/cvd-host_package" \
    -type f -name package.tar.gz -delete 2>/dev/null || true
}

write_fetcher_config() {
  local bundle_dir="$1"
  shift

  local f first=1
  {
    printf '{\n  "cvd_files": {'
    for f in "$@"; do
      [[ -f "$bundle_dir/$f" ]] || continue
      if [[ "$first" -eq 0 ]]; then
        printf ','
      fi
      printf '\n    "%s": { "source": "local_file", "build_id": "", "build_target": "" }' "$f"
      first=0
    done
    printf '\n  }\n}\n'
  } > "$bundle_dir/fetcher_config.json"
}

write_release_metadata() {
  local bundle_dir="$1"
  local arch="$2"
  local product="$3"
  local product_out="$4"
  shift 4

  local metadata_script="$workspace/vendor/lineage_desktop/scripts/write_release_metadata.py"
  [[ -x "$metadata_script" ]] || die "missing release metadata writer: $metadata_script"

  local -a metadata_args=(
    --android-root "$workspace"
    --overlay-dir "$workspace/vendor/lineage_desktop"
    --product-out "$product_out"
    --bundle-dir "$bundle_dir"
    --arch "$arch"
    --product "$product"
    --lineage-branch "$lineage_branch"
  )

  local image
  for image in "$@"; do
    metadata_args+=(--image "$image")
  done

  "$metadata_script" "${metadata_args[@]}"
}

normalize_crosvm_seccomp_policies() {
  local bundle_dir="$1"
  local policy_root="$bundle_dir/usr/share/crosvm"
  [[ -d "$policy_root" ]] || return 0

  python3 - "$policy_root" <<'PY'
import pathlib
import re
import sys

policy_root = pathlib.Path(sys.argv[1])
policy_names = {
    "gpu_device.policy",
    "gpu_render_server.policy",
    "video_device.policy",
    "wl_device.policy",
}
required = (
    "MADV_GUARD_INSTALL",
    "MADV_GUARD_REMOVE",
)
needle = "madvise:"
insert_after = "MADV_FREE"
rewritten = []
bad = []

for policy in sorted(policy_root.glob("*/seccomp/*.policy")):
    if policy.name not in policy_names:
        continue
    try:
        text = policy.read_text(encoding="utf-8")
    except OSError as exc:
        bad.append(f"{policy}: {exc}")
        continue

    lines = text.splitlines(keepends=True)
    changed = False
    for idx, line in enumerate(lines):
        if not line.lstrip().startswith(needle):
            continue
        if all(token in line for token in required):
            continue
        if re.match(r"^\s*madvise:\s*1\s*(?:#.*)?$", line):
            continue
        if insert_after not in line:
            bad.append(f"{policy}: restricted madvise rule does not contain {insert_after}")
            continue
        suffix = "".join(f" || arg2 == {token}" for token in required)
        lines[idx] = line.replace(insert_after, insert_after + suffix, 1)
        changed = True

    if changed:
        policy.write_text("".join(lines), encoding="utf-8")
        rewritten.append(str(policy.relative_to(policy_root)))

for policy in sorted(policy_root.glob("*/seccomp/*.policy")):
    if policy.name not in policy_names:
        continue
    text = policy.read_text(encoding="utf-8")
    for line in text.splitlines():
        if not line.lstrip().startswith(needle):
            continue
        if re.match(r"^\s*madvise:\s*1\s*(?:#.*)?$", line):
            break
        if all(token in line for token in required):
            break
        bad.append(f"{policy}: missing {'/'.join(required)}")
        break

for name in rewritten:
    print(f"[lineage-desktop] updated crosvm seccomp policy: {name}", file=sys.stderr)

if bad:
    for item in bad:
        print(f"[lineage-desktop] error: {item}", file=sys.stderr)
    raise SystemExit(1)
PY
}

thin_provision_images_tool() {
  local tool="$ika_root/tools/lineageos/thin-provision-images.sh"
  [[ -x "$tool" ]] || die "missing executable image thin-provisioning helper: $tool"
  printf '%s\n' "$tool"
}

copy_bundle_file_thin() {
  local src="$1"
  local dest="$2"

  cp --reflink=auto --sparse=always --preserve=timestamps -- "$src" "$dest"
  chmod 0644 "$dest"
}

copy_vulkan_test_outputs() {
  local product_out="$1"
  local bundle_dir="$2"
  local apk binary test_dir

  vulkan_test_outputs_complete "$product_out" || \
    die "missing Vulkan CTS outputs under $product_out/testcases"

  apk="$(find "$product_out/testcases/com.drawelements.deqp" -type f \
    -name 'com.drawelements.deqp.apk' -print -quit)"
  binary="$(find "$product_out/testcases/deqp-binary" -type f \
    -name 'deqp-binary*' -print -quit)"
  test_dir="$bundle_dir/testcases/vulkan"
  mkdir -p "$test_dir"

  # Keep the established CTS artifact name in the release bundle even though
  # current Android branches name the device-side module
  # com.drawelements.deqp.apk.
  copy_bundle_file_thin "$apk" "$test_dir/CtsDeqpTestCases.apk"
  cp --reflink=auto --sparse=always --preserve=timestamps -- "$binary" \
    "$test_dir/deqp-binary"
  chmod 0755 "$test_dir/deqp-binary"
}

package_cvd_bundle() {
  local arch="$1"
  local product="$2"
  local product_out="$3"
  local host_package="$4"
  local signed_images_dir="$5"
  local bundle_name="$6"
  shift 6

  local bundle_dir="$output_dir/$bundle_name"
  local -a thin_files=("$@")

  [[ -d "$product_out" ]] || die "missing product output: $product_out"
  [[ -f "$host_package" ]] || die "missing Cuttlefish host package: $host_package"

  log "packaging $bundle_name"
  rm -rf "$bundle_dir"
  mkdir -p "$bundle_dir"

  # For each bundle file prefer the release-key-signed image emitted into
  # $signed_images_dir by sign_target_files.sh. Files that aren't shipped
  # inside the target-files.zip IMAGES/ tree (kernel binaries, dtb.img,
  # vendor-bootconfig.img, android-info.txt, misc_info.txt, ...) fall back
  # to the original $product_out path so the bundle still includes them.
  local f src copied=0
  for f in "${thin_files[@]}"; do
    src="$signed_images_dir/$f"
    if [[ "$f" == "super.img" && -f "$signed_images_dir/vbmeta.img" && ! -f "$src" ]]; then
      die "signed vbmeta exists but signed super.img is missing in $signed_images_dir"
    fi
    [[ -f "$src" ]] || src="$product_out/$f"
    if [[ -f "$src" ]]; then
      copy_bundle_file_thin "$src" "$bundle_dir/$f"
      copied=$((copied + 1))
    fi
  done
  "$(thin_provision_images_tool)" "$bundle_dir"
  copy_vulkan_test_outputs "$product_out" "$bundle_dir"

  (( copied > 0 )) || die "no image files were copied from $product_out"
  desktop_android_info_selects_tablet "$bundle_dir/android-info.txt" || \
    die "$bundle_name/android-info.txt does not select config=tablet"

  tar -xzf "$host_package" -C "$bundle_dir" --exclude='bin' --exclude='lib64'
  normalize_crosvm_seccomp_policies "$bundle_dir"

  # assemble_cvd requires every etc/cvd_config/*.json preset it might select
  # (via --config=... or via android-info.txt) to be a JSON object; it aborts
  # on the first preset that is empty, unparseable, or non-object. Upstream's
  # cvd-host_package.tar.gz ships several of these as zero-byte stubs.
  # Normalize anything that is not a valid object to {} so the launcher
  # treats it as "no overrides", and log each replacement so future bundle
  # issues surface in the build log instead of going silently.
  if [[ -d "$bundle_dir/etc/cvd_config" ]]; then
    local normalize_status=0
    STRICT_BUNDLE_VALIDATION="$strict_bundle_validation" \
      python3 - "$bundle_dir/etc/cvd_config" <<'PY' || normalize_status=$?
import json, os, pathlib, sys
cfg_dir = pathlib.Path(sys.argv[1])
strict = os.environ.get("STRICT_BUNDLE_VALIDATION", "0") == "1"
rewritten = []
for p in sorted(cfg_dir.glob("*.json")):
    try:
        ok = isinstance(json.loads(p.read_text(encoding="utf-8")), dict)
    except (json.JSONDecodeError, OSError, UnicodeDecodeError):
        ok = False
    if ok:
        continue
    p.write_text("{}\n", encoding="utf-8")
    rewritten.append(p.name)
    print(f"[lineage-desktop] normalized cvd_config preset to {{}}: {p.name}",
          file=sys.stderr)
if rewritten and strict:
    print(
        "[lineage-desktop] STRICT_BUNDLE_VALIDATION=1: refusing to ship a bundle "
        f"with {len(rewritten)} corrupt cvd_config preset(s): "
        + ", ".join(rewritten),
        file=sys.stderr,
    )
    sys.exit(1)
PY
    if (( normalize_status != 0 )); then
      die "etc/cvd_config normalization failed in strict mode for $bundle_name"
    fi
  fi
  write_fetcher_config "$bundle_dir" "${thin_files[@]}"
  write_release_metadata "$bundle_dir" "$arch" "$product" "$product_out" "${thin_files[@]}"

  du -sh "$bundle_dir"
}
