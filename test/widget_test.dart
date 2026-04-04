import 'package:alpha_wet/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows initial app shell', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});

    await tester.pumpWidget(const AlphaWetApp());
    await tester.pumpAndSettle();

    expect(find.text('AlphaWet'), findsWidgets);
    expect(find.text('Import Config'), findsOneWidget);
    expect(find.text('Runtime Settings'), findsOneWidget);
    expect(find.text('Preview Logs'), findsWidgets);
    expect(find.text('Export Log'), findsOneWidget);
    expect(find.text('made by AlphaCraft'), findsOneWidget);
    expect(find.textContaining('HTTP 127.0.0.1:10808'), findsOneWidget);
  });
}
