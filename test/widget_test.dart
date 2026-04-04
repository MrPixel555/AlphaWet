import 'package:alpha_wet/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows initial app shell', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(const AlphaWetApp());
    await tester.pumpAndSettle();

    expect(find.text('AlphaWet'), findsOneWidget);
    expect(find.byType(FilledButton), findsWidgets);
    expect(find.textContaining('HTTP 127.0.0.1:10808'), findsOneWidget);
  });
}
