#!/usr/bin/env python3

import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "update_microg_prebuilts.py"
SPEC = importlib.util.spec_from_file_location("update_microg_prebuilts", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class UpdateMicrogPrebuiltsTest(unittest.TestCase):
    def test_gmscore_defaults_to_newest_published_release(self):
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(
            sys, "argv", [str(SCRIPT)]
        ):
            args = MODULE.parse_args()

        self.assertEqual("latest", args.gmscore_release)

    def test_newest_published_release_includes_prereleases(self):
        older_stable = {
            "tag_name": "v1.2.3",
            "draft": False,
            "prerelease": False,
            "published_at": "2026-07-01T00:00:00Z",
        }
        newer_prerelease = {
            "tag_name": "v1.3.0-rc1",
            "draft": False,
            "prerelease": True,
            "published_at": "2026-07-14T00:00:00Z",
        }
        draft = {
            "tag_name": "v2.0.0",
            "draft": True,
            "prerelease": False,
            "published_at": "2026-07-15T00:00:00Z",
        }

        with mock.patch.object(
            MODULE, "read_json", return_value=[older_stable, draft, newer_prerelease]
        ) as read_json:
            release = MODULE.release_for(MODULE.GMSCORE_REPO, "latest")

        self.assertIs(newer_prerelease, release)
        read_json.assert_called_once_with(
            f"{MODULE.GITHUB_API}/{MODULE.GMSCORE_REPO}/releases?per_page=100"
        )

    def test_main_selector_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            android_root = Path(temp_dir)
            (android_root / "vendor" / "partner_gms").mkdir(parents=True)

            with self.assertRaisesRegex(MODULE.UpdateError, "main is not a release"):
                MODULE.update_microg(
                    android_root,
                    "main",
                    "latest",
                    "latest",
                    "latest",
                    False,
                    android_root / "cache",
                )


if __name__ == "__main__":
    unittest.main()
