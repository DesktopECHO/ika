#!/usr/bin/env bash
set -euo pipefail

# Re-sign a target-files.zip with the LineageOS Desktop release keys, then
# extract the resulting partition images into a staging directory for the
# bundle scripts to consume.
#
# Usage: sign_target_files.sh <input-target-files.zip> <output-signed.zip> [signed-images-dir]
#
# The --extra_apks / --extra_apex_payload_key flag list is generated from the
# APEXes actually present in <input-target-files.zip>, so the command stays
# minimal for Cuttlefish (which ships only a subset of the wiki's APEX list).
# Missing APEX keys are fatal by default; set STRICT_APEX_SIGNING=0 only for
# local debugging when keeping a module's build-time/default signature is
# intentional.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/signing_common.sh"
require_signing_keys

strict_apex_signing="${STRICT_APEX_SIGNING:-1}"
strict_presigned_allowlist="${STRICT_PRESIGNED_ALLOWLIST:-1}"
case "$strict_apex_signing" in
  1|true|yes|on) strict_apex_signing=1 ;;
  0|false|no|off) strict_apex_signing=0 ;;
  *)
    printf '[lineage-desktop] error: invalid STRICT_APEX_SIGNING=%s; use 1 or 0\n' \
      "$strict_apex_signing" >&2
    exit 1
    ;;
esac
case "$strict_presigned_allowlist" in
  1|true|yes|on) strict_presigned_allowlist=1 ;;
  0|false|no|off) strict_presigned_allowlist=0 ;;
  *)
    printf '[lineage-desktop] error: invalid STRICT_PRESIGNED_ALLOWLIST=%s; use 1 or 0\n' \
      "$strict_presigned_allowlist" >&2
    exit 1
    ;;
esac

if [[ -f "$script_dir/../src/build/envsetup.sh" ]]; then
  repo_root="$(cd "$script_dir/../src" && pwd)"
elif [[ -f "$script_dir/../../../build/envsetup.sh" ]]; then
  repo_root="$(cd "$script_dir/../../.." && pwd)"
else
  printf '[lineage-desktop] error: missing Android source tree; expected %s or an in-tree vendor/lineage_desktop checkout\n' \
    "$script_dir/../src" >&2
  exit 1
fi

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <input-target-files.zip> <output-signed-target-files.zip> [signed-images-dir]

  input  Built by \`m target-files-package\`; typically lives at
         out/target/product/<product>/obj/PACKAGING/target_files_intermediates/<product>-target_files.zip
  output Receives the re-signed zip.
  dir    Optional. If given, IMAGES/* are extracted into it so the bundle
         scripts can pick them up in place of out/target/product/<product>/*.img.

Environment:
  STRICT_APEX_SIGNING  Fail if any shipped APEX lacks a matching
                       $ANDROID_CERTS_DIR/<apex>.{pk8,pem}. Default: 1.
  STRICT_PRESIGNED_ALLOWLIST
                       Fail if an APK/APEX is marked PRESIGNED/EXTERNAL but is
                       not in this wrapper's explicit allowlist. Default: 1.
EOF
  exit 1
}

[[ $# -ge 2 ]] || usage
input_zip="$1"
output_zip="$2"
signed_images_dir="${3:-}"

[[ -f "$input_zip" ]] || {
  printf '[lineage-desktop] error: missing input target-files zip: %s\n' "$input_zip" >&2
  exit 1
}

# The wrapper cd's to $repo_root before invoking sign_target_files_apks (so
# its relative apex-key path lookups resolve). Resolve any caller-supplied
# relative paths to absolute now, before that cd loses them.
input_zip="$(readlink -f "$input_zip")"
output_zip_dir="$(dirname "$output_zip")"
mkdir -p "$output_zip_dir"
output_zip="$(readlink -f "$output_zip_dir")/$(basename "$output_zip")"
if [[ -n "$signed_images_dir" ]]; then
  mkdir -p "$signed_images_dir"
  signed_images_dir="$(readlink -f "$signed_images_dir")"
fi

sign_tool="$(find_signing_tool sign_target_files_apks "$repo_root")" || {
  printf '[lineage-desktop] error: sign_target_files_apks not found under %s/out/host/*/bin/\n' "$repo_root" >&2
  printf '[lineage-desktop] add `otatools` to the m line, or run `m otatools` once.\n' >&2
  exit 1
}

build_super_image_tool=""
if [[ -n "$signed_images_dir" ]]; then
  build_super_image_tool="$(find_signing_tool build_super_image "$repo_root")" || {
    printf '[lineage-desktop] error: build_super_image not found under %s/out/host/*/bin/\n' "$repo_root" >&2
    printf '[lineage-desktop] add `otatools` to the m line, or run `m otatools` once.\n' >&2
    exit 1
  }
fi

# Discover APEXes inside the target-files zip. We only emit flags for ones
# that are actually present so the command line stays sane (the upstream wiki
# lists ~75 APEXes; a Cuttlefish desktop build ships a small subset).
#
# Compressed APEXes (.capex) are handled internally by sign_target_files_apks
# via GetApexFilename() (.capex -> .apex), so we normalize both to the .apex
# name when generating --extra_apks / --extra_apex_payload_key flags.
mapfile -t apex_basenames < <(
  unzip -l "$input_zip" \
    | awk '{print $NF}' \
    | awk -F/ '/\.c?apex$/ {print $NF}' \
    | sed 's/\.capex$/.apex/' \
    | sort -u
)

allowlisted_presigned_apks=(
  # microG / F-Droid prebuilts keep their upstream package signatures as app
  # identity. Re-signing them breaks update and permission compatibility.
  FDroid.apk
  FDroidPrivilegedExtension.apk
  FakeStore.apk
  GmsCore.apk
  GsfProxy.apk

  # AOSP CTS / test fixtures are intentionally presigned, malformed, or signed
  # with specific fixture certs. Re-signing changes the behavior under test.
  AndroidXComposeStartupApp.apk
  CtsCorruptApkTests_Compressed_Q.apk
  CtsCorruptApkTests_Compressed_R.apk
  CtsCorruptApkTests_Unaligned_Q.apk
  CtsCorruptApkTests_Unaligned_R.apk
  CtsCorruptApkTests_b71360999.apk
  CtsCorruptApkTests_b71361168.apk
  CtsCorruptApkTests_b79488511.apk
  CtsDuplicatePermissionDeclareApp_DifferentProtectionLevel.apk
  CtsDuplicatePermissionDeclareApp_SameProtectionLevel.apk
  CtsMalformedDuplicatePermission_DifferentPermissionGroup.apk
  CtsShimPrebuilt.apk
  CtsShimPrivPrebuilt.apk
  CtsShimPrivUpgradePrebuilt.apk
  CtsShimPrivUpgradeWrongSHAPrebuilt.apk
  CtsShimTargetPSdkPrebuilt.apk
  androidx.test.orchestrator.apk
  androidx.test.services.test-services.apk
  signed-CtsOmapiTestCases.apk
  signed-CtsSecureElementAccessControlTestCases1.apk
  signed-CtsSecureElementAccessControlTestCases2.apk
  signed-CtsSecureElementAccessControlTestCases3.apk
)

# Soong records each split module in META/apkcerts.txt under the module output
# name, while the target-files archive contains the filename requested by the
# module's `filename` property. Keep the two identities paired: the former is
# checked by the strict PRESIGNED allowlist and the latter is passed to
# sign_target_files_apks so it can find and preserve the Google signature.
mtg_gms_split_apk_pairs=(
  "GmsCoreAdsDynamite.apk|split_AdsDynamite_installtime.apk"
  "GmsCoreConfigEn.apk|split_config.en.apk"
  "GmsCoreConfigLdpi.apk|split_config.ldpi.apk"
  "GmsCoreConfigMdpi.apk|split_config.mdpi.apk"
  "GmsCoreConfigHdpi.apk|split_config.hdpi.apk"
  "GmsCoreConfigXhdpi.apk|split_config.xhdpi.apk"
  "GmsCoreConfigXxhdpi.apk|split_config.xxhdpi.apk"
  "GmsCoreConfigXxxhdpi.apk|split_config.xxxhdpi.apk"
  "GmsCoreCronetDynamite.apk|split_CronetDynamite_installtime.apk"
  "GmsCoreDynamiteLoader.apk|split_DynamiteLoader_installtime.apk"
  "GmsCoreDynamiteModulesA.apk|split_DynamiteModulesA_installtime.apk"
  "GmsCoreDynamiteModulesC.apk|split_DynamiteModulesC_installtime.apk"
  "GmsCoreGoogleCertificates.apk|split_GoogleCertificates_installtime.apk"
  "GmsCoreMapsDynamite.apk|split_MapsDynamite_installtime.apk"
  "GmsCoreMeasurementDynamite.apk|split_MeasurementDynamite_installtime.apk"
)
mtg_gms_split_cert_names=()
mtg_gms_split_installed_names=()
for pair in "${mtg_gms_split_apk_pairs[@]}"; do
  mtg_gms_split_cert_names+=("${pair%%|*}")
  mtg_gms_split_installed_names+=("${pair#*|}")
done

if [[ "${LINEAGE_DESKTOP_GMS_PROVIDER:-none}" == "mtg" ]]; then
  # MindTheGapps modules deliberately retain Google's package signatures.
  allowlisted_presigned_apks+=(
    AndroidAutoStub.apk
    GoogleCalendarSyncAdapter.apk
    GoogleContactsSyncAdapter.apk
    GoogleFeedback.apk
    GooglePartnerSetup.apk
    GoogleRestore.apk
    GoogleServicesFramework.apk
    MarkupGoogle_v2.apk
    Phonesky.apk
    PrebuiltExchange3Google.apk
    PrebuiltGmsCoreVic.apk
    SetupWizard.apk
    SpeechServicesByGoogle.apk
    Velvet.apk
    VelvetTitan.apk
    Wellbeing.apk
    talkback.apk
  )
  allowlisted_presigned_apks+=("${mtg_gms_split_cert_names[@]}")
fi

allowlisted_presigned_apexes=(
  # AOSP's CTS shim APEX is a prebuilt fixture with PRESIGNED metadata.
  com.android.apex.cts.shim.apex
)

if [[ "${LINEAGE_DESKTOP_GMS_PROVIDER:-none}" == "mtg" ]]; then
  allowlisted_presigned_apexes+=(com.google.android.gmssystem.prodvic.apex)
fi

contains_item() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

mapfile -t special_apk_entries < <(unzip -p "$input_zip" META/apkcerts.txt 2>/dev/null | awk '
  {
    apk = ""; cert = "";
    if (match($0, /name="[^"]+"/)) {
      apk = substr($0, RSTART+6, RLENGTH-7);
    }
    if (match($0, /certificate="[^"]+"/)) {
      cert = substr($0, RSTART+13, RLENGTH-14);
    }
    if (apk != "" && (cert == "PRESIGNED" || cert == "EXTERNAL")) {
      print apk "\t" cert;
    }
  }
')

unexpected_special_apks=()
for entry in "${special_apk_entries[@]}"; do
  IFS=$'\t' read -r apk cert_name <<<"$entry"
  if contains_item "$apk" "${allowlisted_presigned_apks[@]}"; then
    printf '[lineage-desktop] allowing presigned apk %s (%s)\n' "$apk" "$cert_name"
  else
    unexpected_special_apks+=("$apk:$cert_name")
  fi
done

if (( ${#unexpected_special_apks[@]} > 0 )); then
  if [[ "$strict_presigned_allowlist" == "1" ]]; then
    printf '[lineage-desktop] error: unexpected APK special cert string(s):\n' >&2
    for entry in "${unexpected_special_apks[@]}"; do
      printf '[lineage-desktop]   %s\n' "$entry" >&2
    done
    printf '[lineage-desktop] set STRICT_PRESIGNED_ALLOWLIST=0 only for local debugging.\n' >&2
    exit 1
  fi
  for entry in "${unexpected_special_apks[@]}"; do
    printf '[lineage-desktop] warning: unexpected APK special cert string: %s\n' "$entry" >&2
  done
fi

declare -A presigned_apex_names=()
while IFS= read -r apex_name; do
  [[ -n "$apex_name" ]] || continue
  presigned_apex_names["$apex_name"]=1
done < <(unzip -p "$input_zip" META/apexkeys.txt 2>/dev/null | awk '
  {
    name = ""; payload_public = ""; payload_private = "";
    container_cert = ""; container_private = "";
    if (match($0, /name="[^"]+"/)) {
      name = substr($0, RSTART+6, RLENGTH-7);
    }
    if (match($0, /public_key="[^"]+"/)) {
      payload_public = substr($0, RSTART+12, RLENGTH-13);
    }
    if (match($0, /private_key="[^"]+"/)) {
      payload_private = substr($0, RSTART+13, RLENGTH-14);
    }
    if (match($0, /container_certificate="[^"]+"/)) {
      container_cert = substr($0, RSTART+23, RLENGTH-24);
    }
    if (match($0, /container_private_key="[^"]+"/)) {
      container_private = substr($0, RSTART+23, RLENGTH-24);
    }
    if (name != "" &&
        payload_public == "PRESIGNED" &&
        payload_private == "PRESIGNED" &&
        container_cert == "PRESIGNED" &&
        container_private == "PRESIGNED") {
      print name;
    }
  }
')

# Wiki-mandated extra APK overrides: a handful of mainline modules are
# distributed as APKs (not APEXes) but still need releasekey signing.
extra_releasekey_apks=(
  com.android.appsearch.apk.apk
  AdServicesApk.apk
  FederatedCompute.apk
  HalfSheetUX.apk
  HealthConnectBackupRestore.apk
  HealthConnectController.apk
  OsuLogin.apk
  SafetyCenterResources.apk
  ServiceConnectivityResources.apk
  ServiceUwbResources.apk
  ServiceWifiResources.apk
  WifiDialog.apk
)

sign_args=(-o -d "$ANDROID_CERTS_DIR")

# apkcerts.txt uses the GmsCore module aliases above, but releasetools indexes
# actual archive entries by basename. Add PRESIGNED mappings for only the
# split filenames present in this target so signing neither rejects them as
# unknown nor replaces Google's signatures.
presigned_apk_aliases=0
if [[ "${LINEAGE_DESKTOP_GMS_PROVIDER:-none}" == "mtg" ]]; then
  mapfile -t installed_apk_basenames < <(
    unzip -Z1 "$input_zip" \
      | awk -F/ '/\.apk$/ {print $NF}' \
      | sort -u
  )
  for installed_apk in "${mtg_gms_split_installed_names[@]}"; do
    if contains_item "$installed_apk" "${installed_apk_basenames[@]}"; then
      sign_args+=(--extra_apks "$installed_apk=")
      presigned_apk_aliases=$((presigned_apk_aliases + 1))
    fi
  done
fi

# `-d` populates an internal key_map for the well-known mainline cert tags
# (testkey/devkey/media/shared/platform/networkstack/sdk_sandbox/bluetooth),
# but not for `nfc`. That same key_map is what ReplaceCerts() walks to rewrite
# embedded certs in mac_permissions.xml. Without an explicit nfc remap, we
# re-sign NfcNciApex.apk (inside com.android.nfcservices.apex) with the user's
# release nfc cert via --extra_apks below, but mac_permissions.xml keeps the
# AOSP-test nfc cert under @NFC. SELinuxMMAC then can't match the running
# apk's cert, falls back to seinfo=default, no seapp_contexts row matches
# user=nfc seinfo=default, and zygote SIGABRTs on every com.android.nfc fork.
if [[ -f "$ANDROID_CERTS_DIR/nfc.pk8" && -f "$ANDROID_CERTS_DIR/nfc.x509.pem" ]]; then
  sign_args+=(-k "build/make/target/product/security/nfc=$ANDROID_CERTS_DIR/nfc")
fi

for apk in "${extra_releasekey_apks[@]}"; do
  sign_args+=(--extra_apks "$apk=$ANDROID_CERTS_DIR/releasekey")
done

# Apply our keys to every APK whose cert tag we have a matching key for.
# Without this, inner APKs of re-signed APEXes (e.g. NfcNciApex.apk inside
# com.android.nfcservices.apex) fall back to the build's default cert path
# (build/make/target/product/security/<tag>.{pk8,x509.pem}), which doesn't
# exist in the host sandbox, and signapk.jar aborts with FileNotFoundException.
# `-d` populates the top-level apk_keys but doesn't propagate into APEX
# payload re-signing, so we explicitly enumerate.
apk_overrides=0
while IFS=$'\t' read -r apk cert_name; do
  if [[ -f "$ANDROID_CERTS_DIR/$cert_name.pk8" && -f "$ANDROID_CERTS_DIR/$cert_name.x509.pem" ]]; then
    sign_args+=(--extra_apks "$apk=$ANDROID_CERTS_DIR/$cert_name")
    apk_overrides=$((apk_overrides + 1))
  fi
done < <(unzip -p "$input_zip" META/apkcerts.txt 2>/dev/null | awk '
  {
    apk = ""; cert = "";
    if (match($0, /name="[^"]+"/)) {
      apk = substr($0, RSTART+6, RLENGTH-7);
    }
    if (match($0, /certificate="[^"]+"/)) {
      cert = substr($0, RSTART+13, RLENGTH-14);
    }
    if (apk == "" || cert == "" || cert == "PRESIGNED" || cert == "EXTERNAL") next;
    n = split(cert, parts, "/");
    cert_name = parts[n];
    sub(/\.x509\.pem$/, "", cert_name);
    print apk "\t" cert_name;
  }
')

# Build a map of apex_filename -> (payload_pem, container_stem) from
# apexkeys.txt. Without this, sign_target_files_apks silently generates
# ephemeral RSA4096 keys per APEX whenever its internal payload-key resolution
# fails (it changes cwd into a temp extraction dir, so the relative paths
# from apexkeys.txt stop resolving). That breaks multi-install APEXes like
# com.android.hardware.keymint.* — apexd refuses to load any of them when
# their public keys differ, and keystore2 then SIGABRTs at boot.
declare -A apex_payload_pems=()
declare -A apex_container_stems=()
while IFS=$'\t' read -r ak_name ak_payload_pem ak_container_pk8; do
  [[ -z "$ak_name" || -z "$ak_payload_pem" || -z "$ak_container_pk8" ]] && continue
  [[ "$ak_payload_pem" == "PRESIGNED" || "$ak_container_pk8" == "PRESIGNED" ]] && continue
  apex_payload_pems[$ak_name]="$ak_payload_pem"
  apex_container_stems[$ak_name]="${ak_container_pk8%.pk8}"
done < <(unzip -p "$input_zip" META/apexkeys.txt 2>/dev/null | awk '
  {
    name = ""; payload_private = ""; container_private = "";
    if (match($0, /name="[^"]+"/)) {
      name = substr($0, RSTART+6, RLENGTH-7);
    }
    if (match($0, /private_key="[^"]+"/)) {
      payload_private = substr($0, RSTART+13, RLENGTH-14);
    }
    if (match($0, /container_private_key="[^"]+"/)) {
      container_private = substr($0, RSTART+23, RLENGTH-24);
    }
    if (name != "" && payload_private != "" && container_private != "") {
      print name "\t" payload_private "\t" container_private;
    }
  }
')

apex_signed=0
apex_skipped=0
apex_presigned=0
apex_build_default=0
missing_apex_keys=()
unexpected_presigned_apexes=()
for apex_file in "${apex_basenames[@]}"; do
  apex_name="${apex_file%.apex}"
  if [[ -n "${presigned_apex_names[$apex_file]:-}" ]]; then
    if contains_item "$apex_file" "${allowlisted_presigned_apexes[@]}"; then
      printf '[lineage-desktop] allowing presigned apex %s\n' "$apex_file"
      apex_presigned=$((apex_presigned + 1))
    else
      unexpected_presigned_apexes+=("$apex_file")
      if [[ "$strict_presigned_allowlist" == "0" ]]; then
        printf '[lineage-desktop] warning: unexpected presigned apex %s\n' "$apex_file" >&2
      fi
    fi
    continue
  fi
  # Look up the APEX's payload + container key names from apexkeys.txt. Keys
  # are addressed by their on-disk basename (the AOSP "apex key name", e.g.
  # com.google.cf.apex), NOT by APEX filename. Multi-install APEX variants
  # (com.android.hardware.keymint.rust_*) intentionally share a payload key
  # name in apexkeys.txt — apexd refuses to load them if their public keys
  # diverge. Looking up by APEX filename instead would give each variant a
  # distinct key and break boot.
  payload_rel="${apex_payload_pems[$apex_file]:-}"
  container_rel="${apex_container_stems[$apex_file]:-}"
  if [[ -z "$payload_rel" || -z "$container_rel" ]]; then
    missing_apex_keys+=("$apex_name")
    if [[ "$strict_apex_signing" == "0" ]]; then
      printf '[lineage-desktop] warning: %s missing from META/apexkeys.txt; leaving default signature\n' "$apex_file" >&2
    fi
    apex_skipped=$((apex_skipped + 1))
    continue
  fi
  payload_key_name="$(basename "$payload_rel" .pem)"
  container_key_name="$(basename "$container_rel")"
  if [[ -f "$ANDROID_CERTS_DIR/$payload_key_name.pem" \
        && -f "$ANDROID_CERTS_DIR/$container_key_name.pk8" \
        && -f "$ANDROID_CERTS_DIR/$container_key_name.x509.pem" ]]; then
    sign_args+=(--extra_apks "$apex_file=$ANDROID_CERTS_DIR/$container_key_name")
    sign_args+=(--extra_apex_payload_key "$apex_file=$ANDROID_CERTS_DIR/$payload_key_name.pem")
    apex_signed=$((apex_signed + 1))
  else
    # No user key for this apex_key_name; pin to the absolutized build path
    # so sign_target_files_apks doesn't silently generate an ephemeral key.
    sign_args+=(--extra_apks "$apex_file=$repo_root/${container_rel}")
    sign_args+=(--extra_apex_payload_key "$apex_file=$repo_root/${payload_rel}")
    apex_build_default=$((apex_build_default + 1))
  fi
done

if (( ${#unexpected_presigned_apexes[@]} > 0 && strict_presigned_allowlist == 1 )); then
  printf '[lineage-desktop] error: unexpected presigned APEX module(s):\n' >&2
  for apex_file in "${unexpected_presigned_apexes[@]}"; do
    printf '[lineage-desktop]   %s\n' "$apex_file" >&2
  done
  printf '[lineage-desktop] set STRICT_PRESIGNED_ALLOWLIST=0 only for local debugging.\n' >&2
  exit 1
fi

if (( ${#missing_apex_keys[@]} > 0 && strict_apex_signing == 1 )); then
  printf '[lineage-desktop] error: missing signing keys for %d shipped APEX module(s):\n' \
    "${#missing_apex_keys[@]}" >&2
  for apex_name in "${missing_apex_keys[@]}"; do
    printf '[lineage-desktop]   %s (expected %s/%s.pk8 and %s/%s.pem)\n' \
      "$apex_name" "$ANDROID_CERTS_DIR" "$apex_name" "$ANDROID_CERTS_DIR" "$apex_name" >&2
    printf '[lineage-desktop]     plus container cert %s/%s.x509.pem\n' \
      "$ANDROID_CERTS_DIR" "$apex_name" >&2
  done
  printf '[lineage-desktop] generate missing keys with: ANDROID_CERTS_DIR=%q %q\n' \
    "$ANDROID_CERTS_DIR" "$script_dir/generate_signing_keys.sh" >&2
  printf '[lineage-desktop] for local debugging only, set STRICT_APEX_SIGNING=0 to keep default APEX signatures.\n' >&2
  exit 1
fi

# ANDROID_PW_FILE is honored by sign_target_files_apks itself; just make sure
# it's exported in case the caller only set it for the parent shell.
[[ -n "${ANDROID_PW_FILE:-}" ]] && export ANDROID_PW_FILE

printf '[lineage-desktop] signing %s\n' "$(basename "$input_zip")"
printf '[lineage-desktop]   apk overrides: %d (from META/apkcerts.txt)\n' "$apk_overrides"
printf '[lineage-desktop]   presigned APK filename aliases: %d\n' "$presigned_apk_aliases"
printf '[lineage-desktop]   apex: %d user-signed, %d build-default-signed, %d presigned, %d skipped (no key)\n' \
  "$apex_signed" "$apex_build_default" "$apex_presigned" "$apex_skipped"

tmp_output="${output_zip}.tmp.$$"
trap 'rm -f "$tmp_output"' EXIT

# sign_target_files_apks resolves APEX container/payload key paths from
# apexkeys.txt as paths relative to the Android source root (e.g.
# "hardware/interfaces/apexkey/com.android.hardware.pem"). Run from there so
# those lookups succeed regardless of where this wrapper was invoked from.
cd "$repo_root"
"$sign_tool" "${sign_args[@]}" "$input_zip" "$tmp_output"
mv -f "$tmp_output" "$output_zip"
trap - EXIT

if [[ -n "$signed_images_dir" ]]; then
  printf '[lineage-desktop] extracting signed IMAGES/* to %s\n' "$signed_images_dir"
  rm -rf "$signed_images_dir"
  mkdir -p "$signed_images_dir"
  # -j strips the IMAGES/ prefix so files land flat alongside the bundle's
  # expected layout (super.img, boot.img, vbmeta.img, ...).
  unzip -q -o -j "$output_zip" 'IMAGES/*' -d "$signed_images_dir"
  unzip -q -o -j "$output_zip" 'META/misc_info.txt' -d "$signed_images_dir"

  # sign_target_files_apks updates the individual dynamic partition images and
  # vbmeta descriptors, but target-files zips commonly do not carry IMAGES/super.img.
  # Rebuild it here so the bundle never mixes release-key vbmeta with a pre-sign
  # super partition.
  printf '[lineage-desktop] rebuilding signed super.img\n'
  tmp_super="$signed_images_dir/super.img.tmp.$$"
  PATH="$(dirname "$build_super_image_tool"):$PATH" \
    "$build_super_image_tool" "$output_zip" "$tmp_super"
  [[ -f "$tmp_super" ]] || {
    printf '[lineage-desktop] error: build_super_image did not produce %s\n' "$tmp_super" >&2
    exit 1
  }
  mv -f "$tmp_super" "$signed_images_dir/super.img"
fi

printf '[lineage-desktop] signed target-files: %s\n' "$output_zip"
