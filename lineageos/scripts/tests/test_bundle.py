#!/usr/bin/env python3

from pathlib import Path
import subprocess
import tempfile
import unittest


BUNDLE_SH = Path(__file__).resolve().parents[1] / "lib" / "bundle.sh"


class BundleTest(unittest.TestCase):
    def test_android_16_vulkan_cts_outputs_use_host_apk_and_product_binary(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            product_out = root / "out/target/product/ika_x86_64"
            apk = (
                root
                / "out/host/linux-x86/testcases/CtsDeqpTestCases"
                / "com.drawelements.deqp.apk"
            )
            binary = (
                product_out
                / "testcases/deqp-binary/x86_64/deqp-binary64"
            )
            apk.parent.mkdir(parents=True)
            binary.parent.mkdir(parents=True)
            apk.write_bytes(b"apk")
            binary.write_bytes(b"binary")
            binary.chmod(0o755)

            script = f"""
set -e
workspace={root!s}
source {BUNDLE_SH!s}
vulkan_test_outputs_complete {product_out!s} linux-x86
! vulkan_test_outputs_complete {product_out!s} linux-arm64
"""
            subprocess.run(["bash", "-c", script], check=True)


if __name__ == "__main__":
    unittest.main()
