#!/usr/bin/env bash
#
# Build libdatachannel + its bundled deps (libjuice / libSRTP / usrsctp) + this
# plugin's C bridge (src/*.cpp) into a single static archive for iOS:
#   build/ios/<sdk>-<config>/libflutter_libdatachannel_native.a
# linked against the MbedTLS prebuilt (with MBEDTLS_SSL_DTLS_SRTP) produced by
# tools/build_mbedtls_ios.sh. This is the iOS counterpart of android/CMakeLists.txt
# + build_mbedtls_android.sh.
#
# Invoked by ios/flutter_libdatachannel.podspec's build script phase, which runs
# inside Xcode and exports PLATFORM_NAME / ARCHS / CONFIGURATION / *_DEPLOYMENT_TARGET.
# All are also defaulted so the script can be run/tested standalone:
#   ./tools/build_ios_native.sh              # device (iphoneos, arm64, Release)
#   PLATFORM_NAME=iphonesimulator ./tools/build_ios_native.sh
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${PLATFORM_NAME:-iphoneos}"
CONFIG="${CONFIGURATION:-Release}"
DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-12.0}"
CMAKE_BIN="${CMAKE:-cmake}"

# Xcode ARCHS is space-separated; CMake wants ';'. Default per SDK.
if [ -n "${ARCHS:-}" ]; then
  OSX_ARCHS="$(echo "$ARCHS" | tr ' ' ';')"
elif [ "$SDK" = "iphonesimulator" ]; then
  OSX_ARCHS="arm64;x86_64"
else
  OSX_ARCHS="arm64"
fi

MBEDTLS_PREFIX="$PLUGIN_DIR/ios/third_party/mbedtls-ios/$SDK"
if [ ! -f "$MBEDTLS_PREFIX/include/mbedtls/build_info.h" ]; then
  echo "error: MbedTLS for '$SDK' not found at $MBEDTLS_PREFIX." >&2
  echo "       Cross-compile it first:  tools/build_mbedtls_ios.sh $SDK" >&2
  exit 1
fi

LDC_SRC="$PLUGIN_DIR/third_party/libdatachannel"
BUILD_DIR="$PLUGIN_DIR/build/ios/$SDK-$CONFIG"
OUT_LIB="$BUILD_DIR/libflutter_libdatachannel_native.a"

GEN_ARGS=()
if command -v ninja >/dev/null 2>&1; then GEN_ARGS=(-G Ninja); fi

# libdatachannel + its bundled deps + libSRTP all resolve MbedTLS via
# find_package(MbedTLS 3). Under an iOS toolchain CMake restricts find_*() to the
# sysroot, so add the MbedTLS prefix to the find-root and open the find modes to
# BOTH (same problem the Android NDK toolchain has — see android/CMakeLists.txt).
echo "==> Configuring libdatachannel ($SDK / $OSX_ARCHS / $CONFIG)"
"$CMAKE_BIN" -S "$LDC_SRC" -B "$BUILD_DIR" "${GEN_ARGS[@]}" \
  -DCMAKE_BUILD_TYPE="$CONFIG" \
  -DNO_WEBSOCKET=ON -DNO_EXAMPLES=ON -DNO_TESTS=ON \
  -DUSE_MBEDTLS=ON \
  -DLIBSRTP_TEST_APPS=OFF \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_OSX_ARCHITECTURES="$OSX_ARCHS" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_PREFIX_PATH="$MBEDTLS_PREFIX" \
  -DCMAKE_FIND_ROOT_PATH="$MBEDTLS_PREFIX" \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH

echo "==> Building datachannel-static + deps"
"$CMAKE_BIN" --build "$BUILD_DIR" --target datachannel-static

echo "==> Compiling plugin C bridge (src/) for $SDK"
BRIDGE_OBJ="$BUILD_DIR/bridge"; mkdir -p "$BRIDGE_OBJ"
ARCH_FLAGS=()
IFS=';' read -ra _archs <<< "$OSX_ARCHS"
for a in "${_archs[@]}"; do ARCH_FLAGS+=(-arch "$a"); done
case "$SDK" in
  iphonesimulator) MINV_FLAG="-mios-simulator-version-min=$DEPLOYMENT_TARGET" ;;
  *)               MINV_FLAG="-miphoneos-version-min=$DEPLOYMENT_TARGET" ;;
esac
for f in flutter_libdatachannel ldc_dump; do
  xcrun --sdk "$SDK" clang++ -c "${ARCH_FLAGS[@]}" "$MINV_FLAG" \
    -std=gnu++17 -fvisibility=default -DRTC_STATIC \
    -I "$PLUGIN_DIR/src" -I "$LDC_SRC/include" \
    "$PLUGIN_DIR/src/$f.cpp" -o "$BRIDGE_OBJ/$f.o"
done

# Merge the bridge objects with libdatachannel-static and every static dep
# (including the three MbedTLS archives, in TLS -> x509 -> crypto order) into one
# self-contained archive the podspec links. libtool warns about duplicate member
# names in libdatachannel-static; harmless.
echo "==> Combining -> $OUT_LIB"
xcrun libtool -static -o "$OUT_LIB" \
  "$BRIDGE_OBJ/flutter_libdatachannel.o" "$BRIDGE_OBJ/ldc_dump.o" \
  "$BUILD_DIR/libdatachannel-static.a" \
  "$BUILD_DIR/deps/libjuice/libjuice-static.a" \
  "$BUILD_DIR/deps/libsrtp/libsrtp2.a" \
  "$BUILD_DIR/deps/usrsctp/usrsctplib/libusrsctp.a" \
  "$MBEDTLS_PREFIX/lib/libmbedtls.a" \
  "$MBEDTLS_PREFIX/lib/libmbedx509.a" \
  "$MBEDTLS_PREFIX/lib/libmbedcrypto.a" 2>&1 | grep -v "duplicate member name" || true

echo "==> Done: $OUT_LIB"
