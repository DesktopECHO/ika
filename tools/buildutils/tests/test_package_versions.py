#!/usr/bin/env python3

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
LIBRARY = ROOT / "lib" / "package_versions.sh"
SAME_VERSION = "1.2.3-4"
OLDER_VERSION = "1.2.2-9"
NEWER_VERSION = "1.2.4-1"
MISSING = "missing"


class PackageVersionsTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.package = self.root / "ika-base.pkg"
        self.package.touch()
        self.lineage_package = self.root / "ika-lineageos.pkg"
        self.lineage_package.touch()
        self._write_fake_tools()

    def tearDown(self):
        self.temp_dir.cleanup()

    def _write_tool(self, name, body):
        path = self.bin_dir / name
        path.write_text("#!/usr/bin/env bash\nset -eu\n" + textwrap.dedent(body))
        path.chmod(0o755)

    def _write_fake_tools(self):
        self._write_tool(
            "rpm",
            r'''
            if [[ "$1" == "-qp" ]]; then
              path="${@: -1}"
              name=ika-base
              [[ "$path" == *ika-lineageos.pkg ]] && name=ika-lineageos
              printf '%s\t0:1.2.3-4\tx86_64\n' "$name"
              exit 0
            fi

            name="${@: -1}"
            case "$name" in
              ika-base) version="$FAKE_BASE_INSTALLED_VERSION" ;;
              ika-lineageos) version="$FAKE_LINEAGE_INSTALLED_VERSION" ;;
              *) exit 1 ;;
            esac
            [[ "$version" != missing ]] || exit 1
            printf '%s\t0:%s\tx86_64\n' "$name" "$version"
            ''',
        )
        self._write_tool(
            "rpmdev-vercmp",
            r'''
            [[ "$1" != "$2" ]] || exit 0
            newest="$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)"
            [[ "$newest" == "$1" ]] && exit 11
            exit 12
            ''',
        )
        self._write_tool(
            "dpkg-deb",
            r'''
            name=ika-base
            [[ "$2" == *ika-lineageos.pkg ]] && name=ika-lineageos
            case "${3:-}" in
              Package) printf '%s\n' "$name" ;;
              Version) printf '1.2.3-4\n' ;;
              Architecture) printf 'amd64\n' ;;
              *) exit 1 ;;
            esac
            ''',
        )
        self._write_tool(
            "dpkg-query",
            r'''
            name="${@: -1}"
            case "$name" in
              ika-base) version="$FAKE_BASE_INSTALLED_VERSION" ;;
              ika-lineageos) version="$FAKE_LINEAGE_INSTALLED_VERSION" ;;
              *) exit 1 ;;
            esac
            [[ "$version" != missing ]] || exit 1
            printf 'ii \t%s\tamd64\n' "$version"
            ''',
        )
        self._write_tool(
            "dpkg",
            r'''
            [[ "$1" == --compare-versions ]]
            local_version="$2"
            operator="$3"
            installed_version="$4"
            case "$operator" in
              eq) [[ "$local_version" == "$installed_version" ]] ;;
              gt)
                [[ "$local_version" != "$installed_version" ]]
                [[ "$(printf '%s\n%s\n' "$local_version" "$installed_version" | sort -V | tail -n 1)" == "$local_version" ]]
                ;;
              lt)
                [[ "$local_version" != "$installed_version" ]]
                [[ "$(printf '%s\n%s\n' "$local_version" "$installed_version" | sort -V | head -n 1)" == "$local_version" ]]
                ;;
              *) exit 2 ;;
            esac
            ''',
        )
        self._write_tool(
            "pacman",
            r'''
            if [[ "$1" == "-Qp" ]]; then
              path="${@: -1}"
              name=ika-base
              [[ "$path" == *ika-lineageos.pkg ]] && name=ika-lineageos
              printf '%s 1.2.3-4\n' "$name"
              exit 0
            fi

            name="${@: -1}"
            case "$name" in
              ika-base) version="$FAKE_BASE_INSTALLED_VERSION" ;;
              ika-lineageos) version="$FAKE_LINEAGE_INSTALLED_VERSION" ;;
              *) exit 1 ;;
            esac
            [[ "$version" != missing ]] || exit 1
            printf '%s %s\n' "$name" "$version"
            ''',
        )
        self._write_tool(
            "vercmp",
            r'''
            if [[ "$1" == "$2" ]]; then
              printf '0\n'
            elif [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]; then
              printf '1\n'
            else
              printf '%s\n' '-1'
            fi
            ''',
        )

    def command_for(
        self,
        family,
        *,
        base_installed=SAME_VERSION,
        lineage_installed=SAME_VERSION,
        packages=None,
    ):
        script = r'''
source "$1"
family="$2"
shift 2
command=""
build_manual_package_install_command "$family" command "$@"
printf '%s\n' "$command"
'''
        if packages is None:
            packages = [self.package, self.lineage_package]
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "FAKE_BASE_INSTALLED_VERSION": base_installed,
                "FAKE_LINEAGE_INSTALLED_VERSION": lineage_installed,
            }
        )
        result = subprocess.run(
            [
                "bash",
                "-c",
                script,
                "bash",
                str(LIBRARY),
                family,
                *(str(package) for package in packages),
            ],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
        return result.stdout.rstrip("\n")

    def expected(self, *words):
        return " ".join(str(word) for word in words)

    def test_exact_versions_use_reinstall_semantics(self):
        self.assertEqual(
            self.expected(
                "sudo", "dnf", "reinstall", self.package, self.lineage_package
            ),
            self.command_for("rpm"),
        )
        self.assertEqual(
            self.expected(
                "sudo",
                "apt",
                "install",
                "--reinstall",
                self.package,
                self.lineage_package,
            ),
            self.command_for("debian"),
        )
        self.assertEqual(
            self.expected("sudo", "pacman", "-U", self.package, self.lineage_package),
            self.command_for("arch"),
        )

    def test_newer_local_versions_use_upgrade_semantics(self):
        self.assertEqual(
            self.expected("sudo", "dnf", "upgrade", self.package, self.lineage_package),
            self.command_for(
                "rpm",
                base_installed=OLDER_VERSION,
                lineage_installed=OLDER_VERSION,
            ),
        )
        self.assertEqual(
            self.expected(
                "sudo",
                "apt",
                "install",
                "--only-upgrade",
                self.package,
                self.lineage_package,
            ),
            self.command_for(
                "debian",
                base_installed=OLDER_VERSION,
                lineage_installed=OLDER_VERSION,
            ),
        )
        self.assertEqual(
            self.expected("sudo", "pacman", "-U", self.package, self.lineage_package),
            self.command_for(
                "arch",
                base_installed=OLDER_VERSION,
                lineage_installed=OLDER_VERSION,
            ),
        )

    def test_missing_packages_use_install_semantics(self):
        self.assertEqual(
            self.expected("sudo", "dnf", "install", self.package, self.lineage_package),
            self.command_for(
                "rpm", base_installed=MISSING, lineage_installed=MISSING
            ),
        )
        self.assertEqual(
            self.expected("sudo", "apt", "install", self.package, self.lineage_package),
            self.command_for(
                "debian", base_installed=MISSING, lineage_installed=MISSING
            ),
        )
        self.assertEqual(
            self.expected("sudo", "pacman", "-U", self.package, self.lineage_package),
            self.command_for(
                "arch", base_installed=MISSING, lineage_installed=MISSING
            ),
        )

    def test_older_local_versions_use_downgrade_semantics(self):
        self.assertEqual(
            self.expected(
                "sudo", "dnf", "downgrade", self.package, self.lineage_package
            ),
            self.command_for(
                "rpm",
                base_installed=NEWER_VERSION,
                lineage_installed=NEWER_VERSION,
            ),
        )
        self.assertEqual(
            self.expected(
                "sudo",
                "apt",
                "install",
                "--allow-downgrades",
                self.package,
                self.lineage_package,
            ),
            self.command_for(
                "debian",
                base_installed=NEWER_VERSION,
                lineage_installed=NEWER_VERSION,
            ),
        )
        self.assertEqual(
            self.expected("sudo", "pacman", "-U", self.package, self.lineage_package),
            self.command_for(
                "arch",
                base_installed=NEWER_VERSION,
                lineage_installed=NEWER_VERSION,
            ),
        )

    def test_mixed_states_stay_on_one_shell_line(self):
        self.assertEqual(
            self.expected("sudo", "dnf", "upgrade", self.package)
            + " && "
            + self.expected("sudo", "dnf", "install", self.lineage_package),
            self.command_for(
                "rpm", base_installed=OLDER_VERSION, lineage_installed=MISSING
            ),
        )
        self.assertEqual(
            self.expected("sudo", "apt", "install", "--only-upgrade", self.package)
            + " && "
            + self.expected("sudo", "apt", "install", self.lineage_package),
            self.command_for(
                "debian", base_installed=OLDER_VERSION, lineage_installed=MISSING
            ),
        )
        self.assertEqual(
            self.expected("sudo", "pacman", "-U", self.package, self.lineage_package),
            self.command_for(
                "arch", base_installed=OLDER_VERSION, lineage_installed=MISSING
            ),
        )

    def test_package_paths_are_shell_escaped(self):
        spaced_dir = self.root / "packages with spaces"
        spaced_dir.mkdir()
        spaced_package = spaced_dir / "ika-base.pkg"
        spaced_package.touch()

        command = self.command_for(
            "rpm",
            base_installed=MISSING,
            packages=[spaced_package],
        )
        self.assertIn(r"packages\ with\ spaces", command)
        subprocess.run(["bash", "-n", "-c", command], check=True)


if __name__ == "__main__":
    unittest.main()
