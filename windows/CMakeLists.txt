# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "flutter_libdatachannel")
project(${PROJECT_NAME} LANGUAGES CXX C)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "flutter_libdatachannel_plugin")

# TLS backend: Windows ships no system OpenSSL (libdatachannel's default), so use
# MbedTLS like the other platforms. This also flips libSRTP to its MbedTLS crypto
# engine (libdatachannel sets ENABLE_MBEDTLS when USE_MBEDTLS). find_package(MbedTLS
# 3) (called from libdatachannel during add_subdirectory below) locates the static
# prebuilt produced by tools/build_mbedtls_windows.ps1 via CMAKE_PREFIX_PATH. That
# build MUST have MBEDTLS_SSL_DTLS_SRTP enabled or DTLS-SRTP key extraction fails.
set(MBEDTLS_WINDOWS_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/third_party/mbedtls-windows")
if(NOT EXISTS "${MBEDTLS_WINDOWS_PREFIX}/include/mbedtls/build_info.h")
  message(FATAL_ERROR
    "MbedTLS for Windows not found at ${MBEDTLS_WINDOWS_PREFIX}.\n"
    "Build it first:  pwsh tools/build_mbedtls_windows.ps1")
endif()
list(PREPEND CMAKE_PREFIX_PATH "${MBEDTLS_WINDOWS_PREFIX}")
set(USE_MBEDTLS ON CACHE BOOL "" FORCE)

# Build libdatachannel from source
set(NO_WEBSOCKET ON CACHE BOOL "" FORCE)
set(NO_EXAMPLES ON CACHE BOOL "" FORCE)
set(NO_TESTS ON CACHE BOOL "" FORCE)
set(RTC_STATIC ON CACHE BOOL "" FORCE)
set(LIBSRTP_TEST_APPS OFF CACHE BOOL "" FORCE)
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libdatachannel"
                 "${CMAKE_CURRENT_BINARY_DIR}/libdatachannel" EXCLUDE_FROM_ALL)

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "flutter_libdatachannel_plugin.cpp"
  "flutter_libdatachannel_plugin.h"
  "../src/ldc_dump.cpp"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/flutter_libdatachannel/flutter_libdatachannel_plugin_c_api.h"
  "flutter_libdatachannel_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_LIBDATACHANNEL_BUILDING)
target_compile_definitions(${PLUGIN_NAME} PRIVATE RTC_STATIC _CRT_SECURE_NO_WARNINGS)

# Source include directories and library dependencies.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../src"
  "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libdatachannel/include")

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)
target_link_libraries(${PLUGIN_NAME} PRIVATE datachannel-static)

# List of absolute paths to libraries that should be bundled with the plugin.
# Everything is linked statically into flutter_libdatachannel_plugin.dll:
# datachannel-static pulls in libjuice/libsrtp/usrsctp (all static via RTC_STATIC)
# and MbedTLS::MbedTLS (the static prebuilt), so there are no extra runtime DLLs
# to copy alongside the app.
set(flutter_libdatachannel_bundled_libraries
  ""
  PARENT_SCOPE
)
