#!/usr/bin/env bash
#
# Cross-compile MbedTLS (static) for Android and install it per-ABI into
#   android/third_party/mbedtls-android/<abi>
# which android/CMakeLists.txt points find_package(MbedTLS) at. Android has no
# system OpenSSL, so libdatachannel (USE_MBEDTLS) and its bundled libsrtp need
# this before the plugin's Android build can succeed.
#
# Usage:
#   ANDROID_NDK=/path/to/ndk [MBEDTLS_VERSION=3.6.2] \
#     ./tools/build_mbedtls_android.sh [abi ...]
#
# Defaults to all ABIs the plugin ships (arm64-v8a armeabi-v7a x86_64).
# Requires cmake + a generator (Ninja recommended). On Windows, the ninja that
# ships with the Android SDK cmake works; pass it via CMAKE_MAKE_PROGRAM if the
# ninja on PATH is not a native Windows binary.
set -euo pipefail

MBEDTLS_VERSION="${MBEDTLS_VERSION:-3.6.2}"
: "${ANDROID_NDK:?set ANDROID_NDK to your NDK path (e.g. \$ANDROID_SDK/ndk/26.1.10909125)}"

ABIS=("$@")
if [ ${#ABIS[@]} -eq 0 ]; then
  ABIS=(arm64-v8a armeabi-v7a x86_64)
fi

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN="$ANDROID_NDK/build/cmake/android.toolchain.cmake"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading MbedTLS $MBEDTLS_VERSION ..."
curl -fsSL -o "$WORK/mbedtls.tar.bz2" \
  "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$MBEDTLS_VERSION/mbedtls-$MBEDTLS_VERSION.tar.bz2"
tar xjf "$WORK/mbedtls.tar.bz2" -C "$WORK"
SRC="$WORK/mbedtls-$MBEDTLS_VERSION"

# libdatachannel's media path (DTLS-SRTP key extraction) needs MbedTLS built
# with MBEDTLS_SSL_DTLS_SRTP, which the default config leaves off.
python "$SRC/scripts/config.py" -f "$SRC/include/mbedtls/mbedtls_config.h" \
  set MBEDTLS_SSL_DTLS_SRTP

GEN_ARGS=()
if [ -n "${CMAKE_MAKE_PROGRAM:-}" ]; then
  GEN_ARGS=(-G Ninja -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM")
fi

for ABI in "${ABIS[@]}"; do
  PREFIX="$PLUGIN_DIR/android/third_party/mbedtls-android/$ABI"
  echo "=== Building MbedTLS for $ABI -> $PREFIX ==="
  cmake -S "$SRC" -B "$WORK/build-$ABI" "${GEN_ARGS[@]}" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DANDROID_ABI="$ABI" -DANDROID_PLATFORM=android-21 \
    -DGEN_FILES=OFF -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
    -DUSE_STATIC_MBEDTLS_LIBRARY=ON -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
  cmake --build "$WORK/build-$ABI" --target install
done

echo "Done. Installed ABIs: ${ABIS[*]}"
