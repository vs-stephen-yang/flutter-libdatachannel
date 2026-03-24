cmake_minimum_required(VERSION 3.14)
project(flutter_libdatachannel_android LANGUAGES CXX C)

set(NO_WEBSOCKET ON CACHE BOOL "" FORCE)
set(NO_EXAMPLES ON CACHE BOOL "" FORCE)
set(NO_TESTS ON CACHE BOOL "" FORCE)
set(USE_MBEDTLS ON CACHE BOOL "" FORCE)

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
    log
)

target_compile_definitions(flutter_libdatachannel_native PRIVATE RTC_STATIC)
