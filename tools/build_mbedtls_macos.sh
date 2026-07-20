#!/usr/bin/env bash
#
# Build MbedTLS (static) for macOS and install it into
#   macos/third_party/mbedtls-macos
# which macos/flutter_libdatachannel.podspec's native build points
# find_package(MbedTLS) at. macOS ships no OpenSSL dev headers we want to depend
# on, so libdatachannel (USE_MBEDTLS) and its bundled libSRTP need this MbedTLS
# (built with MBEDTLS_SSL_DTLS_SRTP) before the plugin's macOS build can succeed.
# This is the macOS counterpart of tools/build_mbedtls_ios.sh (host build — no
# cross-compile, so it is simpler).
#
# Usage:
#   [MBEDTLS_VERSION=3.6.2] [MACOSX_DEPLOYMENT_TARGET=10.14] \
#   [MACOS_ARCHS=arm64] [CMAKE=/path/to/cmake] \
#     ./tools/build_mbedtls_macos.sh
#
# MACOS_ARCHS defaults to the host arch (arm64). Pass "arm64;x86_64" for a
# universal build. Requires macOS + Xcode + CMake >= 3.14.
set -euo pipefail

MBEDTLS_VERSION="${MBEDTLS_VERSION:-3.6.2}"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.14}"
CMAKE_BIN="${CMAKE:-cmake}"
ARCHS_IN="${MACOS_ARCHS:-arm64}"

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading MbedTLS $MBEDTLS_VERSION ..."
curl -fsSL -o "$WORK/mbedtls.tar.bz2" \
  "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$MBEDTLS_VERSION/mbedtls-$MBEDTLS_VERSION.tar.bz2"
tar xjf "$WORK/mbedtls.tar.bz2" -C "$WORK"
SRC="$WORK/mbedtls-$MBEDTLS_VERSION"

# libdatachannel's media path (DTLS-SRTP key extraction) needs MbedTLS built
# with MBEDTLS_SSL_DTLS_SRTP, which the default config leaves off.
python3 "$SRC/scripts/config.py" -f "$SRC/include/mbedtls/mbedtls_config.h" \
  set MBEDTLS_SSL_DTLS_SRTP

GEN_ARGS=()
if [ -n "${CMAKE_MAKE_PROGRAM:-}" ]; then
  GEN_ARGS=(-G Ninja -DCMAKE_MAKE_PROGRAM="$CMAKE_MAKE_PROGRAM")
fi

PREFIX="$PLUGIN_DIR/macos/third_party/mbedtls-macos"
echo "=== Building MbedTLS for macOS ($ARCHS_IN) -> $PREFIX ==="
rm -rf "$PREFIX"
"$CMAKE_BIN" -S "$SRC" -B "$WORK/build" ${GEN_ARGS[@]+"${GEN_ARGS[@]}"} \
  -DCMAKE_OSX_ARCHITECTURES="$ARCHS_IN" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DGEN_FILES=OFF -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
  -DUSE_STATIC_MBEDTLS_LIBRARY=ON -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
"$CMAKE_BIN" --build "$WORK/build" --target install -j

echo "Done. Installed to $PREFIX"
cfg="$PREFIX/include/mbedtls/mbedtls_config.h"
if grep -q '^#define MBEDTLS_SSL_DTLS_SRTP' "$cfg"; then
  echo "  MBEDTLS_SSL_DTLS_SRTP: ON"
else
  echo "  WARNING: MBEDTLS_SSL_DTLS_SRTP not set in $cfg" >&2
fi
