
import 'flutter_libdatachannel_platform_interface.dart';

class FlutterLibdatachannel {
  Future<String?> getPlatformVersion() {
    return FlutterLibdatachannelPlatform.instance.getPlatformVersion();
  }
}
