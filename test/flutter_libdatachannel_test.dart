import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_libdatachannel/flutter_libdatachannel.dart';
import 'package:flutter_libdatachannel/flutter_libdatachannel_platform_interface.dart';
import 'package:flutter_libdatachannel/flutter_libdatachannel_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlutterLibdatachannelPlatform
    with MockPlatformInterfaceMixin
    implements FlutterLibdatachannelPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FlutterLibdatachannelPlatform initialPlatform = FlutterLibdatachannelPlatform.instance;

  test('$MethodChannelFlutterLibdatachannel is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlutterLibdatachannel>());
  });

  test('getPlatformVersion', () async {
    FlutterLibdatachannel flutterLibdatachannelPlugin = FlutterLibdatachannel();
    MockFlutterLibdatachannelPlatform fakePlatform = MockFlutterLibdatachannelPlatform();
    FlutterLibdatachannelPlatform.instance = fakePlatform;

    expect(await flutterLibdatachannelPlugin.getPlatformVersion(), '42');
  });
}
