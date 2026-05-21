#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRCPY_DIR="$ROOT_DIR/scrcpy"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/out/build-scrcpy-server}"
ANDROID_CACHE_DIR="${ANDROID_CACHE_DIR:-$ROOT_DIR/out/android-sdk-cache}"
JDK_DIR="${JDK_DIR:-$ROOT_DIR/toolchain/jdk-17.0.18+8}"

ANDROID_PLATFORM="${ANDROID_PLATFORM:-36}"
ANDROID_PLATFORM_REV="${ANDROID_PLATFORM_REV:-02}"
ANDROID_BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-36.0.0}"
ANDROID_BUILD_TOOLS_ZIP_BASENAME="${ANDROID_BUILD_TOOLS_ZIP_BASENAME:-build-tools_r36_linux.zip}"

PLATFORM_ZIP="${ANDROID_CACHE_DIR}/platform-${ANDROID_PLATFORM}_r${ANDROID_PLATFORM_REV}.zip"
BUILD_TOOLS_ZIP="${ANDROID_CACHE_DIR}/${ANDROID_BUILD_TOOLS_ZIP_BASENAME}"
PLATFORM_ZIP_URL="${PLATFORM_ZIP_URL:-https://dl.google.com/android/repository/platform-${ANDROID_PLATFORM}_r${ANDROID_PLATFORM_REV}.zip}"
BUILD_TOOLS_ZIP_URL="${BUILD_TOOLS_ZIP_URL:-https://dl.google.com/android/repository/${ANDROID_BUILD_TOOLS_ZIP_BASENAME}}"

ANDROID_JAR="${BUILD_DIR}/sdk/platforms/android-${ANDROID_PLATFORM}/android.jar"
LAMBDA_JAR="${BUILD_DIR}/sdk/build-tools/${ANDROID_BUILD_TOOLS}/core-lambda-stubs.jar"
D8_JAR="${BUILD_DIR}/sdk/build-tools/${ANDROID_BUILD_TOOLS}/lib/d8.jar"

SCRCPY_VERSION_NAME="${SCRCPY_VERSION_NAME:-}"
if [[ -z "${SCRCPY_VERSION_NAME}" ]]; then
    SCRCPY_VERSION_NAME="$(sed -n "s/.*version: '\\([^']*\\)'.*/\\1/p" "${SCRCPY_DIR}/meson.build" | head -n1)"
fi
if [[ -z "${SCRCPY_VERSION_NAME}" ]]; then
    SCRCPY_VERSION_NAME="3.3.4"
fi

JAVA=""
JAVAC=""
JAR=""

CLASSES_DIR="$BUILD_DIR/classes"
GEN_DIR="$BUILD_DIR/gen"
SERVER_BINARY="$BUILD_DIR/scrcpy-server"

usage() {
    cat <<'EOF'
Build scrcpy-server on aarch64 Linux without relying on x86 Android host tools.

Required inputs:
  - A JDK (either under toolchain/jdk-17.0.18+8 or from PATH)
  - Android platform/build-tools zip caches (downloaded automatically if missing)

Optional env vars:
  BUILD_DIR
  ANDROID_CACHE_DIR
  JDK_DIR
  ANDROID_PLATFORM
  ANDROID_PLATFORM_REV
  ANDROID_BUILD_TOOLS
  ANDROID_BUILD_TOOLS_ZIP_BASENAME
  PLATFORM_ZIP_URL
  BUILD_TOOLS_ZIP_URL
  SCRCPY_VERSION_NAME
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

resolve_java_tools() {
    if [[ -x "${JDK_DIR}/bin/java" && -x "${JDK_DIR}/bin/javac" && -x "${JDK_DIR}/bin/jar" ]]; then
        JAVA="${JDK_DIR}/bin/java"
        JAVAC="${JDK_DIR}/bin/javac"
        JAR="${JDK_DIR}/bin/jar"
        return
    fi

    JAVA="$(command -v java || true)"
    JAVAC="$(command -v javac || true)"
    JAR="$(command -v jar || true)"
    if [[ -z "${JAVA}" || -z "${JAVAC}" || -z "${JAR}" ]]; then
        echo "Missing Java tools; install a JDK or set JDK_DIR" >&2
        exit 1
    fi
}

fetch_if_missing() {
    local path="$1"
    local url="$2"
    if [[ -f "${path}" ]]; then
        return
    fi

    mkdir -p "$(dirname "${path}")"
    echo "Downloading $(basename "${path}") from ${url}"
    curl -fL --retry 3 -o "${path}" "${url}"
}

resolve_java_tools
echo "Preparing scrcpy-server build in ${BUILD_DIR}"
fetch_if_missing "${PLATFORM_ZIP}" "${PLATFORM_ZIP_URL}"
fetch_if_missing "${BUILD_TOOLS_ZIP}" "${BUILD_TOOLS_ZIP_URL}"

rm -rf "$CLASSES_DIR" "$GEN_DIR" "$SERVER_BINARY" "$BUILD_DIR/classes.zip" "$BUILD_DIR/sdk"
mkdir -p "$CLASSES_DIR" "$GEN_DIR/com/genymobile/scrcpy" "$GEN_DIR/android/view" \
    "$BUILD_DIR/sdk/platforms/android-${ANDROID_PLATFORM}" \
    "$BUILD_DIR/sdk/build-tools/${ANDROID_BUILD_TOOLS}/lib"

if ! unzip -oj "$PLATFORM_ZIP" "android-${ANDROID_PLATFORM}/android.jar" -d "$BUILD_DIR/sdk/platforms/android-${ANDROID_PLATFORM}" >/dev/null; then
    echo "Could not extract android.jar from ${PLATFORM_ZIP}" >&2
    exit 1
fi

if ! unzip -oj "$BUILD_TOOLS_ZIP" 'android-16/core-lambda-stubs.jar' -d "$BUILD_DIR/sdk/build-tools/${ANDROID_BUILD_TOOLS}" >/dev/null; then
    echo "Could not extract core-lambda-stubs.jar from ${BUILD_TOOLS_ZIP}" >&2
    exit 1
fi

if ! unzip -oj "$BUILD_TOOLS_ZIP" 'android-16/lib/d8.jar' -d "$BUILD_DIR/sdk/build-tools/${ANDROID_BUILD_TOOLS}/lib" >/dev/null; then
    echo "Could not extract d8.jar from ${BUILD_TOOLS_ZIP}" >&2
    exit 1
fi

for path in "$JAVA" "$JAVAC" "$JAR" "$ANDROID_JAR" "$LAMBDA_JAR" "$D8_JAR"; do
    if [[ ! -e "$path" ]]; then
        echo "Missing required input after setup: $path" >&2
        exit 1
    fi
done

cat > "$GEN_DIR/com/genymobile/scrcpy/BuildConfig.java" <<EOF
package com.genymobile.scrcpy;

public final class BuildConfig {
    public static final boolean DEBUG = false;
    public static final String VERSION_NAME = "${SCRCPY_VERSION_NAME}";

    private BuildConfig() {
    }
}
EOF

cat > "$GEN_DIR/android/view/IDisplayWindowListener.java" <<'EOF'
package android.view;

import android.content.res.Configuration;
import android.os.Binder;
import android.os.IBinder;
import android.os.IInterface;
import android.os.Parcel;
import android.os.RemoteException;

public interface IDisplayWindowListener extends IInterface {
    void onDisplayAdded(int displayId) throws RemoteException;

    void onDisplayConfigurationChanged(int displayId, Configuration newConfig) throws RemoteException;

    void onDisplayRemoved(int displayId) throws RemoteException;

    abstract class Stub extends Binder implements IDisplayWindowListener {
        public Stub() {
        }

        public static IDisplayWindowListener asInterface(IBinder binder) {
            throw new UnsupportedOperationException("compile-time stub only");
        }

        @Override
        public IBinder asBinder() {
            return this;
        }

        @Override
        public boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
            return super.onTransact(code, data, reply, flags);
        }
    }
}
EOF

mapfile -t SRC_FILES < <(find \
    "$SCRCPY_DIR/server/src/main/java/android" \
    "$SCRCPY_DIR/server/src/main/java/com/genymobile/scrcpy" \
    "$GEN_DIR" \
    -name '*.java' | sort)

echo "Compiling scrcpy-server Java sources"
"$JAVAC" -encoding UTF-8 \
    -bootclasspath "$ANDROID_JAR" \
    -cp "$LAMBDA_JAR:$GEN_DIR" \
    -d "$CLASSES_DIR" \
    -Xlint:-options \
    -source 8 \
    -target 8 \
    "${SRC_FILES[@]}"

mapfile -t CLASS_FILES < <(find "$CLASSES_DIR" -name '*.class' | sort)

echo "Dexing compiled classes"
"$JAVA" -cp "$D8_JAR" com.android.tools.r8.D8 \
    --lib "$ANDROID_JAR" \
    --min-api 21 \
    --output "$BUILD_DIR/classes.zip" \
    "${CLASS_FILES[@]}"

mv "$BUILD_DIR/classes.zip" "$SERVER_BINARY"

if "$JAR" tf "$SERVER_BINARY" | grep -qx 'classes.dex'; then
    echo "Built scrcpy-server: $SERVER_BINARY"
    echo "Verified server archive contains classes.dex"
else
    echo "Built scrcpy-server is missing classes.dex: $SERVER_BINARY" >&2
    exit 1
fi
