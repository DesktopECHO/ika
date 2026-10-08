#!/usr/bin/env bash
set -ex
. $(dirname ${BASH_SOURCE[0]})/_init
process_args "$@"

VERSION=3.4.18
URL="https://github.com/libsdl-org/SDL/archive/refs/tags/release-$VERSION.tar.gz"
SHA256SUM=c4b08b950bd29d83caae0ab8d884298d27046a9d30700fb42841c50992665c90

PROJECT_DIR="sdl-$VERSION"
FILENAME="$PROJECT_DIR.tar.gz"

cd "$SOURCES_DIR"

if [[ -d "$PROJECT_DIR" ]]
then
    echo "$PWD/$PROJECT_DIR" found
else
    get_file "$URL" "$FILENAME" "$SHA256SUM"
    tar xf "$FILENAME"  # First level directory is "SDL-release-$VERSION"
    mv "SDL-release-$VERSION" "$PROJECT_DIR"
fi

mkdir -p "$BUILD_DIR/$PROJECT_DIR"
cd "$BUILD_DIR/$PROJECT_DIR"

export CFLAGS='-O2'
if [[ "$HOST" == linux && "$BUILD_TYPE" == native ]]
then
    # RPM-family toolchains enable PIE at link time; compile feature probes as
    # PIE too, otherwise symbol checks can fail with absolute-relocation errors.
    CFLAGS+=' -fPIE'
fi
export CFLAGS
export CXXFLAGS="$CFLAGS"

mkdir -p "$DIRNAME"
cd "$DIRNAME"

conf=(
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR/$DIRNAME"
    # The other dependencies install to lib, where the builds look for them;
    # CMake would pick lib64 on Fedora.
    -DCMAKE_INSTALL_LIBDIR=lib
    -DSDL_TESTS=OFF
)

if [[ "$HOST" == linux ]]
then
    conf+=(
        -DSDL_WAYLAND=ON
        -DSDL_X11=ON
        # scrcpy does not synthesize X11 input through XTEST. Disabling this
        # optional SDL backend avoids a libXtst build dependency.
        -DSDL_X11_XTEST=OFF
        # Link the libusb that libusb.sh builds into this prefix (build it
        # first) instead of loading the host's at runtime, so SDL is the same
        # whether or not the host has libusb-1.0-0-dev.
        -DSDL_HIDAPI_LIBUSB=ON
        -DSDL_HIDAPI_LIBUSB_SHARED=OFF
    )
    export PKG_CONFIG_PATH="$INSTALL_DIR/$DIRNAME/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi

if [[ "$LINK_TYPE" == static ]]
then
    conf+=(
        -DBUILD_SHARED_LIBS=OFF
    )
else
    conf+=(
        -DBUILD_SHARED_LIBS=ON
    )
fi

if [[ "$BUILD_TYPE" == cross ]]
then
    if [[ "$HOST" = win32 ]]
    then
        TOOLCHAIN_FILENAME="cmake-toolchain-mingw64-i686.cmake"
    elif [[ "$HOST" = win64 ]]
    then
        TOOLCHAIN_FILENAME="cmake-toolchain-mingw64-x86_64.cmake"
    else
        echo "Unsupported cross-build to host: $HOST" >&2
        exit 1
    fi

    conf+=(
        -DCMAKE_TOOLCHAIN_FILE="$SOURCES_DIR/$PROJECT_DIR/build-scripts/$TOOLCHAIN_FILENAME"
    )
fi

# Configure from scratch on every invocation. CMake keeps feature-check results
# in its cache, so a probe that failed once (as every libc check did before
# -fPIE, under RPM's hardened linker flags) would stay failed, and SDL would
# ignore the environment (SDL_APP_ID included) and its libc functions.
cmake --fresh "$SOURCES_DIR/$PROJECT_DIR" "${conf[@]}"

cmake --build .
cmake --install .
