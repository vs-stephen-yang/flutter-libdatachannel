#!/usr/bin/env bash
#
# Cross-compile MbedTLS (static) for iOS and install it per-SDK into
#   ios/third_party/mbedtls-ios/<sdk>            (sdk = iphoneos | iphonesimulator)
# which ios/flutter_libdatachannel.podspec points find_package(MbedTLS) at.
# iOS has no system OpenSSL we want to depend on, so libdatachannel (USE_MBEDTLS)
# and its bundled libSRTP need this MbedTLS before the plugin's iOS build can
# succeed. This is the iOS counterpart of tools/build_mbedtls_android.sh.
#
# Usage:
#   [MBEDTLS_VERSION=3.6.2] [IOS_DEPLOYMENT_TARGET=12.0] \
#   [CMAKE=/path/to/cmake] [CMAKE_MAKE_PROGRAM=/path/to/ninja] \
#     ./tools/build_mbedtls_ios.sh [iphoneos|iphonesimulator ...]
#
# Defaults to the device SDK (iphoneos, arm64) — the Firebase Test Lab target,
# which runs on real devices. Pass "iphonesimulator" too for local simulator
# runs. Requires macOS + Xcode (for the iOS SDK) and CMake >= 3.14 (native iOS
# cross-compile support). Ninja optional (pass CMAKE_MAKE_PROGRAM to use it).
set -euo pipefail

MBEDTLS_VERSION="${MBEDTLS_VERSION:-3.6.2}"
DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-12.0}"
CMAKE_BIN="${CMAKE:-cmake}"

SDKS=("$@")
if [ ${#SDKS[@]} -eq 0 ]; then
  SDKS=(iphoneos)
fi

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

sdk_archs() {
  case "$1" in
    iphoneos) echo "arm64" ;;
    iphonesimulator) echo "arm64;x86_64" ;;
    *) echo "unknown SDK: $1 (expected iphoneos or iphonesimulator)" >&2; exit 1 ;;
  esac
}

for SDK in "${SDKS[@]}"; do
  ARCHS="$(sdk_archs "$SDK")"
  PREFIX="$PLUGIN_DIR/ios/third_party/mbedtls-ios/$SDK"
  echo "=== Building MbedTLS for $SDK ($ARCHS) -> $PREFIX ==="
  rm -rf "$PREFIX"
  "$CMAKE_BIN" -S "$SRC" -B "$WORK/build-$SDK" "${GEN_ARGS[@]}" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DGEN_FILES=OFF -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
    -DUSE_STATIC_MBEDTLS_LIBRARY=ON -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
  "$CMAKE_BIN" --build "$WORK/build-$SDK" --target install
done

echo "Done. Installed SDKs: ${SDKS[*]}"
# Sanity: confirm DTLS-SRTP is compiled into the installed config (WebRTC needs it).
for SDK in "${SDKS[@]}"; do
  cfg="$PLUGIN_DIR/ios/third_party/mbedtls-ios/$SDK/include/mbedtls/mbedtls_config.h"
  if grep -q '^#define MBEDTLS_SSL_DTLS_SRTP' "$cfg"; then
    echo "  [$SDK] MBEDTLS_SSL_DTLS_SRTP: ON"
  else
    echo "  [$SDK] WARNING: MBEDTLS_SSL_DTLS_SRTP not set in $cfg" >&2
  fi
done
