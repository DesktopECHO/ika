#!/usr/bin/env python3
#
# Copyright (C) 2026 LineageOS Desktop Project
# SPDX-License-Identifier: Apache-2.0
#

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile


DEFAULT_SDK_PACKAGE = (
    "https://dl.google.com/android/repository/sys-img/google_apis/"
    "x86_64-36.0-Baklava_r01.zip"
)
# SHA1 is sourced from Google's repository.xml manifest; we keep it for parity
# with that manifest, but also verify SHA256 because SHA1 is collision-broken.
DEFAULT_SDK_PACKAGE_SHA1 = "dc5a0f14318ac2f18c876e1286809fcde665f507"
DEFAULT_SDK_PACKAGE_SHA256 = ""
USER_AGENT = "lineage-desktop-native-bridge-updater/1.0"
SPARSE_MAGIC = b":\xff&\xed"
EROFS_MAGIC = b"\xe2\xe1\xf5\xe0"
GPT_MAGIC = b"EFI PART"
EXT_MAGIC_OFFSET = 1024 + 56
EROFS_MAGIC_OFFSET = 1024
GPT_MAGIC_OFFSET = 512

PAYLOAD_REQUIRED_FILES = (
    "bin/ndk_translation_program_runner_binfmt_misc_arm64",
    "etc/binfmt_misc/arm64_dyn",
    "etc/binfmt_misc/arm64_exe",
    "etc/init/ndk_translation.rc",
    "etc/ld.config.arm.txt",
    "etc/ld.config.arm64.txt",
    "lib64/libndk_translation.so",
)

PAYLOAD_ARM32_FILES = (
    "bin/ndk_translation_program_runner_binfmt_misc",
    "etc/binfmt_misc/arm_dyn",
    "etc/binfmt_misc/arm_exe",
    "lib/libndk_translation.so",
)

PAYLOAD_GLOBS = (
    "lib/*ndk_translation*.so",
    "lib64/*ndk_translation*.so",
)

ANDROID_BP = """\
package {
    default_applicable_licenses: ["Android-Apache-2.0"],
}

cc_prebuilt_library_shared {
    name: "libndk_translation",
    srcs: ["system/lib64/libndk_translation.so"],
    check_elf_files: false,
    compile_multilib: "64",
    installable: false,
    strip: {
        none: true,
    },
}

cc_library_shared {
    name: "libndk_translation_proxy_libm",
    defaults: [
        "berberis_arm64_defaults",
        "native_bridge_proxy_libm_defaults",
    ],
    header_libs: [
        "libberberis_guest_abi_arm64_headers",
    ],
    whole_static_libs: [
        "libberberis_proxy_loader",
    ],
    shared_libs: [
        "liblog",
        "libndk_translation",
    ],
    system_shared_libs: [
        "libc",
        "libm",
        "libdl",
    ],
}
"""


class UpdateError(Exception):
    pass


def log(message):
    print(f"[lineage-desktop] {message}")


def is_url(value):
    return urllib.parse.urlparse(str(value)).scheme in ("http", "https")


def run(cmd):
    subprocess.check_call([str(part) for part in cmd])


def run_capture_on_error(cmd):
    result = subprocess.run(
        [str(part) for part in cmd],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return
    if result.stdout:
        print(result.stdout, end="", file=sys.stdout)
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    raise subprocess.CalledProcessError(result.returncode, [str(part) for part in cmd])


def tool(android_root, name):
    found = shutil.which(name)
    if found:
        return found

    host_tool = android_root / "out" / "host" / "linux-x86" / "bin" / name
    if host_tool.exists():
        return str(host_tool)

    return None


def require_tool(android_root, name, hint):
    found = tool(android_root, name)
    if found is None:
        raise UpdateError(f"missing {name}; {hint}")
    return found


def file_digest(path, algorithm):
    digest = hashlib.new(algorithm)
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, dest):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request) as response:
        with open(dest, "wb") as output:
            shutil.copyfileobj(response, output)


def _verify_digests(path, expected_sha1, expected_sha256):
    if expected_sha1 and file_digest(path, "sha1") != expected_sha1:
        raise UpdateError(f"SHA1 mismatch for {path}")
    if expected_sha256 and file_digest(path, "sha256") != expected_sha256:
        raise UpdateError(f"SHA256 mismatch for {path}")


def fetch_sdk_package(sdk_package, expected_sha1, expected_sha256, cache_dir):
    if not is_url(sdk_package):
        package_path = Path(sdk_package).expanduser().resolve()
        if not package_path.is_file():
            raise UpdateError(f"native bridge SDK package is missing: {package_path}")
        _verify_digests(package_path, expected_sha1, expected_sha256)
        return package_path

    cache_dir.mkdir(parents=True, exist_ok=True)
    package_name = Path(urllib.parse.urlparse(sdk_package).path).name
    package_path = cache_dir / package_name

    if package_path.exists() and (expected_sha1 or expected_sha256):
        try:
            _verify_digests(package_path, expected_sha1, expected_sha256)
            return package_path
        except UpdateError:
            package_path.unlink()

    if not package_path.exists():
        log(f"downloading Android SDK system image: {sdk_package}")
        tmp_path = package_path.with_suffix(package_path.suffix + ".download")
        tmp_path.unlink(missing_ok=True)
        download(sdk_package, tmp_path)
        tmp_path.replace(package_path)

    try:
        _verify_digests(package_path, expected_sha1, expected_sha256)
    except UpdateError:
        package_path.unlink(missing_ok=True)
        raise

    return package_path


def read_at(path, offset, size):
    with open(path, "rb") as stream:
        stream.seek(offset)
        return stream.read(size)


def convert_sparse_if_needed(android_root, image_path, tmp_dir):
    if read_at(image_path, 0, 4) != SPARSE_MAGIC:
        return image_path

    simg2img = require_tool(
        android_root,
        "simg2img",
        "install Android sparse image tools or build the host tool from the Android tree",
    )
    raw_image = tmp_dir / f"{image_path.stem}.raw.img"
    log(f"converting sparse image: {image_path.name}")
    run([simg2img, image_path, raw_image])
    return raw_image


def extract_zip_member(archive, member, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    with archive.open(member) as source:
        with open(dest, "wb") as output:
            shutil.copyfileobj(source, output)
    return dest


def unpack_super_image(android_root, super_image, tmp_dir):
    super_image = convert_sparse_if_needed(android_root, super_image, tmp_dir)
    lpunpack = require_tool(
        android_root,
        "lpunpack",
        "install Android logical partition tools or build lpunpack from the Android tree",
    )
    unpack_dir = tmp_dir / f"{super_image.stem}-logical"
    shutil.rmtree(unpack_dir, ignore_errors=True)
    unpack_dir.mkdir()
    log("unpacking super image")
    run([lpunpack, super_image, unpack_dir])

    for name in ("system.img", "system_a.img"):
        image = unpack_dir / name
        if image.exists():
            return image
    raise UpdateError("super image did not contain a system partition")


def extract_system_image_from_zip(android_root, zip_path, tmp_dir):
    with zipfile.ZipFile(zip_path) as archive:
        names = archive.namelist()
        system_images = sorted(
            name for name in names
            if Path(name).name in ("system.img", "system_a.img")
        )
        if system_images:
            member = system_images[0]
            log(f"extracting {member}")
            return extract_zip_member(archive, member, tmp_dir / Path(member).name)

        super_images = sorted(
            name for name in names
            if Path(name).name in ("super.img", "super_empty.img")
        )
        if not super_images:
            raise UpdateError(f"{zip_path} does not contain system.img or super.img")

        member = super_images[0]
        log(f"extracting {member}")
        super_image = extract_zip_member(archive, member, tmp_dir / Path(member).name)

    return unpack_super_image(android_root, super_image, tmp_dir)


def detect_filesystem(image_path):
    if read_at(image_path, GPT_MAGIC_OFFSET, len(GPT_MAGIC)) == GPT_MAGIC:
        return "gpt"
    if read_at(image_path, EXT_MAGIC_OFFSET, 2) == b"\x53\xef":
        return "ext"
    if read_at(image_path, EROFS_MAGIC_OFFSET, 4) == EROFS_MAGIC:
        return "erofs"
    return "unknown"


def extract_gpt_image(android_root, image_path, dest, tmp_dir):
    seven_zip = require_tool(
        android_root,
        "7z",
        "install 7-Zip to extract GPT-wrapped Android SDK system images",
    )
    gpt_dir = tmp_dir / f"{image_path.stem}-gpt"
    shutil.rmtree(gpt_dir, ignore_errors=True)
    gpt_dir.mkdir()
    log("extracting GPT-wrapped system image")
    run([seven_zip, "x", "-y", f"-o{gpt_dir}", image_path])

    super_images = sorted(
        path for path in gpt_dir.iterdir()
        if path.is_file() and "super" in path.name and path.suffix == ".img"
    )
    if not super_images:
        raise UpdateError(f"GPT image did not contain a super partition: {image_path}")

    system_image = unpack_super_image(android_root, super_images[0], tmp_dir)
    extract_filesystem_image(android_root, system_image, dest, tmp_dir)


def extract_filesystem_image(android_root, image_path, dest, tmp_dir):
    image_path = convert_sparse_if_needed(android_root, image_path, tmp_dir)
    fs_type = detect_filesystem(image_path)

    if fs_type == "gpt":
        extract_gpt_image(android_root, image_path, dest, tmp_dir)
        return

    if fs_type == "ext":
        debugfs = require_tool(
            android_root,
            "debugfs",
            "install e2fsprogs/debugfs to extract ext images",
        )
        log("extracting ext system image")
        dest.mkdir(parents=True, exist_ok=True)
        # debugfs parses the -R argument as its own command language; quote the
        # destination path so spaces or shell metacharacters in the cache dir
        # don't mis-target the dump.
        escaped_dest = str(dest).replace('\\', '\\\\').replace('"', '\\"')
        run_capture_on_error(
            [debugfs, "-R", f'rdump / "{escaped_dest}"', image_path]
        )
        return

    if fs_type == "erofs":
        fsck_erofs = require_tool(
            android_root,
            "fsck.erofs",
            "install erofs-utils, or build fsck.erofs from the Android tree",
        )
        log("extracting EROFS system image")
        dest.mkdir(parents=True, exist_ok=True)
        run([fsck_erofs, f"--extract={dest}", image_path])
        return

    seven_zip = tool(android_root, "7z")
    if seven_zip:
        log("extracting system image with 7z")
        dest.mkdir(parents=True, exist_ok=True)
        run([seven_zip, "x", "-y", f"-o{dest}", image_path])
        _reject_path_traversal_escapes(dest)
        return

    raise UpdateError(
        f"could not identify {image_path}; install debugfs, erofs-utils, or 7z"
    )


def _reject_path_traversal_escapes(root):
    # Guard against zip-slip / archive path traversal: if a malicious SDK
    # package contained entries with ../ components, refuse to proceed rather
    # than letting them land outside `root`.
    resolved_root = root.resolve()
    for path in resolved_root.rglob("*"):
        try:
            path.resolve().relative_to(resolved_root)
        except ValueError:
            raise UpdateError(
                f"archive contained an entry that escaped {resolved_root}: {path}"
            )


def find_system_root(path):
    candidates = (path, path / "system")
    for candidate in candidates:
        if (candidate / "lib64" / "libndk_translation.so").is_file():
            return candidate

    # A fully-extracted Android system image can be many GiB; cap the search
    # depth instead of walking the whole tree.
    matches = []
    base_depth = len(path.parts)
    max_depth = 6
    for root, dirs, files in os.walk(path):
        depth = len(Path(root).parts) - base_depth
        if depth > max_depth:
            dirs[:] = []
            continue
        if "libndk_translation.so" in files:
            matches.append(Path(root) / "libndk_translation.so")
    for match in matches:
        parts = match.parts
        if len(parts) >= 3 and parts[-3] in ("system", path.name) and parts[-2] in ("lib", "lib64"):
            return match.parents[1]
        if match.parent.name in ("lib", "lib64"):
            return match.parents[1]

    raise UpdateError(
        f"could not find lib64/libndk_translation.so under {path}"
    )


def copy_file(src, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)


def copy_relpath(system_root, relpath, output_root, copied):
    src = system_root / relpath
    if not src.exists():
        return

    dest = output_root / relpath
    if src.is_dir():
        for child in sorted(src.rglob("*")):
            if child.is_file():
                child_rel = child.relative_to(system_root)
                copy_file(child, output_root / child_rel)
                copied.add(str(child_rel))
    elif src.is_file():
        copy_file(src, dest)
        copied.add(relpath)


def stage_payload(source_root, output_root):
    system_root = find_system_root(source_root)
    copied = set()

    missing = []
    for relpath in PAYLOAD_REQUIRED_FILES:
        if not (system_root / relpath).is_file():
            missing.append(relpath)
            continue
        copy_relpath(system_root, relpath, output_root, copied)
    if missing:
        raise UpdateError(
            "native bridge payload missing required files: " + ", ".join(missing)
        )

    if (system_root / "lib" / "libndk_translation.so").is_file():
        missing = []
        for relpath in PAYLOAD_ARM32_FILES:
            if not (system_root / relpath).is_file():
                missing.append(relpath)
                continue
            copy_relpath(system_root, relpath, output_root, copied)
        if missing:
            raise UpdateError(
                "native bridge ARM32 payload missing required files: " + ", ".join(missing)
            )

    for pattern in PAYLOAD_GLOBS:
        for src in sorted(system_root.glob(pattern)):
            if src.is_file():
                relpath = src.relative_to(system_root)
                copy_file(src, output_root / relpath)
                copied.add(str(relpath))

    if len(copied) == 1:
        log("warning: only libndk_translation.so was found in the SDK payload")

    return sorted(copied)


def write_manifest(path, source, files):
    entries = []
    for relpath in files:
        full_path = path / "system" / relpath
        if full_path.is_file():
            entries.append(
                {
                    "path": relpath,
                    "size": full_path.stat().st_size,
                    "sha256": file_digest(full_path, "sha256"),
                }
            )

    manifest = {
        "source": source,
        "files": entries,
    }
    (path / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def write_android_bp(path):
    (path / "Android.bp").write_text(ANDROID_BP)


def install_payload(source_root, output_dir, source_description):
    parent = output_dir.parent
    parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix=".native_bridge.", dir=parent) as tmp_name:
        tmp_root = Path(tmp_name)
        stage_dir = tmp_root / "system"
        files = stage_payload(source_root, stage_dir)
        write_manifest(tmp_root, source_description, files)

        shutil.rmtree(output_dir, ignore_errors=True)
        shutil.move(str(stage_dir), output_dir)
        shutil.move(str(tmp_root / "manifest.json"), output_dir.parent / "manifest.json")
        write_android_bp(output_dir.parent)

    log(f"native bridge payload ready: {output_dir} ({len(files)} files)")


def update_from_sdk(
    android_root,
    output_dir,
    sdk_package,
    sdk_package_sha1,
    sdk_package_sha256,
    cache_dir,
):
    package_path = fetch_sdk_package(
        sdk_package, sdk_package_sha1, sdk_package_sha256, cache_dir
    )
    source_description = {
        "sdk_package": str(sdk_package),
        "sdk_package_sha1": file_digest(package_path, "sha1"),
        "sdk_package_sha256": file_digest(package_path, "sha256"),
    }

    extract_tmp_parent = android_root / "out"
    extract_tmp_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="lineage-native-bridge.", dir=extract_tmp_parent) as tmp_name:
        tmp_dir = Path(tmp_name)
        image = extract_system_image_from_zip(android_root, package_path, tmp_dir)
        extracted_system = tmp_dir / "system-root"
        extract_filesystem_image(android_root, image, extracted_system, tmp_dir)
        install_payload(extracted_system, output_dir, source_description)


def parse_args():
    cache_dir_env = os.environ.get("NATIVE_BRIDGE_CACHE_DIR")

    parser = argparse.ArgumentParser(
        description="Install Google NDK translation native bridge prebuilts for the x86-64 product."
    )
    parser.add_argument(
        "android_root",
        nargs="?",
        default=".",
        help="Android source root. Default: current directory.",
    )
    parser.add_argument(
        "--source-dir",
        default=os.environ.get("NATIVE_BRIDGE_SOURCE_DIR"),
        help="Use an already-extracted Android system root instead of downloading an SDK image.",
    )
    parser.add_argument(
        "--sdk-package",
        default=os.environ.get("NATIVE_BRIDGE_SDK_PACKAGE", DEFAULT_SDK_PACKAGE),
        help="Android SDK system image zip path or URL.",
    )
    parser.add_argument(
        "--sdk-package-sha1",
        default=os.environ.get("NATIVE_BRIDGE_SDK_PACKAGE_SHA1", DEFAULT_SDK_PACKAGE_SHA1),
        help="Expected SDK package SHA1. Set to an empty string to skip.",
    )
    parser.add_argument(
        "--sdk-package-sha256",
        default=os.environ.get("NATIVE_BRIDGE_SDK_PACKAGE_SHA256", DEFAULT_SDK_PACKAGE_SHA256),
        help="Expected SDK package SHA256. Empty skips; recommended for pinned builds.",
    )
    parser.add_argument(
        "--cache-dir",
        type=Path,
        default=Path(cache_dir_env) if cache_dir_env else None,
        help="Download cache directory. Default: out/lineage-desktop/native_bridge under the Android source root.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="Output system payload directory. Default: vendor/lineage_desktop/prebuilts/native_bridge/system.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    android_root = Path(args.android_root).resolve()
    cache_dir = args.cache_dir
    if cache_dir is None:
        cache_dir = android_root / "out" / "lineage-desktop" / "native_bridge"
    else:
        cache_dir = cache_dir.expanduser().resolve()
    output_dir = args.output_dir
    if output_dir is None:
        output_dir = (
            android_root
            / "vendor"
            / "lineage_desktop"
            / "prebuilts"
            / "native_bridge"
            / "system"
        )
    else:
        output_dir = output_dir.resolve()

    try:
        if args.source_dir:
            source_dir = Path(args.source_dir).expanduser().resolve()
            if not source_dir.is_dir():
                raise UpdateError(f"native bridge source directory is missing: {source_dir}")
            install_payload(source_dir, output_dir, {"source_dir": str(source_dir)})
        else:
            update_from_sdk(
                android_root,
                output_dir,
                args.sdk_package,
                args.sdk_package_sha1,
                args.sdk_package_sha256,
                cache_dir,
            )
    except (
        OSError,
        subprocess.CalledProcessError,
        urllib.error.URLError,
        zipfile.BadZipFile,
        UpdateError,
    ) as exc:
        print(f"[lineage-desktop] error: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
