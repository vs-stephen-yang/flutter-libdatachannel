import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flutter_libdatachannel_platform_interface.dart';

/// An implementation of [FlutterLibdatachannelPlatform] that uses method channels.
class MethodChannelFlutterLibdatachannel extends FlutterLibdatachannelPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_libdatachannel');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
