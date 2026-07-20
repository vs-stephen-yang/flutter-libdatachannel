#!/usr/bin/env bash
#
# Build libdatachannel + its bundled deps (libjuice / libSRTP / usrsctp) + this
# plugin's C bridge (src/*.cpp) into a single static archive for macOS:
#   build/macos/<sdk>-<config>/libflutter_libdatachannel_native.a
# linked against the MbedTLS prebuilt (with MBEDTLS_SSL_DTLS_SRTP) produced by
# tools/build_mbedtls_macos.sh. This is the macOS counterpart of
# tools/build_ios_native.sh (host build — no cross-compile).
#
# Invoked by macos/flutter_libdatachannel.podspec's build script phase, which
# runs inside Xcode and exports PLATFORM_NAME / ARCHS / CONFIGURATION /
# MACOSX_DEPLOYMENT_TARGET. All are defaulted so the script also runs standalone:
#   ./tools/build_macos_native.sh                 # macosx, host arch, Release
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${PLATFORM_NAME:-macosx}"
CONFIG="${CONFIGURATION:-Release}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.14}"
CMAKE_BIN="${CMAKE:-cmake}"

# Xcode ARCHS is space-separated; CMake wants ';'. Default to host arch.
if [ -n "${ARCHS:-}" ]; then
  OSX_ARCHS="$(echo "$ARCHS" | tr ' ' ';')"
else
  OSX_ARCHS="$(uname -m)"
fi

MBEDTLS_PREFIX="$PLUGIN_DIR/macos/third_party/mbedtls-macos"
if [ ! -f "$MBEDTLS_PREFIX/include/mbedtls/build_info.h" ]; then
  echo "error: MbedTLS for macOS not found at $MBEDTLS_PREFIX." >&2
  echo "       Build it first:  tools/build_mbedtls_macos.sh" >&2
  exit 1
fi

LDC_SRC="$PLUGIN_DIR/third_party/libdatachannel"
BUILD_DIR="$PLUGIN_DIR/build/macos/$SDK-$CONFIG"
OUT_LIB="$BUILD_DIR/libflutter_libdatachannel_native.a"

GEN_ARGS=()
if command -v ninja >/dev/null 2>&1; then GEN_ARGS=(-G Ninja); fi

echo "==> Configuring libdatachannel (macOS / $OSX_ARCHS / $CONFIG)"
"$CMAKE_BIN" -S "$LDC_SRC" -B "$BUILD_DIR" ${GEN_ARGS[@]+"${GEN_ARGS[@]}"} \
  -DCMAKE_BUILD_TYPE="$CONFIG" \
  -DNO_WEBSOCKET=ON -DNO_EXAMPLES=ON -DNO_TESTS=ON \
  -DUSE_MBEDTLS=ON \
  -DLIBSRTP_TEST_APPS=OFF \
  -DCMAKE_OSX_ARCHITECTURES="$OSX_ARCHS" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_PREFIX_PATH="$MBEDTLS_PREFIX" \
  -DCMAKE_FIND_ROOT_PATH="$MBEDTLS_PREFIX" \
  -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
  -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH

echo "==> Building datachannel-static + deps"
"$CMAKE_BIN" --build "$BUILD_DIR" --target datachannel-static -j

echo "==> Compiling plugin C bridge (src/) for macOS"
BRIDGE_OBJ="$BUILD_DIR/bridge"; mkdir -p "$BRIDGE_OBJ"
ARCH_FLAGS=()
IFS=';' read -ra _archs <<< "$OSX_ARCHS"
for a in "${_archs[@]}"; do ARCH_FLAGS+=(-arch "$a"); done
for f in flutter_libdatachannel ldc_dump; do
  xcrun --sdk macosx clang++ -c "${ARCH_FLAGS[@]}" \
    -mmacosx-version-min="$DEPLOYMENT_TARGET" \
    -std=gnu++17 -fvisibility=default -DRTC_STATIC \
    -I "$PLUGIN_DIR/src" -I "$LDC_SRC/include" \
    "$PLUGIN_DIR/src/$f.cpp" -o "$BRIDGE_OBJ/$f.o"
done

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
