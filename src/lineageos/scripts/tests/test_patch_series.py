#!/usr/bin/env python3

"""patch_series_already_applied must accept a patch stack whose patches edit
the same lines, and still reject a stack that is not on the tree."""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "scripts" / "lib" / "patch_series.sh"

GIT_ENV = {
    "GIT_AUTHOR_NAME": "t",
    "GIT_AUTHOR_EMAIL": "t@example.com",
    "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@example.com",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_SYSTEM": "/dev/null",
}

BASE = "".join(f"line {n}\n" for n in range(1, 21))


class PatchSeriesAlreadyAppliedTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name) / "root"
        self.project = self.root / "proj"
        self.overlay = Path(self._tmp.name) / "overlay"
        (self.overlay / "patches").mkdir(parents=True)
        self.project.mkdir(parents=True)
        self.git("init", "-q")
        (self.project / "a.txt").write_text(BASE)
        (self.project / "gone.txt").write_text("to be renamed\n")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "base")

    def git(self, *args, cwd=None):
        return subprocess.run(
            ["git", *args],
            cwd=cwd or self.project,
            env={**os.environ, **GIT_ENV},
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).stdout

    def make_patch(self, name, edit):
        """Edits the working tree with `edit`, saves the change as a patch
        in the overlay and keeps it applied."""
        edit()
        self.git("add", "-A")
        diff = self.git("diff", "--cached")
        (self.overlay / "patches" / name).write_text(diff)
        self.git("commit", "-q", "-m", name)
        return f"patches/{name}"

    def edit_lines(self, **changes):
        def edit():
            path = self.project / "a.txt"
            lines = path.read_text().splitlines(keepends=True)
            for number, text in changes.items():
                lines[int(number[1:]) - 1] = text + "\n"
            path.write_text("".join(lines))

        return edit

    def reset_to_base(self):
        self.git("reset", "-q", "--hard", "HEAD~%d" % self.patch_count)

    def check(self, patches):
        script = (
            'source "$1"; patch_series_already_applied "$2" "$3" proj "$4"'
        )
        return subprocess.run(
            [
                "bash",
                "-c",
                script,
                "bash",
                str(LIB),
                str(self.root),
                str(self.overlay),
                "\n".join(patches) + "\n",
            ],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ).returncode

    def stack_of_overlapping_patches(self):
        # The second patch changes line 5, which is within the first patch's
        # context, so the first no longer reverse-applies to the live tree on
        # its own.
        first = self.make_patch("one.patch", self.edit_lines(l4="four edited"))
        second = self.make_patch("two.patch", self.edit_lines(l5="five edited"))
        self.patch_count = 2
        return [first, second]

    def test_overlapping_stack_that_is_applied_passes(self):
        patches = self.stack_of_overlapping_patches()
        # The failure this guards against: reverse-checking the first patch
        # alone against the tree with both applied.
        alone = subprocess.run(
            ["git", "apply", "--check", "--reverse", str(self.overlay / patches[0])],
            cwd=self.project,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertNotEqual(0, alone.returncode, "the patches no longer overlap")
        self.assertEqual(0, self.check(patches))

    def test_stack_is_not_applied_when_the_tree_is_pristine(self):
        patches = self.stack_of_overlapping_patches()
        self.reset_to_base()
        self.assertNotEqual(0, self.check(patches))

    def test_stack_is_not_applied_when_only_the_first_patch_is(self):
        patches = self.stack_of_overlapping_patches()
        self.git("reset", "-q", "--hard", "HEAD~1")
        self.assertNotEqual(0, self.check(patches))

    def test_stack_is_not_applied_when_a_patch_is_missing(self):
        patches = self.stack_of_overlapping_patches()
        self.assertNotEqual(0, self.check(patches + ["patches/absent.patch"]))

    def test_live_tree_is_left_alone(self):
        patches = self.stack_of_overlapping_patches()
        before = (self.project / "a.txt").read_text()
        self.assertEqual(0, self.check(patches))
        self.assertEqual(before, (self.project / "a.txt").read_text())
        self.assertEqual("", self.git("status", "--porcelain"))

    def test_patches_that_create_and_rename_files_pass(self):
        def add_and_rename():
            (self.project / "new.txt").write_text("new file\n")
            self.git("mv", "gone.txt", "renamed.txt")

        first = self.make_patch("files.patch", add_and_rename)
        second = self.make_patch("edit.patch", self.edit_lines(l1="first edited"))
        self.patch_count = 2
        self.assertEqual(0, self.check([first, second]))
        self.reset_to_base()
        self.assertNotEqual(0, self.check([first, second]))

    def test_empty_list_passes_and_source_root_is_refused(self):
        self.assertEqual(0, self.check_empty())
        script = 'source "$1"; patch_series_already_applied "$2" "$3" . "x"'
        result = subprocess.run(
            ["bash", "-c", script, "bash", str(LIB), str(self.root), str(self.overlay)],
            check=False,
        )
        self.assertNotEqual(0, result.returncode)

    def check_empty(self):
        script = 'source "$1"; patch_series_already_applied "$2" "$3" proj ""'
        return subprocess.run(
            ["bash", "-c", script, "bash", str(LIB), str(self.root), str(self.overlay)],
            check=False,
        ).returncode


if __name__ == "__main__":
    unittest.main()
