#!/system/bin/sh
# Run the arm64 guest vulkaninfo under ndk_translation (Berberis). Diffing
# this against native `vulkaninfo` separates gfxstream driver issues from
# translation issues. The runner resolves argv[1] AND argv[2] as paths
# (binfmt_misc "P" convention), so the guest path is passed twice.
exec /system/bin/ndk_translation_program_runner_binfmt_misc_arm64 \
    /system_ext/bin/arm64/vulkaninfo /system_ext/bin/arm64/vulkaninfo "$@"
