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

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.14'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
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
      BUILD_DIR="${PODS_TARGET_SRCROOT}/../build/macos"
      mkdir -p "$BUILD_DIR"
      cd "$BUILD_DIR"
      cmake "${PODS_TARGET_SRCROOT}/../third_party/libdatachannel" \
        -DCMAKE_BUILD_TYPE=Release \
        -DNO_WEBSOCKET=ON \
        -DNO_EXAMPLES=ON \
        -DNO_TESTS=ON
      cmake --build . --config Release -j
    SCRIPT
    :execution_position => :before_compile,
  }
end
