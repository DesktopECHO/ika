#!/usr/bin/env python3

import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "update_native_bridge_prebuilts.py"
SPEC = importlib.util.spec_from_file_location("update_native_bridge_prebuilts", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def write_host_elf(path, machine=MODULE.EM_X86_64, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    header = bytearray(20)
    header[:4] = MODULE.ELF_MAGIC
    header[4] = MODULE.ELFCLASS64
    header[5] = MODULE.ELFDATA2LSB
    struct.pack_into("<H", header, 18, machine)
    path.write_bytes(header)
    path.chmod(0o755 if executable else 0o644)


class UpdateNativeBridgePrebuiltsTest(unittest.TestCase):
    def make_source(self, root, cpuinfo_relpath="etc/berberis/cpuinfo.arm64.txt"):
        system = root / "system"
        for relpath in MODULE.PAYLOAD_REQUIRED_FILES:
            path = system / relpath
            if relpath.startswith(("bin/", "lib64/")):
                write_host_elf(path, executable=relpath.startswith("bin/"))
                if relpath == "lib64/libndk_translation.so":
                    with path.open("ab") as stream:
                        stream.write(f"/system/{cpuinfo_relpath}\0".encode())
            else:
                path.parent.mkdir(parents=True, exist_ok=True)

        for library in MODULE.PAYLOAD_REQUIRED_PROXY_LIBRARIES:
            write_host_elf(system / f"lib64/libndk_translation_proxy_{library}.so")

        (system / "etc/binfmt_misc/arm64_dyn").write_text(
            r":arm64_dyn:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\xb7::/system/bin/ndk_translation_program_runner_binfmt_misc_arm64:P\n"
        )
        (system / "etc/binfmt_misc/arm64_exe").write_text(
            r":arm64_exe:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7::/system/bin/ndk_translation_program_runner_binfmt_misc_arm64:P\n"
        )
        (system / "etc/init/ndk_translation.rc").write_text(
            "on property:ro.dalvik.vm.native.bridge=libndk_translation.so "
            "&& property:ro.dalvik.vm.isa.arm64=x86_64\n"
            "    copy /system/etc/binfmt_misc/arm64_exe /proc/sys/fs/binfmt_misc/register\n"
            "    copy /system/etc/binfmt_misc/arm64_dyn /proc/sys/fs/binfmt_misc/register\n"
        )
        (system / "etc/ld.config.arm64.txt").write_text(
            "dir.system=/system\ndir.system=/data\n"
            "namespace.default.search.paths=/system/${LIB}/arm64\n"
        )
        cpuinfo = system / cpuinfo_relpath
        cpuinfo.parent.mkdir(parents=True, exist_ok=True)
        cpuinfo.write_text(
            "processor : 0\nFeatures : fp asimd aes pmull crc32 atomics\n"
        )
        return system

    def test_stage_payload_validates_and_copies_complete_x86_runtime(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = self.make_source(root / "source")
            output = root / "output"

            copied = MODULE.stage_payload(source, output)

            self.assertIn("lib64/libndk_translation.so", copied)
            self.assertIn("lib64/libndk_translation_proxy_libvulkan.so", copied)
            for relpath in MODULE.CPU_INFO_RELPATHS:
                self.assertIn(relpath, copied)
                self.assertTrue((output / relpath).is_file())
            self.assertEqual(
                MODULE.EM_X86_64,
                MODULE.elf_machine(output / "lib64/libndk_translation.so"),
            )

    def test_copy_file_refreshes_timestamp_for_android_incremental_builds(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "source"
            destination = root / "destination"
            source.write_bytes(b"new payload")
            os.utime(source, ns=(1_000_000_000, 1_000_000_000))

            MODULE.copy_file(source, destination)

            self.assertEqual(source.read_bytes(), destination.read_bytes())
            self.assertGreater(destination.stat().st_mtime_ns, source.stat().st_mtime_ns)

    def test_stage_payload_accepts_current_cpuinfo_location_and_init_trigger(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = self.make_source(
                root / "source", cpuinfo_relpath="etc/cpuinfo.arm64.txt"
            )
            (source / "etc/init/ndk_translation.rc").write_text(
                "on property:ro.enable.native.bridge.exec=1 "
                "&& property:ro.dalvik.vm.isa.arm64=x86_64\n"
                "    copy /system/etc/binfmt_misc/arm64_exe /proc/sys/fs/binfmt_misc/register\n"
                "    copy /system/etc/binfmt_misc/arm64_dyn /proc/sys/fs/binfmt_misc/register\n"
            )

            copied = MODULE.stage_payload(source, root / "output")

            self.assertIn("etc/cpuinfo.arm64.txt", copied)
            self.assertIn("etc/berberis/cpuinfo.arm64.txt", copied)

    def test_stage_payload_rejects_wrong_host_architecture(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = self.make_source(root / "source")
            write_host_elf(source / "lib64/libndk_translation.so", machine=183)

            with self.assertRaisesRegex(MODULE.UpdateError, "not x86-64 ELF"):
                MODULE.stage_payload(source, root / "output")

    def test_manifest_records_format_source_size_and_digest(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            payload = root / "system/lib64/libndk_translation.so"
            write_host_elf(payload)

            MODULE.write_manifest(
                root,
                {"sdk_package": "https://example.invalid/pinned.zip"},
                ["lib64/libndk_translation.so"],
            )
            manifest = json.loads((root / "manifest.json").read_text())

            self.assertEqual(1, manifest["format_version"])
            self.assertEqual(
                "https://example.invalid/pinned.zip",
                manifest["source"]["sdk_package"],
            )
            self.assertEqual(payload.stat().st_size, manifest["files"][0]["size"])
            self.assertEqual(64, len(manifest["files"][0]["sha256"]))

    def test_install_uses_prebuilt_libm_proxy_when_payload_provides_it(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = self.make_source(root / "source")
            write_host_elf(
                source / "lib64/libndk_translation_proxy_libm.so"
            )
            output = root / "prebuilts/system"

            MODULE.install_payload(source, output, {"source_dir": str(source)})

            android_bp = (output.parent / "Android.bp").read_text()
            self.assertNotIn('name: "libndk_translation_proxy_libm"', android_bp)
            self.assertTrue(
                (output / "lib64/libndk_translation_proxy_libm.so").is_file()
            )

    def test_install_builds_libm_proxy_fallback_when_payload_omits_it(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = self.make_source(root / "source")
            output = root / "prebuilts/system"

            MODULE.install_payload(source, output, {"source_dir": str(source)})

            android_bp = (output.parent / "Android.bp").read_text()
            self.assertIn('name: "libndk_translation_proxy_libm"', android_bp)


if __name__ == "__main__":
    unittest.main()
