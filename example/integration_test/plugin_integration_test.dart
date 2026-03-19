import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_libdatachannel/flutter_libdatachannel.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('createPeerConnection test', (WidgetTester tester) async {
    final pc = await RTCPeerConnection.create(
      RTCConfiguration(iceServers: ['stun:stun.l.google.com:19302']),
    );
    expect(pc.id, greaterThanOrEqualTo(0));
    await pc.close();
    await pc.dispose();
  });
}
