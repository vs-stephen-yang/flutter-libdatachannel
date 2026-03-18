import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'flutter_libdatachannel_method_channel.dart';

abstract class FlutterLibdatachannelPlatform extends PlatformInterface {
  /// Constructs a FlutterLibdatachannelPlatform.
  FlutterLibdatachannelPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlutterLibdatachannelPlatform _instance = MethodChannelFlutterLibdatachannel();

  /// The default instance of [FlutterLibdatachannelPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlutterLibdatachannel].
  static FlutterLibdatachannelPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlutterLibdatachannelPlatform] when
  /// they register themselves.
  static set instance(FlutterLibdatachannelPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
