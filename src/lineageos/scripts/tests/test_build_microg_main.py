#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "build_microg_main.py"
SPEC = importlib.util.spec_from_file_location("build_microg_main", SCRIPT)
BUILD_MICROG_MAIN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD_MICROG_MAIN)


class BuildMicrogMainTest(unittest.TestCase):
    def write_file(self, path, content=""):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def write_tool(self, path, exit_status=0):
        self.write_file(path, f"#!/bin/sh\nexit {exit_status}\n")
        path.chmod(0o755)

    def make_aosp_tree(self, root, host_tag):
        android_root = root / "android"
        public_sdk = android_root / "prebuilts" / "sdk" / "35" / "public"
        for relative in (
            "android.jar",
            "core-for-system-modules.jar",
            "framework.aidl",
            "data/api-versions.xml",
        ):
            self.write_file(public_sdk / relative)
        self.write_file(
            android_root / "prebuilts" / "sdk" / "tools" / "core-lambda-stubs.jar"
        )

        host_bin = android_root / "out" / "host" / host_tag / "bin"
        for name in ("aapt2", "aidl", "apksigner", "d8", "zipalign", "adb"):
            self.write_tool(host_bin / name)

        key_dir = android_root / "build" / "make" / "target" / "product" / "security"
        self.write_file(key_dir / "platform.pk8")
        self.write_file(key_dir / "platform.x509.pem")

        java_home = root / "jdk"
        self.write_tool(java_home / "bin" / "java")
        return android_root, java_home

    def test_reads_versions_from_upstream_build(self):
        with tempfile.TemporaryDirectory() as directory:
            source_dir = Path(directory)
            self.write_file(
                source_dir / "build.gradle",
                "ext.androidBuildVersionTools = '35.0.0'\n"
                "ext.androidCompileSdk = 35\n",
            )
            self.assertEqual(
                ("35", "35.0.0"),
                BUILD_MICROG_MAIN.read_android_tool_versions(source_dir),
            )

    def test_temporary_sdk_location_restores_cached_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            source_dir = Path(directory) / "source"
            source_dir.mkdir()
            local_properties = source_dir / "local.properties"
            local_properties.write_text("sdk.dir=/old/sdk\n")

            with BUILD_MICROG_MAIN.temporary_sdk_location(
                source_dir, Path("/selected/sdk")
            ):
                self.assertEqual(
                    "sdk.dir=/selected/sdk\n", local_properties.read_text()
                )

            self.assertEqual("sdk.dir=/old/sdk\n", local_properties.read_text())

    def test_selects_matching_aosp_jdk_for_each_host_architecture(self):
        android_root = Path("/android")
        cases = (
            ("x86_64", "linux-x86"),
            ("aarch64", "linux-arm64"),
            ("arm64", "linux-arm64"),
        )
        for machine, host_tag in cases:
            with self.subTest(machine=machine), mock.patch.dict(
                BUILD_MICROG_MAIN.os.environ, {}, clear=True
            ), mock.patch.object(
                BUILD_MICROG_MAIN.platform, "machine", return_value=machine
            ):
                self.assertEqual(
                    android_root / "prebuilts" / "jdk" / "jdk21" / host_tag,
                    BUILD_MICROG_MAIN.default_java_home(android_root),
                )

    def test_bootstraps_matching_host_tools_for_x86_64_and_arm64(self):
        cases = (
            ("x86_64", "linux-x86"),
            ("aarch64", "linux-arm64"),
            ("arm64", "linux-arm64"),
        )
        for machine, host_tag in cases:
            with self.subTest(machine=machine), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                android_root, java_home = self.make_aosp_tree(root, host_tag)
                sdk_root = root / "sdk"

                # Model a stale or foreign-architecture SDK entry. Validation
                # must replace it with the host-native AOSP output.
                stale_aapt2 = sdk_root / "build-tools" / "35.0.0" / "aapt2"
                self.write_tool(stale_aapt2, exit_status=23)

                with mock.patch.object(
                    BUILD_MICROG_MAIN.platform, "machine", return_value=machine
                ):
                    BUILD_MICROG_MAIN.validate_toolchain(
                        android_root, java_home, sdk_root, "35", "35.0.0"
                    )

                selected_aapt2 = sdk_root / "build-tools" / "35.0.0" / "aapt2"
                expected_aapt2 = android_root / "out" / "host" / host_tag / "bin" / "aapt2"
                self.assertTrue(selected_aapt2.is_symlink())
                self.assertEqual(expected_aapt2.resolve(), selected_aapt2.resolve())
                self.assertTrue(
                    BUILD_MICROG_MAIN.tool_runs(selected_aapt2, "version")
                )
                for tool in ("aidl", "apksigner", "d8", "zipalign"):
                    self.assertEqual(
                        (android_root / "out" / "host" / host_tag / "bin" / tool).resolve(),
                        (sdk_root / "build-tools" / "35.0.0" / tool).resolve(),
                    )


if __name__ == "__main__":
    unittest.main()
