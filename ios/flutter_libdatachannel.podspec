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
  # bridge header (Classes/flutter_libdatachannel.h -> ../../src/...). It's
  # exposed as a public module header so the module's umbrella resolves for
  # consumers (the app's @import) regardless of their header search paths, and
  # so the plugin's own Swift sees the ldc_* C API. The header's *implementation*
  # (../src/*.cpp) is compiled + linked into the native static archive by the
  # build phase below, not by pod. (CocoaPods can't glob a header outside the
  # pod root, hence the in-pod symlink rather than a direct ../src reference.)
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/flutter_libdatachannel.h'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    'HEADER_SEARCH_PATHS' => [
      '"$(PODS_TARGET_SRCROOT)/../src"',
      '"$(PODS_TARGET_SRCROOT)/../third_party/libdatachannel/include"',
    ].join(' '),
    # Link the self-contained native archive produced by the build phase below
    # (libdatachannel + libjuice/libSRTP/usrsctp + MbedTLS + the C bridge).
    # It's generated at build time, so it's referenced via LIBRARY_SEARCH_PATHS
    # + -l rather than vendored_libraries (which pod resolves too early, at
    # `pod install`). The path mirrors build_ios_native.sh's output layout.
    'LIBRARY_SEARCH_PATHS' =>
      '"$(PODS_TARGET_SRCROOT)/../build/ios/$(PLATFORM_NAME)-$(CONFIGURATION)"',
    'OTHER_LDFLAGS' => '-lc++ -lflutter_libdatachannel_native',
  }
  s.swift_version = '5.0'

  s.preserve_paths = [
    '../src/**/*',
    '../third_party/libdatachannel/**/*',
    '../tools/**/*',
    '../build/ios/**/*',
  ]

  # Cross-compile MbedTLS (with MBEDTLS_SSL_DTLS_SRTP) once before building:
  #   tools/build_mbedtls_ios.sh iphoneos [iphonesimulator]
  # Then this phase builds libdatachannel + deps + the C bridge into a single
  # static archive for the current SDK/arch/config (see tools/build_ios_native.sh).
  s.script_phase = {
    :name => 'Build libdatachannel (iOS native)',
    :script => 'set -e; "${PODS_TARGET_SRCROOT}/../tools/build_ios_native.sh"',
    :execution_position => :before_compile,
  }
end
