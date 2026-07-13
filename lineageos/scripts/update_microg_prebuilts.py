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
_NETWORK_RETRIES = 20
_NETWORK_BACKOFF_SECONDS = 2.0
_NETWORK_MAX_BACKOFF_SECONDS = 60.0


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
            delay = min(
                _NETWORK_BACKOFF_SECONDS * (2 ** attempt),
                _NETWORK_MAX_BACKOFF_SECONDS,
            )
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


def cached_apk(cache_dir, download_url):
    """Return a local path to the APK, downloading into the persistent cache
    only on a miss. The upstream file name encodes the version code, so a name
    hit means the cached bytes are exactly this version -- no need to refetch."""
    cache_dir.mkdir(parents=True, exist_ok=True)
    apk_name = download_url.rsplit("/", 1)[-1]
    cached = cache_dir / apk_name
    if cached.exists():
        log(f"reusing cached {apk_name}")
        return cached
    log(f"downloading {apk_name}")
    download(download_url, cached)
    return cached


def install_from_cache(module_dir, apk_name, source, skip_certificate_check):
    apk_path = module_dir / apk_name

    if apk_path.exists() and not skip_certificate_check:
        old_cert = apk_certificate(apk_path)
        new_cert = apk_certificate(source)
        if old_cert is None:
            log("warning: keytool not found; skipping APK certificate continuity check")
        elif old_cert != new_cert:
            raise UpdateError(f"certificate mismatch while updating {apk_path}")

    # Copy the cached APK into the source tree via a temp file in the same
    # directory so an interrupted copy cannot leave a truncated APK behind, and
    # the cached original stays intact for reuse on the next build.
    fd, tmp_name = tempfile.mkstemp(prefix=f"{apk_name}.", suffix=".copy", dir=str(module_dir))
    os.close(fd)
    tmp_path = Path(tmp_name)
    try:
        shutil.copyfile(source, tmp_path)
        tmp_path.chmod(0o644)
        os.replace(tmp_path, apk_path)
    finally:
        tmp_path.unlink(missing_ok=True)


def replace_apk(module_dir, apk_name, download_url, skip_certificate_check, cache_dir):
    source = cached_apk(cache_dir, download_url)
    install_from_cache(module_dir, apk_name, source, skip_certificate_check)


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
    fakestore_privapp_permissions = (
        partner_dir / "FakeStore" / "privapp-permissions-com.android.vending.xml"
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
        "android.permission.DUMP",
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

    for permission in (
        "com.google.android.gms.permission.READ_SETTINGS",
        "com.google.android.gms.permission.WRITE_SETTINGS",
    ):
        changed |= ensure_permission(
            fakestore_privapp_permissions,
            "</privapp-permissions>",
            permission,
        )

    if changed:
        log("updated microG permission allowlists")


def update_module(partner_dir, module, asset, version_code, skip_certificate_check, cache_dir):
    module_dir = partner_dir / module
    if not module_dir.is_dir():
        raise UpdateError(f"missing microG module directory: {module_dir}")

    apk_name = f"{module}.apk"
    log(f"updating {module} to {version_code}")
    replace_apk(module_dir, apk_name, asset["browser_download_url"], skip_certificate_check, cache_dir)
    write_text_if_changed(module_dir / ".version_code", f"{version_code}\n")
    # Return the upstream, version-stamped file name so the caller can record it
    # in the cache manifest for later offline short-circuiting.
    return asset["browser_download_url"].rsplit("/", 1)[-1]


def install_cached_module(partner_dir, module, apk_filename, version_code,
                          cache_dir, skip_certificate_check):
    module_dir = partner_dir / module
    if not module_dir.is_dir():
        raise UpdateError(f"missing microG module directory: {module_dir}")

    source = cache_dir / apk_filename
    if not source.exists():
        raise UpdateError(f"cached APK is missing: {source}")

    log(f"installing {module} {version_code} from cache ({apk_filename})")
    install_from_cache(module_dir, f"{module}.apk", source, skip_certificate_check)
    write_text_if_changed(module_dir / ".version_code", f"{version_code}\n")


MANIFEST_NAME = "index.json"


def load_manifest(cache_dir):
    """Read the cache manifest, tolerating an absent or corrupt file."""
    try:
        return json.loads((cache_dir / MANIFEST_NAME).read_text())
    except (OSError, ValueError):
        return {}


def save_manifest(cache_dir, manifest):
    cache_dir.mkdir(parents=True, exist_ok=True)
    path = cache_dir / MANIFEST_NAME
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def record_manifest(manifest, module, keys, entry):
    """Record a module's resolved APK under every stable key it can be pinned by
    (selector, version code, version name / release tag). 'latest' is never a
    key -- it must always re-resolve so a newer upstream release is picked up."""
    slot = manifest.setdefault(module, {})
    for key in keys:
        if key and key != "latest":
            slot[key] = entry


def cached_entry(manifest, module, selector, cache_dir):
    """Return the manifest entry for a pinned selector whose APK is present in
    the cache, else None. Enables a fully offline run: a pinned version that is
    already cached needs no upstream metadata lookup at all."""
    if selector == "latest":
        return None
    entry = manifest.get(module, {}).get(selector)
    if not entry or not (cache_dir / entry["apk"]).exists():
        return None
    return entry


def build_gmscore_main(android_root, cache_dir):
    build_script = Path(__file__).with_name("build_microg_main.py")
    if not build_script.is_file():
        raise UpdateError(f"missing GmsCore source build script: {build_script}")
    try:
        output = subprocess.check_output(
            [str(build_script), str(android_root), "--output-dir", str(cache_dir)],
            text=True,
        )
        result = json.loads(output)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        raise UpdateError(f"failed to build GmsCore from upstream main: {exc}") from exc
    apk = Path(result.get("apk", ""))
    if not apk.is_file() or not result.get("commit") or not result.get("version_code"):
        raise UpdateError(f"invalid GmsCore source build result: {result}")
    return result


def update_microg(android_root, gmscore_release_selector, gsfproxy_release_selector,
                  fdroid_release_selector, fdroid_privileged_release_selector,
                  skip_certificate_check, cache_dir):
    partner_dir = android_root / "vendor" / "partner_gms"
    if not partner_dir.is_dir():
        raise UpdateError(
            "vendor/partner_gms is missing; sync the lineageos4microg manifest first"
        )

    log(f"microG prebuilt cache: {cache_dir}")
    manifest = load_manifest(cache_dir)
    summary = {}

    # Ika follows GmsCore's upstream main branch so merged compatibility fixes
    # do not have to wait for a release. FakeStore still comes from the latest
    # official release and retains its upstream certificate/signature-spoofed
    # Play Store identity for Google authentication.
    source_marker = partner_dir / ".gmscore_source.json"
    was_source_built = source_marker.is_file()
    if gmscore_release_selector == "main":
        result = build_gmscore_main(android_root, cache_dir)
        commit = result["commit"]
        version_code = str(result["version_code"])
        module_dir = partner_dir / "GmsCore"
        install_from_cache(module_dir, "GmsCore.apk", Path(result["apk"]), True)
        write_text_if_changed(module_dir / ".version_code", f"{version_code}\n")
        write_text_if_changed(
            source_marker,
            json.dumps(
                {"selector": "main", "branch": result["branch"], "commit": commit},
                sort_keys=True,
            ) + "\n",
        )
        gmscore_tag = f"main@{commit}"
        summary["GmsCore"] = f"{gmscore_tag}/{version_code}"

        fakestore_release = release_for(GMSCORE_REPO, "latest")
        fakestore_tag = fakestore_release["tag_name"]
        fakestore_asset, fakestore_match = find_asset(
            fakestore_release, r"com\.android\.vending-(\d+)\.apk")
        fakestore_apk = update_module(
            partner_dir, "FakeStore", fakestore_asset, fakestore_match.group(1),
            skip_certificate_check, cache_dir)
        record_manifest(
            manifest, "FakeStore", (fakestore_tag,),
            {"apk": fakestore_apk, "version_code": fakestore_match.group(1),
             "tag": fakestore_tag},
        )
        summary["FakeStore"] = fakestore_match.group(1)
    # Release-mode GmsCore and FakeStore ship in the same microg/GmsCore
    # release, so they share one selector and one GitHub metadata lookup.
    gms_cached = cached_entry(manifest, "GmsCore", gmscore_release_selector, cache_dir)
    fakestore_cached = cached_entry(manifest, "FakeStore", gmscore_release_selector, cache_dir)
    if gmscore_release_selector == "main":
        pass
    elif gms_cached and fakestore_cached:
        log(f"GmsCore/FakeStore: pinned '{gmscore_release_selector}' already cached; "
            "skipping GitHub metadata lookup")
        gmscore_tag = gms_cached.get("tag", gmscore_release_selector)
        install_cached_module(partner_dir, "GmsCore", gms_cached["apk"],
                              gms_cached["version_code"], cache_dir,
                              skip_certificate_check or was_source_built)
        install_cached_module(partner_dir, "FakeStore", fakestore_cached["apk"],
                              fakestore_cached["version_code"], cache_dir, skip_certificate_check)
        summary["GmsCore"] = f"{gmscore_tag}/{gms_cached['version_code']}"
        summary["FakeStore"] = fakestore_cached["version_code"]
    else:
        gmscore_release = release_for(GMSCORE_REPO, gmscore_release_selector)
        gmscore_tag = gmscore_release["tag_name"]
        gmscore_asset, gmscore_match = find_asset(
            gmscore_release, r"com\.google\.android\.gms-(\d+)\.apk")
        fakestore_asset, fakestore_match = find_asset(
            gmscore_release, r"com\.android\.vending-(\d+)\.apk")

        gms_apk = update_module(partner_dir, "GmsCore", gmscore_asset,
                                gmscore_match.group(1),
                                skip_certificate_check or was_source_built, cache_dir)
        fakestore_apk = update_module(partner_dir, "FakeStore", fakestore_asset,
                                      fakestore_match.group(1), skip_certificate_check, cache_dir)

        record_manifest(manifest, "GmsCore", (gmscore_release_selector, gmscore_tag),
                        {"apk": gms_apk, "version_code": gmscore_match.group(1),
                         "tag": gmscore_tag})
        record_manifest(manifest, "FakeStore", (gmscore_release_selector, gmscore_tag),
                        {"apk": fakestore_apk, "version_code": fakestore_match.group(1),
                         "tag": gmscore_tag})
        summary["GmsCore"] = f"{gmscore_tag}/{gmscore_match.group(1)}"
        summary["FakeStore"] = fakestore_match.group(1)

    if gmscore_release_selector != "main":
        source_marker.unlink(missing_ok=True)

    # F-Droid modules: each resolves from its own repo index (the ~15 MiB
    # metadata download that a pinned+cached run gets to skip entirely).
    fdroid_modules = (
        ("GsfProxy", FDROID_MICROG_REPO, "com.google.android.gsf", gsfproxy_release_selector),
        ("FDroid", FDROID_MAIN_REPO, "org.fdroid.fdroid", fdroid_release_selector),
        ("FDroidPrivilegedExtension", FDROID_MAIN_REPO,
         "org.fdroid.fdroid.privileged", fdroid_privileged_release_selector),
    )
    for module, repo_url, application_id, selector in fdroid_modules:
        entry = cached_entry(manifest, module, selector, cache_dir)
        if entry:
            log(f"{module}: pinned '{selector}' already cached; skipping F-Droid index lookup")
            install_cached_module(partner_dir, module, entry["apk"],
                                  entry["version_code"], cache_dir, skip_certificate_check)
            summary[module] = f"{entry.get('version_name', entry['version_code'])}/{entry['version_code']}"
        else:
            release = fdroid_release(repo_url, application_id, selector)
            apk = update_module(partner_dir, module, release, release["version_code"],
                                skip_certificate_check, cache_dir)
            record_manifest(manifest, module,
                            (selector, release["version_code"], release["version_name"]),
                            {"apk": apk, "version_code": release["version_code"],
                             "version_name": release["version_name"]})
            summary[module] = f"{release['version_name']}/{release['version_code']}"

    ensure_partner_permissions(partner_dir)
    write_text_if_changed(partner_dir / ".microg_release", f"{gmscore_tag}\n")
    save_manifest(cache_dir, manifest)

    log(
        "microG prebuilts ready: "
        f"GmsCore {summary['GmsCore']}, "
        f"FakeStore {summary['FakeStore']}, "
        f"GsfProxy {summary['GsfProxy']}, "
        f"FDroid {summary['FDroid']}, "
        f"FDroidPrivilegedExtension {summary['FDroidPrivilegedExtension']}"
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
        default=os.environ.get("MICROG_GMSCORE_RELEASE", "main"),
        help="microg/GmsCore release tag, latest, or main. Default: main.",
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
    parser.add_argument(
        "--cache-dir",
        default=os.environ.get("MICROG_PREBUILT_CACHE_DIR", ""),
        help="Persistent directory for downloaded APKs; a version already present "
             "is reused instead of refetched. "
             "Default: $MICROG_PREBUILT_CACHE_DIR or ~/ika-build/microg-prebuilts.",
    )
    return parser.parse_args()


def resolve_cache_dir(cache_dir_arg):
    if cache_dir_arg:
        return Path(cache_dir_arg).expanduser()
    return Path.home() / "ika-build" / "microg-prebuilts"


def main():
    args = parse_args()
    android_root = Path(args.android_root).resolve()
    cache_dir = resolve_cache_dir(args.cache_dir)
    try:
        update_microg(
            android_root,
            args.gmscore_release,
            args.gsfproxy_release,
            args.fdroid_release,
            args.fdroid_privileged_release,
            args.skip_certificate_check,
            cache_dir,
        )
    except (OSError, KeyError, ValueError, urllib.error.URLError, UpdateError) as exc:
        print(f"[lineage-desktop] error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
