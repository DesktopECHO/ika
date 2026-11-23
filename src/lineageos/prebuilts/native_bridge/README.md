# Native Bridge Prebuilts

This directory is populated by `scripts/update_native_bridge_prebuilts.py`
when the x86-64 ROM is built with Google's translator
(`X86_ARM_TRANSLATOR=ndk_translation`). The default translator, Digitalis, is
built from source and needs nothing here.

The generated files are not committed because `libndk_translation.so` and its
runtime payload come from Google's Android SDK system images. The build helper
downloads the SDK package, extracts the native bridge payload into
`prebuilts/native_bridge/system`, and the x86-64 product imports it at build
time.
