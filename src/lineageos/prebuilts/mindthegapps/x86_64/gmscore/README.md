# Google Play services for x86-64

This directory contains the Google Play-delivered x86/x86-64 package set for
`com.google.android.gms` 26.26.34 (`versionCode 262634038`). The base, feature,
English, and density APKs were selected by Google Play for the Ika x86-64
Android 16 virtual device on 2026-07-15. Deliveries were captured at physical
120, 168, 240, 320, 480, and 640 DPI for the identical `260800` variant; every
APK shared by the deliveries was byte-identical.

The ldpi, mdpi, hdpi, xhdpi, xxhdpi, and xxxhdpi configuration splits are
installed together so Ika can select native-density Play services assets as its
display density changes.

All APKs carry Google's current signing certificate
`5f2391277b1dbd489000467e4c2fa6af802430080457dce2f618992e9dfb5402`.
The base APK contains native `x86` and `x86_64` libraries. Dex metadata files
from the install session are intentionally omitted because they are optional
optimization artifacts and are not required to install or boot the package.
