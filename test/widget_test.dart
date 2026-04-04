import 'package:alpha_wet/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows initial app shell', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(const AwManagerApp());
    await tester.pump();

    expect(find.text('AlphaWet'), findsWidgets);
    expect(find.textContaining('HTTP 127.0.0.1:10808'), findsOneWidget);
    expect(find.text('made by AlphaCraft'), findsOneWidget);
    expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
  });
}
