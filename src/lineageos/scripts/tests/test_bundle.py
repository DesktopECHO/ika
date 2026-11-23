#!/usr/bin/env python3

from pathlib import Path
import hashlib
import json
import shlex
import subprocess
import tempfile
import unittest


BUNDLE_SH = Path(__file__).resolve().parents[1] / "lib" / "bundle.sh"


def bash_path(path: Path) -> str:
    """Quote a path for bash, including Git Bash drive mapping on Windows."""
    path = path.resolve()
    value = path.as_posix()
    if path.drive:
        value = f"/{path.drive[0].lower()}{value[2:]}"
    return shlex.quote(value)


class BundleTest(unittest.TestCase):
    def test_native_bridge_diagnostics_are_only_required_when_requested(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bundle_dir = root / "bundle"
            bundle_dir.mkdir()
            (bundle_dir / "build-info.json").write_text(
                json.dumps({"ika": {"source_commit": "a" * 40}})
            )
            (bundle_dir / "build-info.txt").write_text("test bundle\n")
            (bundle_dir / "android-info.txt").write_text("config=tablet\n")

            test_dir = bundle_dir / "testcases/native_bridge"
            test_dir.mkdir(parents=True)
            for name in (
                "ndk_program_tests",
                "ndk_program_tests_static",
                "run-tests.sh",
            ):
                path = test_dir / name
                path.write_bytes(b"test")
                path.chmod(0o755)
            (test_dir / "manifest.json").write_text("{}\n")

            script = f"""
set -e
enabled() {{ case "${{1:-}}" in 1|true|yes|on) return 0;; *) return 1;; esac; }}
desktop_android_info_selects_tablet() {{ grep -q '^config=tablet$' "$1"; }}
source {bash_path(BUNDLE_SH)}
IKA_SOURCE_COMMIT=
include_x86_arm_native_bridge=1
build_native_bridge_tests=0
bundle_dir_complete x86_64 {bash_path(bundle_dir)}
build_native_bridge_tests=1
bundle_dir_complete x86_64 {bash_path(bundle_dir)}
rm {bash_path(test_dir / 'ndk_program_tests_static')}
! bundle_dir_complete x86_64 {bash_path(bundle_dir)}
build_native_bridge_tests=0
bundle_dir_complete x86_64 {bash_path(bundle_dir)}
"""
            subprocess.run(["bash", "-c", script], check=True)

    def test_android_16_vulkan_cts_outputs_use_host_apk_and_product_binary(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            product_out = root / "out/target/product/ika_x86_64"
            apk = (
                root
                / "out/host/linux-x86/testcases/CtsDeqpTestCases"
                / "com.drawelements.deqp.apk"
            )
            binary = (
                product_out
                / "testcases/deqp-binary/x86_64/deqp-binary64"
            )
            resource = (
                root
                / "out/host/linux-x86/testcases/CtsDeqpTestCases/vulkan"
                / "amber/api/descriptor_set/descriptor_set_layout_binding"
                / "layout_binding_order.amber"
            )
            apk.parent.mkdir(parents=True)
            binary.parent.mkdir(parents=True)
            resource.parent.mkdir(parents=True)
            apk.write_bytes(b"apk")
            binary.write_bytes(b"binary")
            binary.chmod(0o755)
            resource.write_bytes(b"amber")

            bundle_dir = root / "bundle"

            script = f"""
set -e
workspace={bash_path(root)}
build_vulkan_tests=1
source {bash_path(BUNDLE_SH)}
vulkan_test_outputs_complete {bash_path(product_out)} linux-x86
! vulkan_test_outputs_complete {bash_path(product_out)} linux-arm64
copy_vulkan_test_outputs {bash_path(product_out)} linux-x86 {bash_path(bundle_dir)}
"""
            subprocess.run(["bash", "-c", script], check=True)
            self.assertEqual(
                (bundle_dir / "testcases/vulkan/CtsDeqpTestCases.apk").read_bytes(),
                b"apk",
            )
            bundled_binary = bundle_dir / "testcases/vulkan/deqp-binary"
            self.assertEqual(bundled_binary.read_bytes(), b"binary")
            self.assertTrue(bundled_binary.stat().st_mode & 0o111)
            self.assertEqual(
                (
                    bundle_dir
                    / "testcases/vulkan/vulkan/amber/api/descriptor_set"
                    / "descriptor_set_layout_binding/layout_binding_order.amber"
                ).read_bytes(),
                b"amber",
            )

    def test_native_bridge_installed_payload_must_match_manifest(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            product_out = root / "product"
            installed = product_out / "system/lib64/libndk_translation.so"
            installed.parent.mkdir(parents=True)
            installed.write_bytes(b"current translator")
            manifest = root / "manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "format_version": 1,
                        "files": [
                            {
                                "path": "lib64/libndk_translation.so",
                                "size": installed.stat().st_size,
                                "sha256": hashlib.sha256(installed.read_bytes()).hexdigest(),
                            }
                        ],
                    }
                )
            )

            script = f"""
set -e
workspace={bash_path(root)}
source {bash_path(BUNDLE_SH)}
native_bridge_image_outputs_match_manifest {bash_path(product_out)} {bash_path(manifest)}
printf stale > {bash_path(installed)}
! native_bridge_image_outputs_match_manifest {bash_path(product_out)} {bash_path(manifest)}
"""
            subprocess.run(["bash", "-c", script], check=True)

    def make_digitalis_product(self, product_out: Path, bridge: str) -> None:
        files = [
            "bin/arm64/app_process64",
            "bin/arm64/linker64",
            "bin/berberis_program_runner_binfmt_misc_arm64",
            "etc/binfmt_misc/arm64_dyn",
            "etc/binfmt_misc/arm64_exe",
            "etc/init/berberis.rc",
            "etc/ld.config.arm64.txt",
            "lib64/libberberis_arm64.so",
            "lib64/libberberis_exec_region.so",
        ]
        files += [
            f"lib64/libberberis_proxy_{lib}.so"
            for lib in ("libEGL", "libGLESv2", "libandroid", "libc", "libm",
                        "libnativewindow", "libvulkan")
        ]
        files += [
            f"lib64/arm64/{lib}.so"
            for lib in ("libEGL", "libGLESv2", "libandroid", "libc", "libdl", "libm",
                        "libnativewindow", "libvulkan")
        ]
        for relpath in files:
            path = product_out / "system" / relpath
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(relpath.encode())
        (product_out / "system/build.prop").write_text(
            "ro.product.cpu.abilist=x86_64,arm64-v8a\n"
        )
        (product_out / "product/etc").mkdir(parents=True)
        (product_out / "product/etc/build.prop").write_text(
            f"ro.dalvik.vm.native.bridge={bridge}\n"
            "ro.dalvik.vm.isa.arm64=x86_64\n"
            "ro.enable.native.bridge.exec=1\n"
        )

    def test_digitalis_is_the_default_translator(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            product_out = root / "product"
            self.make_digitalis_product(product_out, "libberberis_arm64.so")
            manifest = root / "manifest.json"

            script = f"""
set -e
unset X86_ARM_TRANSLATOR x86_arm_translator
workspace={bash_path(root)}
source {bash_path(BUNDLE_SH)}
[[ "$(native_bridge_translator)" == digitalis ]]
native_bridge_image_outputs_complete {bash_path(product_out)}
write_native_bridge_output_manifest {bash_path(product_out)} {bash_path(manifest)}
x86_arm_translator=ndk_translation
! native_bridge_image_outputs_complete {bash_path(product_out)}
"""
            subprocess.run(["bash", "-c", script], check=True)

            data = json.loads(manifest.read_text())
            self.assertEqual(data["format_version"], 1)
            self.assertEqual(data["native_bridge"], "libberberis_arm64.so")
            paths = {entry["path"] for entry in data["files"]}
            self.assertIn("lib64/libberberis_arm64.so", paths)
            self.assertIn("lib64/libberberis_proxy_libvulkan.so", paths)
            self.assertIn("etc/init/berberis.rc", paths)
            self.assertNotIn("lib64/arm64/libc.so", paths)
            entry = next(e for e in data["files"] if e["path"] == "lib64/libberberis_arm64.so")
            self.assertEqual(
                entry["sha256"], hashlib.sha256(b"lib64/libberberis_arm64.so").hexdigest()
            )

    def test_digitalis_image_needs_its_bridge_property(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            product_out = root / "product"
            self.make_digitalis_product(product_out, "libndk_translation.so")

            script = f"""
set -e
workspace={bash_path(root)}
x86_arm_translator=digitalis
source {bash_path(BUNDLE_SH)}
! native_bridge_image_outputs_complete {bash_path(product_out)}
"""
            subprocess.run(["bash", "-c", script], check=True)


if __name__ == "__main__":
    unittest.main()
