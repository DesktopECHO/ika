#!/usr/bin/env python3

import argparse
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "write_release_metadata.py"
SPEC = importlib.util.spec_from_file_location("write_release_metadata", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class WriteReleaseMetadataTest(unittest.TestCase):
    def test_source_commit_is_pinned_when_repository_head_moves(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            ika_root = root / "ika"
            android_root = root / "android"
            overlay_dir = android_root / "vendor/lineage_desktop"
            product_out = android_root / "out/target/product/ika_x86_64"
            bundle_dir = root / "bundle"
            for path in (ika_root, overlay_dir, product_out, bundle_dir):
                path.mkdir(parents=True, exist_ok=True)

            subprocess.run(["git", "init", "-q"], cwd=ika_root, check=True)
            subprocess.run(
                ["git", "config", "user.email", "tests@example.invalid"],
                cwd=ika_root,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "Ika Tests"],
                cwd=ika_root,
                check=True,
            )
            marker = ika_root / "marker"
            marker.write_text("first\n", encoding="utf-8")
            subprocess.run(["git", "add", "marker"], cwd=ika_root, check=True)
            subprocess.run(["git", "commit", "-qm", "first"], cwd=ika_root, check=True)
            build_commit = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=ika_root, text=True
            ).strip()

            marker.write_text("second\n", encoding="utf-8")
            subprocess.run(["git", "commit", "-qam", "second"], cwd=ika_root, check=True)
            current_commit = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=ika_root, text=True
            ).strip()

            args = argparse.Namespace(
                ika_root=str(ika_root),
                android_root=str(android_root),
                overlay_dir=str(overlay_dir),
                product_out=str(product_out),
                bundle_dir=str(bundle_dir),
                arch="arm64",
                product="ika_arm64",
                lineage_branch="lineage-23.2",
                image=[],
            )
            with mock.patch.dict(os.environ, {"IKA_SOURCE_COMMIT": build_commit}), mock.patch.object(
                MODULE,
                "write_source_manifest",
                return_value={"path": None, "reason": "test"},
            ):
                metadata = MODULE.build_metadata(args)

            self.assertEqual(metadata["ika"]["source_commit"], build_commit)
            self.assertEqual(metadata["ika"]["commit"], current_commit)
            self.assertEqual(
                metadata["build_options"]["build_native_bridge_tests"], "0"
            )

    def test_x86_64_records_digitalis_by_default(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            android_root = root / "android"
            overlay_dir = android_root / "vendor/lineage_desktop"
            translation = android_root / "frameworks/libs/binary_translation"
            registry = overlay_dir / "prebuilts/vulkan_registry_android16/vk.xml"
            product_out = android_root / "out/target/product/ika_x86_64"
            bundle_dir = root / "bundle"
            for path in (root / "ika", registry.parent, translation, product_out, bundle_dir):
                path.mkdir(parents=True, exist_ok=True)
            registry.write_text("<registry/>\n", encoding="utf-8")
            subprocess.run(["git", "init", "-q"], cwd=translation, check=True)
            subprocess.run(
                ["git", "-c", "user.email=tests@example.invalid", "-c", "user.name=Ika Tests",
                 "commit", "-q", "--allow-empty", "-m", "digitalis"],
                cwd=translation,
                check=True,
            )
            commit = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=translation, text=True
            ).strip()

            args = argparse.Namespace(
                ika_root=str(root / "ika"),
                android_root=str(android_root),
                overlay_dir=str(overlay_dir),
                product_out=str(product_out),
                bundle_dir=str(bundle_dir),
                arch="x86_64",
                product="lineage_desktop_cf_x86_64",
                lineage_branch="lineage-23.2",
                image=[],
            )
            env = {k: v for k, v in os.environ.items() if k != "X86_ARM_TRANSLATOR"}
            with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(
                MODULE,
                "write_source_manifest",
                return_value={"path": None, "reason": "test"},
            ):
                metadata = MODULE.build_metadata(args)

            self.assertEqual(metadata["build_options"]["x86_arm_translator"], "digitalis")
            bridge = metadata["native_bridge"]
            self.assertEqual(bridge["translator"], "digitalis")
            self.assertEqual(bridge["native_bridge"], "libberberis_arm64.so")
            self.assertEqual(bridge["source"]["commit"], commit)
            self.assertTrue(bridge["vulkan_registry"]["present"])

            summary = bundle_dir / "build-info.txt"
            MODULE.write_text_summary(metadata, summary)
            self.assertIn(f"ARM translator: digitalis {commit}", summary.read_text())


if __name__ == "__main__":
    unittest.main()
