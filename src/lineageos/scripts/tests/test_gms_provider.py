#!/usr/bin/env python3

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
PARSER = ROOT / "scripts" / "lib" / "gms_provider.sh"
MANIFEST = ROOT / "manifests" / "mindthegapps.xml"
PRODUCT_CONFIG = ROOT / "config" / "common_desktop_mode_only.mk"
ARM64_PRODUCT = ROOT / "products" / "lineage_desktop_cf_arm64_pgagnostic.mk"
X86_64_PRODUCT = ROOT / "products" / "lineage_desktop_cf_x86_64.mk"
SOURCES = ROOT / "scripts" / "lib" / "sources.sh"
COMMON = ROOT / "scripts" / "lib" / "common.sh"
GMS_CHECKSUMS = ROOT / "prebuilts" / "mindthegapps" / "x86_64" / "gmscore" / "SHA256SUMS"
MODERN_GMS_PATCH = ROOT / "patches" / "vendor-gapps-x86_64-modern-gms.patch"
BUNDLE = ROOT / "scripts" / "lib" / "bundle.sh"
SIGN_TARGET_FILES = ROOT / "scripts" / "sign_target_files.sh"
VALIDATE_BUILD_INPUTS = ROOT / "scripts" / "lib" / "validate_build_inputs.sh"


class GmsProviderTest(unittest.TestCase):
    def parse(self, *arguments):
        script = r'''
source "$1"
shift
provider=""
targets=()
if parse_gms_provider_arguments provider targets "$@"; then
  printf 'provider=%s\n' "$provider"
  printf 'help=%s\n' "$GMS_PROVIDER_SHOW_HELP"
  printf 'target=%s\n' "${targets[@]}"
else
  status=$?
  printf '%s\n' "$GMS_PROVIDER_PARSE_ERROR" >&2
  exit "$status"
fi
'''
        return subprocess.run(
            ["bash", "-c", script, "bash", str(PARSER), *arguments],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def prompt(self, user_input):
        script = r'''
source "$1"
provider=""
if prompt_gms_provider provider; then
  printf 'provider=%s\n' "$provider"
else
  printf '%s\n' "$GMS_PROVIDER_PARSE_ERROR" >&2
  exit 1
fi
'''
        return subprocess.run(
            ["bash", "-c", script, "bash", str(PARSER)],
            input=user_input,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def test_no_switch_selects_no_provider(self):
        result = self.parse("arm64")
        self.assertEqual(0, result.returncode)
        self.assertIn("provider=none\n", result.stdout)
        self.assertIn("target=arm64\n", result.stdout)

    def test_each_provider_preserves_both_architecture_targets(self):
        cases = (
            ("--microg", "microg"),
            ("--mtg", "mtg"),
        )
        for option, provider in cases:
            with self.subTest(option=option):
                result = self.parse("arm64", option, "x86_64")
                self.assertEqual(0, result.returncode)
                self.assertIn(f"provider={provider}\n", result.stdout)
                self.assertIn("target=arm64\n", result.stdout)
                self.assertIn("target=x86_64\n", result.stdout)

    def test_provider_switches_are_mutually_exclusive(self):
        result = self.parse("--microg", "--mtg", "arm64")
        self.assertEqual(2, result.returncode)
        self.assertIn("cannot be used together", result.stderr)

    def test_interactive_prompt_offers_each_provider_choice(self):
        for selection, provider in (("1\n", "microg"), ("2\n", "mtg"), ("3\n", "none")):
            with self.subTest(selection=selection.strip()):
                result = self.prompt(selection)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertIn("Select GMS (App Store) Integration:", result.stdout)
                self.assertIn("3) DeGoogled, no App Store", result.stdout)
                self.assertIn(f"provider={provider}\n", result.stdout)

    def test_interactive_prompt_retries_invalid_choice(self):
        result = self.prompt("invalid\n2\n")
        self.assertEqual(0, result.returncode)
        self.assertIn("Please enter 1, 2, or 3.", result.stderr)
        self.assertIn("provider=mtg\n", result.stdout)

    def test_mindthegapps_manifest_and_product_cover_both_architectures(self):
        manifest = ET.parse(MANIFEST).getroot()
        project = manifest.find("project")
        self.assertIsNotNone(project)
        self.assertEqual("vendor/gapps", project.attrib["path"])
        self.assertEqual("vendor_gapps", project.attrib["name"])
        self.assertEqual("baklava", project.attrib["revision"])

        product = PRODUCT_CONFIG.read_text()
        self.assertIn("ifeq ($(LINEAGE_DESKTOP_GMS_PROVIDER),mtg)", product)
        self.assertIn(
            "vendor/gapps/$(LINEAGE_DESKTOP_MTG_ARCH)/$(LINEAGE_DESKTOP_MTG_ARCH)-vendor.mk",
            product,
        )
        self.assertIn("LINEAGE_DESKTOP_MTG_ARCH := arm64", ARM64_PRODUCT.read_text())
        self.assertIn("LINEAGE_DESKTOP_MTG_ARCH := x86_64", X86_64_PRODUCT.read_text())

    def test_product_provider_matrix_expands_for_both_architectures(self):
        make = shutil.which("make")
        self.assertIsNotNone(make)
        harness = f"""
inherit-product = $(eval INHERITED += $(strip $(1)))
include {PRODUCT_CONFIG}
.PHONY: all
all:
\t@printf 'with_gms=%s\\n' '$(WITH_GMS)'
\t@printf 'inherited=%s\\n' '$(INHERITED)'
"""

        for arch in ("arm64", "x86_64"):
            for provider, expected_with_gms in (
                ("none", "false"),
                ("microg", "true"),
                ("mtg", "true"),
            ):
                with self.subTest(arch=arch, provider=provider):
                    result = subprocess.run(
                        [
                            make,
                            "--no-print-directory",
                            "-f",
                            "-",
                            f"LINEAGE_DESKTOP_MTG_ARCH={arch}",
                            f"LINEAGE_DESKTOP_GMS_PROVIDER={provider}",
                        ],
                        input=harness,
                        check=False,
                        text=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                    )
                    self.assertEqual(0, result.returncode, result.stderr)
                    self.assertIn(f"with_gms={expected_with_gms}\n", result.stdout)
                    expected_mtg = f"vendor/gapps/{arch}/{arch}-vendor.mk"
                    if provider == "mtg":
                        self.assertIn(expected_mtg, result.stdout)
                    else:
                        self.assertNotIn("vendor/gapps/", result.stdout)

    def test_x86_64_gms_density_splits_stay_wired_through_packaging(self):
        checksums = GMS_CHECKSUMS.read_text()
        patch = MODERN_GMS_PATCH.read_text()
        bundle = BUNDLE.read_text()
        signing = SIGN_TARGET_FILES.read_text()
        validator = VALIDATE_BUILD_INPUTS.read_text()

        for filename, module in (
            ("split_config.ldpi.apk", "GmsCoreConfigLdpi"),
            ("split_config.mdpi.apk", "GmsCoreConfigMdpi"),
            ("split_config.hdpi.apk", "GmsCoreConfigHdpi"),
            ("split_config.xhdpi.apk", "GmsCoreConfigXhdpi"),
            ("split_config.xxhdpi.apk", "GmsCoreConfigXxhdpi"),
            ("split_config.xxxhdpi.apk", "GmsCoreConfigXxxhdpi"),
        ):
            with self.subTest(filename=filename):
                self.assertIn(f"  {filename}\n", checksums)
                self.assertIn(f'name: "{module}"', patch)
                self.assertIn(f'apk: "proprietary/product/priv-app/GmsCore/{filename}"', patch)
                self.assertIn(f'"{filename}",', bundle)
                self.assertIn(f'"{module}.apk|{filename}"', signing)
                self.assertIn(module, validator)

    def test_x86_64_gms_split_cert_names_map_to_installed_filenames(self):
        signing = SIGN_TARGET_FILES.read_text()

        for module, filename in (
            ("GmsCoreAdsDynamite", "split_AdsDynamite_installtime.apk"),
            ("GmsCoreConfigEn", "split_config.en.apk"),
            ("GmsCoreConfigLdpi", "split_config.ldpi.apk"),
            ("GmsCoreConfigMdpi", "split_config.mdpi.apk"),
            ("GmsCoreConfigHdpi", "split_config.hdpi.apk"),
            ("GmsCoreConfigXhdpi", "split_config.xhdpi.apk"),
            ("GmsCoreConfigXxhdpi", "split_config.xxhdpi.apk"),
            ("GmsCoreConfigXxxhdpi", "split_config.xxxhdpi.apk"),
            ("GmsCoreCronetDynamite", "split_CronetDynamite_installtime.apk"),
            ("GmsCoreDynamiteLoader", "split_DynamiteLoader_installtime.apk"),
            ("GmsCoreDynamiteModulesA", "split_DynamiteModulesA_installtime.apk"),
            ("GmsCoreDynamiteModulesC", "split_DynamiteModulesC_installtime.apk"),
            ("GmsCoreGoogleCertificates", "split_GoogleCertificates_installtime.apk"),
            ("GmsCoreMapsDynamite", "split_MapsDynamite_installtime.apk"),
            ("GmsCoreMeasurementDynamite", "split_MeasurementDynamite_installtime.apk"),
        ):
            with self.subTest(module=module):
                self.assertIn(f'"{module}.apk|{filename}"', signing)

        self.assertIn('sign_args+=(--extra_apks "$installed_apk=")', signing)

    def test_provider_switch_cleans_the_provider_being_removed(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            workspace = root / "workspace"
            overlay = root / "overlay"
            (workspace / ".lineage-desktop-managed").parent.mkdir(parents=True)
            (workspace / ".lineage-desktop-managed").touch()
            (overlay / "patches").mkdir(parents=True)
            (overlay / "patches" / "series").touch()

            for relative in ("vendor/partner_gms", "vendor/gapps"):
                checkout = workspace / relative
                checkout.mkdir(parents=True)
                subprocess.run(["git", "init", "-q", str(checkout)], check=True)
                tracked = checkout / "tracked.txt"
                tracked.write_text("clean\n")
                subprocess.run(["git", "-C", str(checkout), "add", "tracked.txt"], check=True)
                subprocess.run(
                    [
                        "git",
                        "-C",
                        str(checkout),
                        "-c",
                        "user.name=Test",
                        "-c",
                        "user.email=test@example.invalid",
                        "commit",
                        "-qm",
                        "initial",
                    ],
                    check=True,
                )
                tracked.write_text("changed\n")
                (checkout / "downloaded.apk").write_text("downloaded\n")

            script = r'''
workspace="$1"
overlay_dir="$2"
reset_patched_projects=auto
skip_patch=0
source "$3"
source "$4"
log() { :; }
die() { printf '%s\n' "$*" >&2; exit 1; }
reset_patched_projects_for_sync
'''
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    script,
                    "bash",
                    str(workspace),
                    str(overlay),
                    str(COMMON),
                    str(SOURCES),
                ],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            self.assertEqual(0, result.returncode, result.stderr)

            for relative in ("vendor/partner_gms", "vendor/gapps"):
                checkout = workspace / relative
                status = subprocess.check_output(
                    ["git", "-C", str(checkout), "status", "--short"], text=True
                )
                self.assertEqual("", status)
                self.assertEqual("clean\n", (checkout / "tracked.txt").read_text())
                self.assertFalse((checkout / "downloaded.apk").exists())


if __name__ == "__main__":
    unittest.main()
