#!/usr/bin/env python3
#
# Copyright (C) 2026 LineageOS Desktop Project
# SPDX-License-Identifier: Apache-2.0
#

import argparse
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from xml.dom import pulldom


GITHUB_API = "https://api.github.com/repos"
GMSCORE_REPO = "microg/GmsCore"
FDROID_MICROG_REPO = "https://microg.org/fdroid/repo"
FDROID_MAIN_REPO = "https://f-droid.org/repo"
USER_AGENT = "lineage-desktop-microg-updater/1.0"

# Transient network errors that should trigger a retry. F-Droid's index is
# ~15 MiB and TLS reads occasionally truncate; GitHub returns 5xx under load.
_TRANSIENT_HTTP_STATUSES = (408, 429, 500, 502, 503, 504)
_NETWORK_RETRIES = 4
_NETWORK_BACKOFF_SECONDS = 2.0


def _is_transient_exception(exc):
    if isinstance(exc, urllib.error.HTTPError):
        return exc.code in _TRANSIENT_HTTP_STATUSES
    return isinstance(
        exc,
        (
            urllib.error.URLError,
            http.client.IncompleteRead,
            http.client.RemoteDisconnected,
            ConnectionError,
            TimeoutError,
            zipfile.BadZipFile,
        ),
    )


def _retry_network(label, attempt_fn):
    last_exc = None
    for attempt in range(_NETWORK_RETRIES + 1):
        try:
            return attempt_fn()
        except Exception as exc:
            if not _is_transient_exception(exc) or attempt == _NETWORK_RETRIES:
                raise
            last_exc = exc
            delay = _NETWORK_BACKOFF_SECONDS * (2 ** attempt)
            log(f"network retry {attempt + 1}/{_NETWORK_RETRIES} for {label}: {exc} (sleeping {delay:.1f}s)")
            time.sleep(delay)
    if last_exc is not None:
        raise last_exc


class UpdateError(Exception):
    pass


def log(message):
    print(f"[lineage-desktop] {message}")


def read_json(url):
    def attempt():
        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/vnd.github+json",
                "User-Agent": USER_AGENT,
            },
        )
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    return _retry_network(url, attempt)


def latest_release_from_list(repo):
    releases = read_json(f"{GITHUB_API}/{repo}/releases")
    for release in releases:
        if not release.get("draft") and not release.get("prerelease"):
            return release
    for release in releases:
        if not release.get("draft"):
            return release
    raise UpdateError(f"{repo} has no published releases")


def release_for(repo, selector):
    if selector == "latest":
        try:
            return read_json(f"{GITHUB_API}/{repo}/releases/latest")
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
            return latest_release_from_list(repo)
    return read_json(f"{GITHUB_API}/{repo}/releases/tags/{selector}")


def find_asset(release, pattern):
    regex = re.compile(pattern)
    for asset in release.get("assets", []):
        match = regex.fullmatch(asset.get("name", ""))
        if match:
            return asset, match
    tag = release.get("tag_name", "<unknown>")
    raise UpdateError(f"release {tag} is missing asset matching {pattern}")


def download(url, dest):
    def attempt():
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        # Write to a temp file and rename on success so a half-finished download
        # cannot masquerade as a complete one on retry.
        tmp = Path(str(dest) + ".partial")
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                with open(tmp, "wb") as output:
                    shutil.copyfileobj(response, output)
            with zipfile.ZipFile(tmp) as archive:
                bad_member = archive.testzip()
            if bad_member is not None:
                raise zipfile.BadZipFile(f"corrupt zip member: {bad_member}")
            tmp.replace(dest)
        finally:
            try:
                tmp.unlink()
            except FileNotFoundError:
                pass
    _retry_network(url, attempt)


def _child_el_content(el, tag_name):
    node = el.getElementsByTagName(tag_name).item(0)
    if node is None or node.firstChild is None:
        return ""
    return node.firstChild.data


def fdroid_release(repo_url, application_id, selector):
    index_url = f"{repo_url}/index.xml"

    def attempt():
        request = urllib.request.Request(index_url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.read().decode("utf-8")

    body = _retry_network(index_url, attempt)
    doc = pulldom.parseString(body)

    for event, node in doc:
        if event != pulldom.START_ELEMENT or node.tagName != "application":
            continue
        if node.getAttribute("id") != application_id:
            continue

        doc.expandNode(node)
        marketvercode = _child_el_content(node, "marketvercode")
        selected = marketvercode if selector == "latest" else selector
        for package in node.getElementsByTagName("package"):
            version_code = _child_el_content(package, "versioncode")
            version_name = _child_el_content(package, "version")
            if selected not in (version_code, version_name):
                continue
            apk_name = _child_el_content(package, "apkname")
            return {
                "version_name": version_name or version_code,
                "version_code": version_code,
                "browser_download_url": f"{repo_url}/{apk_name}",
            }

    raise UpdateError(f"did not find {application_id} {selector} in {repo_url}")


def apk_certificate(apk_path):
    keytool = shutil.which("keytool")
    if keytool is None:
        return None

    output = subprocess.check_output(
        [keytool, "-printcert", "-rfc", "-jarfile", str(apk_path)],
        text=True,
        stderr=subprocess.STDOUT,
    )
    begin = output.index("-----BEGIN CERTIFICATE-----")
    end = output.index("-----END CERTIFICATE-----") + len("-----END CERTIFICATE-----")
    return output[begin:end]


def replace_apk(module_dir, apk_name, download_url, skip_certificate_check):
    apk_path = module_dir / apk_name
    fd, tmp_name = tempfile.mkstemp(prefix=f"{apk_name}.", suffix=".download")
    os.close(fd)
    tmp_path = Path(tmp_name)

    try:
        download(download_url, tmp_path)

        if apk_path.exists() and not skip_certificate_check:
            old_cert = apk_certificate(apk_path)
            new_cert = apk_certificate(tmp_path)
            if old_cert is None:
                log("warning: keytool not found; skipping APK certificate continuity check")
            elif old_cert != new_cert:
                raise UpdateError(f"certificate mismatch while updating {apk_path}")

        shutil.move(str(tmp_path), apk_path)
        apk_path.chmod(0o644)
    finally:
        tmp_path.unlink(missing_ok=True)


def write_text_if_changed(path, value):
    old_value = path.read_text() if path.exists() else None
    if old_value == value:
        return False
    path.write_text(value)
    return True


def ensure_permission(path, closing_tag, permission, attrs=""):
    text = path.read_text()
    if f'name="{permission}"' in text:
        return False

    match = re.search(rf"(?m)^([ \t]*)({re.escape(closing_tag)})", text)
    if not match:
        raise UpdateError(f"could not find {closing_tag} in {path}")

    previous_permissions = list(
        re.finditer(r"(?m)^([ \t]*)<permission ", text[:match.start()])
    )
    if previous_permissions:
        indent = previous_permissions[-1].group(1)
    else:
        indent = f"{match.group(1)}  "
    permission_line = f'{indent}<permission name="{permission}"{attrs}/>\n'
    updated = text[:match.start()] + permission_line + text[match.start():]
    path.write_text(updated)
    return True


def replace_permission_placeholder(path, placeholder, permission, attrs=""):
    text = path.read_text()
    if f'name="{permission}"' in text:
        return False

    pattern = re.compile(rf"(?m)^([ \t]*)<!-- {re.escape(placeholder)} -->")
    match = pattern.search(text)
    if not match:
        return ensure_permission(path, "</exception>", permission, attrs)

    indent = match.group(1)
    updated = (
        text[:match.start()]
        + f'{indent}<permission name="{permission}"{attrs}/>'
        + text[match.end():]
    )
    path.write_text(updated)
    return True


def remove_permission(path, permission):
    text = path.read_text()
    updated = re.sub(
        rf"(?m)^[ \t]*<!-- for permissive signature spoofing.*\n"
        rf"[ \t]*<permission name=\"{re.escape(permission)}\"[^>]*/>\n",
        "",
        text,
    )
    updated = re.sub(
        rf"(?m)^[ \t]*<permission name=\"{re.escape(permission)}\"[^>]*/>\n",
        "",
        updated,
    )
    if updated == text:
        return False
    path.write_text(updated)
    return True


def ensure_partner_permissions(partner_dir):
    changed = False
    gms_default_permissions = partner_dir / "GmsCore" / "default-permissions-com.google.android.gms.xml"
    gms_privapp_permissions = partner_dir / "GmsCore" / "privapp-permissions-com.google.android.gms.xml"
    fakestore_default_permissions = (
        partner_dir / "FakeStore" / "default-permissions-com.android.vending.xml"
    )

    changed |= replace_permission_placeholder(
        gms_default_permissions,
        "%ACCESS_BACKGROUND_LOCATION%",
        "android.permission.ACCESS_BACKGROUND_LOCATION",
        ' fixed="false" ',
    )
    for permission in (
        "android.permission.BLUETOOTH_SCAN",
        "android.permission.BLUETOOTH_CONNECT",
        "android.permission.BLUETOOTH_ADVERTISE",
    ):
        changed |= ensure_permission(
            gms_default_permissions,
            "</exception>",
            permission,
            ' fixed="false" ',
        )

    for permission in (
        "android.permission.READ_SYSTEM_GRAMMATICAL_GENDER",
        "android.permission.PROVIDE_REMOTE_CREDENTIALS",
        "android.permission.PROVIDE_DEFAULT_ENABLED_CREDENTIAL_SERVICE",
    ):
        changed |= ensure_permission(
            gms_privapp_permissions,
            "</privapp-permissions>",
            permission,
        )

    changed |= remove_permission(
        fakestore_default_permissions,
        "android.permission.FAKE_PACKAGE_SIGNATURE",
    )

    if changed:
        log("updated microG permission allowlists")


def update_module(partner_dir, module, asset, version_code, skip_certificate_check):
    module_dir = partner_dir / module
    if not module_dir.is_dir():
        raise UpdateError(f"missing microG module directory: {module_dir}")

    apk_name = f"{module}.apk"
    log(f"updating {module} to {version_code}")
    replace_apk(module_dir, apk_name, asset["browser_download_url"], skip_certificate_check)
    write_text_if_changed(module_dir / ".version_code", f"{version_code}\n")


def update_microg(android_root, gmscore_release_selector, gsfproxy_release_selector,
                  fdroid_release_selector, fdroid_privileged_release_selector,
                  skip_certificate_check):
    partner_dir = android_root / "vendor" / "partner_gms"
    if not partner_dir.is_dir():
        raise UpdateError(
            "vendor/partner_gms is missing; sync the lineageos4microg manifest first"
        )

    gmscore_release = release_for(GMSCORE_REPO, gmscore_release_selector)
    gmscore_tag = gmscore_release["tag_name"]
    gmscore_asset, gmscore_match = find_asset(
        gmscore_release,
        r"com\.google\.android\.gms-(\d+)\.apk",
    )
    fakestore_asset, fakestore_match = find_asset(
        gmscore_release,
        r"com\.android\.vending-(\d+)\.apk",
    )

    gsfproxy_release = fdroid_release(
        FDROID_MICROG_REPO,
        "com.google.android.gsf",
        gsfproxy_release_selector,
    )
    gsfproxy_version = (
        f"{gsfproxy_release['version_name']}/"
        f"{gsfproxy_release['version_code']}"
    )
    fdroid_app_release = fdroid_release(
        FDROID_MAIN_REPO,
        "org.fdroid.fdroid",
        fdroid_release_selector,
    )
    fdroid_version = (
        f"{fdroid_app_release['version_name']}/"
        f"{fdroid_app_release['version_code']}"
    )
    fdroid_privileged_release = fdroid_release(
        FDROID_MAIN_REPO,
        "org.fdroid.fdroid.privileged",
        fdroid_privileged_release_selector,
    )
    fdroid_privileged_version = (
        f"{fdroid_privileged_release['version_name']}/"
        f"{fdroid_privileged_release['version_code']}"
    )

    update_module(
        partner_dir,
        "GmsCore",
        gmscore_asset,
        gmscore_match.group(1),
        skip_certificate_check,
    )
    update_module(
        partner_dir,
        "FakeStore",
        fakestore_asset,
        fakestore_match.group(1),
        skip_certificate_check,
    )
    update_module(
        partner_dir,
        "GsfProxy",
        gsfproxy_release,
        gsfproxy_release["version_code"],
        skip_certificate_check,
    )
    update_module(
        partner_dir,
        "FDroid",
        fdroid_app_release,
        fdroid_app_release["version_code"],
        skip_certificate_check,
    )
    update_module(
        partner_dir,
        "FDroidPrivilegedExtension",
        fdroid_privileged_release,
        fdroid_privileged_release["version_code"],
        skip_certificate_check,
    )
    ensure_partner_permissions(partner_dir)
    write_text_if_changed(partner_dir / ".microg_release", f"{gmscore_tag}\n")

    log(
        "microG prebuilts ready: "
        f"GmsCore {gmscore_tag}/{gmscore_match.group(1)}, "
        f"FakeStore {fakestore_match.group(1)}, "
        f"GsfProxy {gsfproxy_version}, "
        f"FDroid {fdroid_version}, "
        f"FDroidPrivilegedExtension {fdroid_privileged_version}"
    )


def parse_args():
    parser = argparse.ArgumentParser(
        description="Refresh vendor/partner_gms APKs from official microG GitHub releases."
    )
    parser.add_argument(
        "android_root",
        nargs="?",
        default=".",
        help="Android source root. Default: current directory.",
    )
    parser.add_argument(
        "--gmscore-release",
        default=os.environ.get("MICROG_GMSCORE_RELEASE", "latest"),
        help="microg/GmsCore release tag, or latest. Default: latest.",
    )
    parser.add_argument(
        "--gsfproxy-release",
        default=os.environ.get("MICROG_GSFPROXY_RELEASE", "latest"),
        help="GsfProxy microG F-Droid version name/code, or latest. Default: latest.",
    )
    parser.add_argument(
        "--fdroid-release",
        default=os.environ.get("MICROG_FDROID_RELEASE", "latest"),
        help="F-Droid version name/code, or latest. Default: latest.",
    )
    parser.add_argument(
        "--fdroid-privileged-release",
        default=os.environ.get("MICROG_FDROID_PRIVILEGED_RELEASE", "latest"),
        help="F-Droid Privileged Extension version name/code, or latest. Default: latest.",
    )
    parser.add_argument(
        "--skip-certificate-check",
        action="store_true",
        default=os.environ.get("MICROG_SKIP_CERTIFICATE_CHECK", "0") == "1",
        help="Do not compare APK signing certificates against the current prebuilts.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    android_root = Path(args.android_root).resolve()
    try:
        update_microg(
            android_root,
            args.gmscore_release,
            args.gsfproxy_release,
            args.fdroid_release,
            args.fdroid_privileged_release,
            args.skip_certificate_check,
        )
    except (OSError, KeyError, ValueError, urllib.error.URLError, UpdateError) as exc:
        print(f"[lineage-desktop] error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
