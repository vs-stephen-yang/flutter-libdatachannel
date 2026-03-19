import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_libdatachannel_example/main.dart';

void main() {
  testWidgets('App renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.text('flutter_libdatachannel'), findsOneWidget);
  });
}
