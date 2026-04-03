import 'package:aw_manager_ui/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows initial empty state', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(const AwManagerApp());
    await tester.pumpAndSettle();

    expect(find.text('AW Manager UI'), findsOneWidget);
    expect(find.text('No configs imported yet'), findsOneWidget);
    expect(find.byType(FilledButton), findsWidgets);
    expect(find.textContaining('HTTP 127.0.0.1:10808'), findsOneWidget);
  });
}
