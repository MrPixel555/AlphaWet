import 'package:aw_manager_ui/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows initial empty state', (WidgetTester tester) async {
    await tester.pumpWidget(const AwManagerApp());

    expect(find.text('AW Manager UI'), findsOneWidget);
    expect(find.text('No configs imported yet'), findsOneWidget);
    expect(find.byType(OutlinedButton), findsOneWidget);
  });
}
