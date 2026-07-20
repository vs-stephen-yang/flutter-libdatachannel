Pod::Spec.new do |s|
  s.name             = 'flutter_libdatachannel'
  s.version          = '0.0.1'
  s.summary          = 'Flutter plugin for WebRTC media tracks using libdatachannel.'
  s.description      = <<-DESC
Flutter plugin for WebRTC media track sending/receiving using libdatachannel.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  # The Swift plugin lives in Classes/, alongside a symlink to the shared C
  # bridge header (Classes/flutter_libdatachannel.h -> ../../src/...), exposed as
  # a public module header so the plugin's own Swift sees the ldc_* C API and the
  # app's @import resolves. The header's implementation (../src/*.cpp) is compiled
  # + linked into the native static archive by the build phase below (mirrors the
  # iOS podspec).
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/flutter_libdatachannel.h'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.14'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => [
      '"$(PODS_TARGET_SRCROOT)/../src"',
      '"$(PODS_TARGET_SRCROOT)/../third_party/libdatachannel/include"',
    ].join(' '),
    # Link the self-contained native archive produced by the build phase below
    # (libdatachannel + libjuice/libSRTP/usrsctp + MbedTLS + the C bridge). It is
    # generated at build time, so it is referenced via LIBRARY_SEARCH_PATHS + -l
    # rather than vendored_libraries (which pod resolves too early). The path
    # mirrors build_macos_native.sh's output layout.
    'LIBRARY_SEARCH_PATHS' =>
      '"$(PODS_TARGET_SRCROOT)/../build/macos/$(PLATFORM_NAME)-$(CONFIGURATION)"',
    'OTHER_LDFLAGS' => '-lc++ -lflutter_libdatachannel_native',
  }
  s.swift_version = '5.0'

  s.preserve_paths = [
    '../src/**/*',
    '../third_party/libdatachannel/**/*',
    '../tools/**/*',
    '../build/macos/**/*',
  ]

  # Build MbedTLS (with MBEDTLS_SSL_DTLS_SRTP) once before building:
  #   tools/build_mbedtls_macos.sh
  # Then this phase builds libdatachannel + deps + the C bridge into a single
  # static archive for the current arch/config (see tools/build_macos_native.sh).
  s.script_phase = {
    :name => 'Build libdatachannel (macOS native)',
    :script => 'set -e; "${PODS_TARGET_SRCROOT}/../tools/build_macos_native.sh"',
    :execution_position => :before_compile,
  }
end
