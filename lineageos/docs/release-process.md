# Release Process

Each public release should be reproducible from documented inputs.

Before building:

1. Choose the LineageOS branch and manifest revision.
2. Choose `--microg` or `--mtg` when that provider should be included. For
   microG, the newest published, non-draft GmsCore entry (including prereleases)
   is selected unless an explicit release tag is pinned; choose the other module
   versions as needed. Build metadata records the selected provider and its
   resolved source information.
3. Choose the native bridge SDK payload for x86-64, or set
   `NATIVE_BRIDGE_SOURCE_DIR` to a vetted extracted payload.
4. Run the one-command build script from a clean or script-managed workspace.

The build script runs `scripts/lib/validate_build_inputs.sh` before compiling. It
checks patch application state, userdata policy, selected provider prebuilts,
WebView prebuilts, native bridge files for x86-64, and required desktop aconfig
flags.

Each generated Cuttlefish bundle contains:

- `build-info.json`: machine-readable release metadata
- `build-info.txt`: short human-readable summary
- `source-manifest.xml`: `repo manifest -r` output when `repo` is available
- image checksums for files copied into the bundle
- selected provider source and prebuilt metadata
- WebView APK checksum for the target architecture
- native bridge payload metadata for x86-64
- Vulkan CTS artifacts on both architectures
- ARM64 static/dynamic native-bridge regression suites on x86-64

Release reviewers should compare these files between ARM64 and x86-64 before
publishing. Expected differences are the target product and architecture,
kernel artifacts, WebView architecture prebuilt, and x86-64 native bridge
metadata.

Before publishing x86-64, boot the final bundle and run
`testcases/native_bridge/run-tests.sh -s SERIAL`. Run at least one Vulkan CTS
smoke case from the bundled APK or command-line dEQP binary as well.
