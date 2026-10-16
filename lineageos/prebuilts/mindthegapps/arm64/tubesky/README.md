# Google Play Store for Android TV

`Tubesky.apk` is the Android TV build of the Google Play Store
(`com.android.vending` 49.2.23-31 [8], `versionCode 84922318`), from
MindTheGapps' TV GApps, `vendor_gapps_tv` commit
`378d98196fe90f7ba5da6ef925ebc23d5434e030` (branch `baklava`,
`arm64/proprietary/product/priv-app/Tubesky/Tubesky.apk`).

The phone Play Store that MindTheGapps ships refuses to run on a TV, so Ika's
TV mode runs this one instead: PackageManager scans it only in TV mode, and
the phone build only in desktop mode
(`patches/frameworks-base-ika-mode.patch`). MindTheGapps has no TV
build for x86-64, so x86-64 images carry this arm64 build too, and run its
native code through the ARM native bridge (`libndk_translation`); without the
bridge, x86-64 images keep the phone Play Store in both modes.

The APK keeps its native libraries (`arm64-v8a`) uncompressed, so it installs
as is (`preprocessed`). It carries Google's signing certificate
`7ce83c1b71f3d572fed04c8d40c5cb10ff75e6d87d9df6fbd53f0468c2905053`.
`privapp-permissions-ika-tubesky.xml` grants the privileged permissions it
requests that the phone Play Store's allowlist does not.
