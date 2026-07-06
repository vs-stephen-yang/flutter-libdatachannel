cmake_minimum_required(VERSION 3.14)
project(flutter_libdatachannel_android LANGUAGES CXX C)

set(NO_WEBSOCKET ON CACHE BOOL "" FORCE)
set(NO_EXAMPLES ON CACHE BOOL "" FORCE)
set(NO_TESTS ON CACHE BOOL "" FORCE)
set(USE_MBEDTLS ON CACHE BOOL "" FORCE)
# Don't build libSRTP's bundled test executables — they link only libsrtp2 (no
# MbedTLS) and fail with undefined mbedtls_* symbols on Android.
set(LIBSRTP_TEST_APPS OFF CACHE BOOL "" FORCE)

# Android has no system OpenSSL, so libdatachannel is built with MbedTLS. Point
# find_package(MbedTLS) (used by both libdatachannel and its bundled libsrtp) at
# the per-ABI MbedTLS we cross-compiled into third_party/mbedtls-android/<abi>.
# Build it with tools/build_mbedtls_android.sh before building the plugin.
set(MBEDTLS_ANDROID_PREFIX
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/mbedtls-android/${ANDROID_ABI}")
if(NOT EXISTS "${MBEDTLS_ANDROID_PREFIX}/include/mbedtls/build_info.h")
  message(FATAL_ERROR
    "MbedTLS for ABI '${ANDROID_ABI}' not found at ${MBEDTLS_ANDROID_PREFIX}. "
    "Run tools/build_mbedtls_android.sh to cross-compile it first.")
endif()
set(CMAKE_PREFIX_PATH "${MBEDTLS_ANDROID_PREFIX}" ${CMAKE_PREFIX_PATH})
# The NDK toolchain sets CMAKE_FIND_ROOT_PATH_MODE_* to ONLY, so find_package()
# would otherwise only search the NDK sysroot and ignore CMAKE_PREFIX_PATH.
# Add our MbedTLS prefix to the find-root so libdatachannel and libsrtp locate it.
list(APPEND CMAKE_FIND_ROOT_PATH "${MBEDTLS_ANDROID_PREFIX}")

add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libdatachannel"
                 "${CMAKE_CURRENT_BINARY_DIR}/libdatachannel" EXCLUDE_FROM_ALL)

add_library(flutter_libdatachannel_native SHARED
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/flutter_libdatachannel.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/../src/ldc_dump.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/main/jni/flutter_libdatachannel_jni.cpp"
)

target_include_directories(flutter_libdatachannel_native PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/../src"
    "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libdatachannel/include"
)

target_link_libraries(flutter_libdatachannel_native PRIVATE
    datachannel-static
    # libdatachannel/libsrtp reference MbedTLS crypto primitives; link the static
    # libs explicitly (TLS → x509 → crypto order) so the final .so resolves them.
    "${MBEDTLS_ANDROID_PREFIX}/lib/libmbedtls.a"
    "${MBEDTLS_ANDROID_PREFIX}/lib/libmbedx509.a"
    "${MBEDTLS_ANDROID_PREFIX}/lib/libmbedcrypto.a"
    log
)

target_compile_definitions(flutter_libdatachannel_native PRIVATE RTC_STATIC)
