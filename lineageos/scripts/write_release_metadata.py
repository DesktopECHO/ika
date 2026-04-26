#!/usr/bin/env python3
"""Write release metadata into a Cuttlefish bundle."""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
from typing import Any


def run(cmd: list[str], cwd: Path | None = None) -> str | None:
    try:
        completed = subprocess.run(
            cmd,
            cwd=cwd,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return completed.stdout.strip()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_info(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {"present": False}
    return {
        "present": True,
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    }


def git_info(path: Path) -> dict[str, Any]:
    commit = run(["git", "rev-parse", "HEAD"], cwd=path)
    if commit is None:
        return {"present": False}
    status = run(["git", "status", "--short"], cwd=path) or ""
    branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=path)
    # Record every configured remote so supply-chain attestation captures the
    # full fetch surface, not just a single hand-picked remote name.
    remotes: dict[str, str] = {}
    remote_names = run(["git", "remote"], cwd=path) or ""
    for name in (line.strip() for line in remote_names.splitlines() if line.strip()):
        url = run(["git", "remote", "get-url", name], cwd=path)
        if url:
            remotes[name] = url
    # Preserve the legacy "remote" key for compatibility with older readers.
    legacy_remote = remotes.get("desktopecho") or remotes.get("origin") or next(
        iter(remotes.values()), None
    )
    return {
        "present": True,
        "commit": commit,
        "branch": branch,
        "dirty": bool(status),
        "remote": legacy_remote,
        "remotes": remotes,
    }


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return None


def microg_info(android_root: Path) -> dict[str, Any]:
    partner = android_root / "vendor" / "partner_gms"
    modules = {
        "GmsCore": partner / "GmsCore" / "GmsCore.apk",
        "FakeStore": partner / "FakeStore" / "FakeStore.apk",
        "GsfProxy": partner / "GsfProxy" / "GsfProxy.apk",
        "FDroid": partner / "FDroid" / "FDroid.apk",
        "FDroidPrivilegedExtension": partner
        / "FDroidPrivilegedExtension"
        / "FDroidPrivilegedExtension.apk",
    }
    return {
        "release": read_text(partner / ".microg_release"),
        "modules": {name: file_info(path) for name, path in modules.items()},
    }


def webview_info(android_root: Path, arch: str) -> dict[str, Any]:
    prebuilt_arch = "arm64" if arch == "arm64" else "x86_64"
    path = android_root / "external" / "chromium-webview" / "prebuilt" / prebuilt_arch / "webview.apk"
    data = file_info(path)
    data["prebuilt_arch"] = prebuilt_arch
    return data


def native_bridge_info(android_root: Path) -> dict[str, Any]:
    bridge = android_root / "vendor" / "lineage_desktop" / "prebuilts" / "native_bridge"
    manifest_path = bridge / "manifest.json"
    manifest: Any = None
    if manifest_path.is_file():
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            manifest = read_text(manifest_path)

    files = {
        "libndk_translation": bridge / "system" / "lib64" / "libndk_translation.so",
        "binfmt_arm64_dyn": bridge / "system" / "etc" / "binfmt_misc" / "arm64_dyn",
        "binfmt_arm64_exe": bridge / "system" / "etc" / "binfmt_misc" / "arm64_exe",
        "init_rc": bridge / "system" / "etc" / "init" / "ndk_translation.rc",
        "ld_config_arm64": bridge / "system" / "etc" / "ld.config.arm64.txt",
    }
    return {
        "manifest": manifest,
        "files": {name: file_info(path) for name, path in files.items()},
    }


def write_source_manifest(android_root: Path, bundle_dir: Path) -> dict[str, Any]:
    """Write source-manifest.xml. Return a dict describing success or failure
    so the caller can surface the reason in build-info.json instead of
    silently omitting the manifest from the bundle."""
    repo = shutil.which("repo")
    if repo is None:
        return {"path": None, "reason": "repo not found on host"}
    try:
        completed = subprocess.run(
            [repo, "manifest", "-r"],
            cwd=android_root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError as exc:
        return {"path": None, "reason": f"could not exec repo: {exc}"}
    except subprocess.CalledProcessError as exc:
        return {
            "path": None,
            "reason": f"repo manifest -r failed (exit {exc.returncode}): {exc.stderr.strip()}",
        }

    path = bundle_dir / "source-manifest.xml"
    path.write_text(completed.stdout, encoding="utf-8")
    return {"path": path.name, "reason": None}


def build_metadata(args: argparse.Namespace) -> dict[str, Any]:
    android_root = Path(args.android_root).resolve()
    overlay_dir = Path(args.overlay_dir).resolve()
    bundle_dir = Path(args.bundle_dir).resolve()
    product_out = Path(args.product_out).resolve()

    source_manifest_result = write_source_manifest(android_root, bundle_dir)

    image_names = args.image or []
    images = {
        image: file_info(bundle_dir / image)
        for image in image_names
        if (bundle_dir / image).exists()
    }

    metadata: dict[str, Any] = {
        "schema": 1,
        "generated_utc": _dt.datetime.now(_dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat(),
        "product": args.product,
        "arch": args.arch,
        "lineage_branch": args.lineage_branch,
        "host": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
        },
        "paths": {
            "product_out": str(product_out),
        },
        "overlay": git_info(overlay_dir),
        "android": {
            "manifest_branch": args.lineage_branch,
            "source_manifest": source_manifest_result["path"],
            "source_manifest_error": source_manifest_result["reason"],
        },
        "build_options": {
            "include_microg": os.environ.get("INCLUDE_MICROG", "1"),
            "update_microg_prebuilts": os.environ.get("UPDATE_MICROG_PREBUILTS", "1"),
            "include_x86_arm_native_bridge": os.environ.get(
                "INCLUDE_X86_ARM_NATIVE_BRIDGE", "1"
            ),
            "update_native_bridge_prebuilts": os.environ.get(
                "UPDATE_NATIVE_BRIDGE_PREBUILTS", "1"
            ),
            "microg_gmscore_release": os.environ.get("MICROG_GMSCORE_RELEASE", "latest"),
            "microg_gsfproxy_release": os.environ.get("MICROG_GSFPROXY_RELEASE", "latest"),
            "microg_fdroid_release": os.environ.get("MICROG_FDROID_RELEASE", "latest"),
            "microg_fdroid_privileged_release": os.environ.get(
                "MICROG_FDROID_PRIVILEGED_RELEASE", "latest"
            ),
            "native_bridge_sdk_package_sha1": os.environ.get(
                "NATIVE_BRIDGE_SDK_PACKAGE_SHA1", ""
            ),
        },
        "images": images,
        "microg": microg_info(android_root),
        "webview": webview_info(android_root, args.arch),
    }

    if args.arch == "x86_64":
        metadata["native_bridge"] = native_bridge_info(android_root)

    return metadata


def write_text_summary(metadata: dict[str, Any], path: Path) -> None:
    overlay = metadata.get("overlay", {})
    image_count = len(metadata.get("images", {}))
    lines = [
        "LineageOS Desktop build metadata",
        f"Generated UTC: {metadata['generated_utc']}",
        f"Product: {metadata['product']}",
        f"Architecture: {metadata['arch']}",
        f"Lineage branch: {metadata['lineage_branch']}",
        f"Overlay commit: {overlay.get('commit', 'unknown')}",
        f"Overlay dirty: {overlay.get('dirty', 'unknown')}",
        f"Image files: {image_count}",
        f"microG release: {metadata.get('microg', {}).get('release') or 'unknown'}",
    ]
    if metadata["arch"] == "x86_64":
        bridge = metadata.get("native_bridge", {})
        bridge_file = bridge.get("files", {}).get("libndk_translation", {})
        lines.append(f"Native bridge present: {bridge_file.get('present', False)}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--android-root", required=True)
    parser.add_argument("--overlay-dir", required=True)
    parser.add_argument("--product-out", required=True)
    parser.add_argument("--bundle-dir", required=True)
    parser.add_argument("--arch", required=True, choices=("arm64", "x86_64"))
    parser.add_argument("--product", required=True)
    parser.add_argument("--lineage-branch", required=True)
    parser.add_argument("--image", action="append", default=[])
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    bundle_dir = Path(args.bundle_dir)
    bundle_dir.mkdir(parents=True, exist_ok=True)
    metadata = build_metadata(args)
    (bundle_dir / "build-info.json").write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    write_text_summary(metadata, bundle_dir / "build-info.txt")

    # STRICT_RELEASE=1 means: this bundle is intended to be reproducible by a
    # third party. Fail loudly if any input version is still floating ("latest")
    # or if the source-manifest could not be emitted.
    if os.environ.get("STRICT_RELEASE", "0") == "1":
        problems: list[str] = []
        for key, value in metadata.get("build_options", {}).items():
            if key.endswith("_release") and value == "latest":
                problems.append(f"{key} is 'latest'; pin a version for reproducible builds")
        if metadata["android"].get("source_manifest_error"):
            problems.append(
                f"source-manifest.xml missing: {metadata['android']['source_manifest_error']}"
            )
        if problems:
            import sys
            for problem in problems:
                print(f"[lineage-desktop] STRICT_RELEASE: {problem}", file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()
