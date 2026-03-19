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
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'HEADER_SEARCH_PATHS' => [
      '"$(PODS_TARGET_SRCROOT)/../src"',
      '"$(PODS_TARGET_SRCROOT)/../third_party/libdatachannel/include"',
    ].join(' '),
    'OTHER_LDFLAGS' => '-lstdc++',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
  }
  s.swift_version = '5.0'

  s.preserve_paths = [
    '../src/**/*',
    '../third_party/libdatachannel/**/*',
  ]

  s.script_phase = {
    :name => 'Build libdatachannel',
    :script => <<-SCRIPT
      set -e
      BUILD_DIR="${PODS_TARGET_SRCROOT}/../build/ios"
      mkdir -p "$BUILD_DIR"
      cd "$BUILD_DIR"
      cmake "${PODS_TARGET_SRCROOT}/../third_party/libdatachannel" \
        -DCMAKE_BUILD_TYPE=Release \
        -DNO_WEBSOCKET=ON \
        -DNO_EXAMPLES=ON \
        -DNO_TESTS=ON \
        -DUSE_MBEDTLS=ON \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES="arm64" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="12.0"
      cmake --build . --config Release -j
    SCRIPT
    :execution_position => :before_compile,
  }
end
