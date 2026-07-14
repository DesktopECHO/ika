#!/usr/bin/env python3
#
# Copyright (C) 2026 LineageOS Desktop Project
# SPDX-License-Identifier: Apache-2.0

"""Build and platform-sign GmsCore from upstream microG main."""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile


UPSTREAM_URL = "https://github.com/microg/GmsCore.git"
UPSTREAM_BRANCH = "master"
UPSTREAM_BUILD_FILE = Path("build.gradle")
SETTINGS_MANIFEST = Path("play-services-base/core/src/main/AndroidManifest.xml")
SETTINGS_SIGNATURE_LEVEL = 'android:protectionLevel="signature"'
SETTINGS_PRIVILEGED_LEVEL = 'android:protectionLevel="signature|privileged"'


class BuildError(Exception):
    pass


def log(message):
    print(f"[lineage-desktop] {message}", file=sys.stderr)


def run(command, *, cwd=None, env=None, capture=False):
    log("running: " + " ".join(str(value) for value in command))
    completed = subprocess.run(
        [str(value) for value in command],
        cwd=cwd,
        env=env,
        check=True,
        text=True,
        stdout=subprocess.PIPE if capture else sys.stderr,
    )
    return completed.stdout if capture else None


def set_privileged_settings_permissions(source_dir, enabled):
    """Let the official-signed privileged FakeStore read GmsCore settings."""
    manifest = source_dir / SETTINGS_MANIFEST
    text = manifest.read_text()
    source = SETTINGS_SIGNATURE_LEVEL if enabled else SETTINGS_PRIVILEGED_LEVEL
    target = SETTINGS_PRIVILEGED_LEVEL if enabled else SETTINGS_SIGNATURE_LEVEL
    source_count = text.count(source)
    target_count = text.count(target)

    if source_count == 0 and target_count == 2:
        return
    if source_count != 2 or target_count != 0:
        raise BuildError(
            f"unexpected settings permission declarations in {manifest}: "
            f"source={source_count}, target={target_count}"
        )
    manifest.write_text(text.replace(source, target))


def ensure_checkout(source_dir):
    git_dir = source_dir / ".git"
    if not git_dir.is_dir():
        source_dir.parent.mkdir(parents=True, exist_ok=True)
        run([
            "git", "clone", "--branch", UPSTREAM_BRANCH, "--single-branch",
            UPSTREAM_URL, source_dir,
        ])
    else:
        # Recover the one script-managed edit if a previous build was killed
        # before its finally block restored the cached upstream checkout.
        set_privileged_settings_permissions(source_dir, False)
        origin = run(
            ["git", "config", "--get", "remote.origin.url"], cwd=source_dir, capture=True
        ).strip()
        if origin.rstrip("/").removesuffix(".git") != UPSTREAM_URL.rstrip("/").removesuffix(".git"):
            raise BuildError(f"unexpected GmsCore origin in {source_dir}: {origin}")
        if run(["git", "status", "--porcelain"], cwd=source_dir, capture=True).strip():
            raise BuildError(f"GmsCore source checkout has local changes: {source_dir}")

    run(["git", "fetch", "--prune", "origin", UPSTREAM_BRANCH], cwd=source_dir)
    run([
        "git", "checkout", "-B", UPSTREAM_BRANCH, f"origin/{UPSTREAM_BRANCH}"
    ], cwd=source_dir)
    return run(["git", "rev-parse", "HEAD"], cwd=source_dir, capture=True).strip()


def default_java_home(android_root):
    configured = os.environ.get("MICROG_JAVA_HOME") or os.environ.get("JAVA_HOME")
    if configured:
        return Path(configured).expanduser().resolve()
    if platform.machine().lower() in ("aarch64", "arm64"):
        return android_root / "prebuilts" / "jdk" / "jdk21" / "linux-arm64"
    return android_root / "prebuilts" / "jdk" / "jdk21" / "linux-x86"


def default_sdk_root():
    configured = os.environ.get("MICROG_ANDROID_SDK_ROOT")
    if not configured:
        configured = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME")
    if configured:
        return Path(configured).expanduser().resolve()
    return Path.home() / "ika-build" / "android-sdk"


@contextmanager
def temporary_sdk_location(source_dir, sdk_root):
    """Make Gradle use the selected SDK without altering the cached checkout."""
    local_properties = source_dir / "local.properties"
    previous = local_properties.read_bytes() if local_properties.exists() else None
    local_properties.write_text(f"sdk.dir={sdk_root}\n")
    try:
        yield
    finally:
        if previous is None:
            local_properties.unlink(missing_ok=True)
        else:
            local_properties.write_bytes(previous)


def read_android_tool_versions(source_dir):
    """Read the SDK versions declared by the checked-out upstream build."""
    build_file = source_dir / UPSTREAM_BUILD_FILE
    try:
        text = build_file.read_text()
    except OSError as exc:
        raise BuildError(f"cannot read upstream build configuration {build_file}: {exc}") from exc

    build_tools_match = re.search(
        r"ext\.androidBuildVersionTools\s*=\s*['\"]([^'\"]+)['\"]", text
    )
    compile_sdk_match = re.search(r"ext\.androidCompileSdk\s*=\s*([0-9]+)", text)
    if not build_tools_match or not compile_sdk_match:
        raise BuildError(
            f"cannot determine Android SDK versions from upstream {build_file}"
        )

    build_tools_version = build_tools_match.group(1)
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){2}", build_tools_version):
        raise BuildError(
            f"unexpected Android build-tools version in {build_file}: "
            f"{build_tools_version}"
        )
    return compile_sdk_match.group(1), build_tools_version


def replace_symlink(path, target):
    """Point a private SDK-cache path at an AOSP build artifact."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() and path.resolve() == target.resolve():
        return
    if path.exists() or path.is_symlink():
        if path.is_dir() and not path.is_symlink():
            raise BuildError(f"cannot replace SDK directory with a file: {path}")
        path.unlink()
    path.symlink_to(target.resolve())


def write_if_missing(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.write_text(content)


def bootstrap_sdk_from_aosp(android_root, sdk_root, compile_sdk, build_tools_version):
    """Create the small host-native SDK view Gradle needs from the AOSP build.

    Google's downloadable Linux SDK build-tools are x86-64 binaries.  Native
    ARM64 Ika builds already produce the equivalent host tools, so reuse them
    instead of requiring an incompatible SDK download.
    """
    platform_dir = sdk_root / "platforms" / f"android-{compile_sdk}"
    public_sdk = android_root / "prebuilts" / "sdk" / compile_sdk / "public"
    build_tools = sdk_root / "build-tools" / build_tools_version
    platform_tools = sdk_root / "platform-tools"
    host_tag = "linux-arm64" if platform.machine().lower() in ("aarch64", "arm64") else "linux-x86"
    host_out = android_root / "out" / "host" / host_tag
    core_lambda = android_root / "prebuilts" / "sdk" / "tools" / "core-lambda-stubs.jar"

    required_sources = (
        public_sdk / "android.jar",
        public_sdk / "core-for-system-modules.jar",
        public_sdk / "framework.aidl",
        public_sdk / "data" / "api-versions.xml",
        core_lambda,
        host_out / "bin" / "aapt2",
        host_out / "bin" / "aidl",
        host_out / "bin" / "apksigner",
        host_out / "bin" / "d8",
        host_out / "bin" / "zipalign",
        host_out / "bin" / "adb",
    )
    missing = [str(path) for path in required_sources if not path.exists()]
    if missing:
        raise BuildError(
            "missing native AOSP GmsCore build dependency: " + ", ".join(missing)
        )

    for name in ("android.jar", "core-for-system-modules.jar", "framework.aidl"):
        replace_symlink(platform_dir / name, public_sdk / name)
    # A downloaded SDK has a real data directory; a minimal script-managed SDK
    # can point directly at the matching checked-in AOSP data instead.
    platform_data = platform_dir / "data"
    if not platform_data.exists():
        replace_symlink(platform_data, public_sdk / "data")
    write_if_missing(
        platform_dir / "source.properties",
        f"Pkg.Desc=Android SDK Platform {compile_sdk}\n"
        f"Pkg.Revision=1\nAndroidVersion.ApiLevel={compile_sdk}\n",
    )
    write_if_missing(
        platform_dir / "build.prop", f"ro.build.version.sdk={compile_sdk}\n"
    )

    # AGP 8 uses aapt2 for resources and its bundled D8 for dexing.  Populate
    # the other standard entries when AOSP has produced them so BuildToolInfo
    # also remains useful to Gradle plugins that inspect the selected version.
    for name in ("aapt2", "aidl", "apksigner", "d8", "zipalign"):
        source = host_out / "bin" / name
        if source.exists():
            replace_symlink(build_tools / name, source)
    # BuildToolInfo still requires the legacy AAPT slot even though AGP 8 uses
    # the aapt2 override above for every resource task.
    replace_symlink(build_tools / "aapt", host_out / "bin" / "aapt2")
    # DEXDUMP is another legacy presence check in BuildToolInfo; GmsCore does
    # not invoke it (AGP carries its own D8/R8 implementation).
    replace_symlink(build_tools / "dexdump", host_out / "bin" / "d8")
    # Split APK selection is likewise not used by this single universal APK.
    replace_symlink(build_tools / "split-select", host_out / "bin" / "aapt2")
    replace_symlink(build_tools / "core-lambda-stubs.jar", core_lambda)
    build_tools_major = build_tools_version.split(".", 1)[0]
    write_if_missing(
        build_tools / "source.properties",
        f"Pkg.Desc=Android SDK Build-Tools {build_tools_major}\n"
        f"Pkg.Revision={build_tools_version}\n",
    )
    for name in ("adb", "fastboot"):
        source = host_out / "bin" / name
        if source.exists():
            replace_symlink(platform_tools / name, source)
    write_if_missing(
        platform_tools / "source.properties",
        "Pkg.Desc=Android SDK Platform-Tools\nPkg.Revision=35.0.2\n",
    )
    log(f"using native AOSP SDK tools from {host_out}")


def tool_runs(path, *args):
    if not path.is_file() or not os.access(path, os.X_OK):
        return False
    try:
        completed = subprocess.run(
            [str(path), *args],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return completed.returncode == 0


def sdk_required_paths(sdk_root, compile_sdk, build_tools_version):
    platform_dir = sdk_root / "platforms" / f"android-{compile_sdk}"
    build_tools = sdk_root / "build-tools" / build_tools_version
    return (
        platform_dir / "android.jar",
        platform_dir / "core-for-system-modules.jar",
        platform_dir / "data" / "api-versions.xml",
        build_tools / "aapt",
        build_tools / "aapt2",
        build_tools / "aidl",
        build_tools / "apksigner",
        build_tools / "core-lambda-stubs.jar",
        build_tools / "dexdump",
        build_tools / "split-select",
        build_tools / "zipalign",
        sdk_root / "platform-tools" / "adb",
    )


def validate_toolchain(
    android_root, java_home, sdk_root, compile_sdk, build_tools_version
):
    sdk_required = sdk_required_paths(sdk_root, compile_sdk, build_tools_version)
    aapt2 = sdk_root / "build-tools" / build_tools_version / "aapt2"
    if any(not path.exists() for path in sdk_required) or not tool_runs(
        aapt2, "version"
    ):
        bootstrap_sdk_from_aosp(
            android_root, sdk_root, compile_sdk, build_tools_version
        )

    required = (
        java_home / "bin" / "java",
        *sdk_required,
        android_root / "build" / "make" / "target" / "product" / "security" / "platform.pk8",
        android_root / "build" / "make" / "target" / "product" / "security" / "platform.x509.pem",
    )
    missing = [str(path) for path in required if not path.exists()]
    if not tool_runs(aapt2, "version"):
        missing.append(f"{aapt2} (not runnable on this host)")
    if missing:
        raise BuildError("missing GmsCore build dependency: " + ", ".join(missing))


def read_built_apk(source_dir):
    output_dir = (
        source_dir / "play-services-core" / "build" / "outputs" / "apk"
        / "mapboxDefault" / "release"
    )
    metadata_path = output_dir / "output-metadata.json"
    try:
        metadata = json.loads(metadata_path.read_text())
        element = metadata["elements"][0]
        apk = output_dir / element["outputFile"]
        version_code = str(element["versionCode"])
    except (OSError, KeyError, IndexError, TypeError, ValueError) as exc:
        raise BuildError(f"invalid GmsCore build metadata {metadata_path}: {exc}") from exc
    if not apk.is_file():
        raise BuildError(f"GmsCore build did not produce {apk}")
    return apk, version_code


def sign_apk(
    android_root, sdk_root, java_home, build_tools_version, unsigned_apk, output_apk
):
    apksigner = sdk_root / "build-tools" / build_tools_version / "apksigner"
    key_dir = android_root / "build" / "make" / "target" / "product" / "security"
    env = os.environ.copy()
    env["JAVA_HOME"] = str(java_home)
    env["PATH"] = str(java_home / "bin") + os.pathsep + env.get("PATH", "")
    output_apk.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=output_apk.name + ".", dir=output_apk.parent)
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        run([
            apksigner, "sign", "--key", key_dir / "platform.pk8", "--cert",
            key_dir / "platform.x509.pem", "--out", tmp, unsigned_apk,
        ], env=env)
        log(f"verifying APK signature: {tmp}")
        verification = subprocess.run(
            [str(apksigner), "verify", "--verbose", str(tmp)],
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        if verification.returncode:
            raise BuildError(
                "GmsCore APK signature verification failed:\n" + verification.stdout
            )
        tmp.chmod(0o644)
        os.replace(tmp, output_apk)
    finally:
        tmp.unlink(missing_ok=True)


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("android_root", nargs="?", default=".")
    parser.add_argument(
        "--source-dir",
        default=os.environ.get("MICROG_GMSCORE_SOURCE_DIR", "~/ika-build/microg-main/GmsCore"),
    )
    parser.add_argument("--output-dir", required=True)
    return parser.parse_args()


def main():
    args = parse_args()
    android_root = Path(args.android_root).resolve()
    source_dir = Path(args.source_dir).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    java_home = default_java_home(android_root)
    sdk_root = default_sdk_root()

    try:
        commit = ensure_checkout(source_dir)
        compile_sdk, build_tools_version = read_android_tool_versions(source_dir)
        log(
            f"upstream GmsCore requires Android platform {compile_sdk} "
            f"and build-tools {build_tools_version}"
        )
        validate_toolchain(
            android_root, java_home, sdk_root, compile_sdk, build_tools_version
        )
        env = os.environ.copy()
        env.update({
            "JAVA_HOME": str(java_home),
            "ANDROID_HOME": str(sdk_root),
            "ANDROID_SDK_ROOT": str(sdk_root),
        })
        set_privileged_settings_permissions(source_dir, True)
        try:
            with temporary_sdk_location(source_dir, sdk_root):
                run(
                    [
                        source_dir / "gradlew", "--no-daemon",
                        "--no-configuration-cache",
                        f"-Pandroid.aapt2FromMavenOverride={sdk_root / 'build-tools' / build_tools_version / 'aapt2'}",
                        ":play-services-core:assembleMapboxDefaultRelease",
                    ],
                    cwd=source_dir,
                    env=env,
                )
        finally:
            set_privileged_settings_permissions(source_dir, False)
        unsigned_apk, version_code = read_built_apk(source_dir)
        output_apk = output_dir / f"GmsCore-main-{commit}-{version_code}.apk"
        sign_apk(
            android_root,
            sdk_root,
            java_home,
            build_tools_version,
            unsigned_apk,
            output_apk,
        )
        print(json.dumps({
            "apk": str(output_apk),
            "branch": UPSTREAM_BRANCH,
            "build_tools_version": build_tools_version,
            "commit": commit,
            "compile_sdk": compile_sdk,
            "version_code": version_code,
        }))
        return 0
    except (BuildError, OSError, subprocess.CalledProcessError) as exc:
        print(f"[lineage-desktop] error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
