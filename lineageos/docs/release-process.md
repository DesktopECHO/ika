# Release Process

Each public tarball should be reproducible from documented inputs.

Before building:

1. Choose the LineageOS branch and manifest revision.
2. Choose microG versions or leave them as `latest` and let the build metadata
   record the resolved APK checksums.
3. Choose the native bridge SDK payload for x86-64, or set
   `NATIVE_BRIDGE_SOURCE_DIR` to a vetted extracted payload.
4. Run the one-command build script from a clean or script-managed workspace.

The build script runs `scripts/validate_build_inputs.sh` before compiling. It
checks patch application state, userdata policy, required microG APKs, WebView
prebuilts, native bridge files for x86-64, and required desktop aconfig flags.

Each generated Cuttlefish bundle contains:

- `build-info.json`: machine-readable release metadata
- `build-info.txt`: short human-readable summary
- `source-manifest.xml`: `repo manifest -r` output when `repo` is available
- image checksums for files copied into the bundle
- microG APK checksums
- WebView APK checksum for the target architecture
- native bridge payload metadata for x86-64

Release reviewers should compare these files between ARM64 and x86-64 before
publishing. Expected differences are architecture, kernel artifacts, host
package, WebView architecture prebuilt, and x86-64 native bridge metadata.
