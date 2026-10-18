import 'package:fishauctions_application/widgets/tap_to_pay_awareness.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Opens the sheet; the returned getter reads what it resolved to.
  Future<bool? Function()> open(WidgetTester tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result = await TapToPayAwarenessSheet.show(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return () => result;
  }

  testWidgets('the CTA resolves true', (tester) async {
    final result = await open(tester);
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.text('Get started with Tap to Pay on iPhone'));
    await tester.pumpAndSettle();
    expect(result(), isTrue);
  });

  testWidgets('"Terms apply." opens the full disclaimers', (tester) async {
    await open(tester);
    await tester.tap(find.text('Terms apply.'));
    await tester.pumpAndSettle();
    expect(find.text('Legal Disclaimers'), findsOneWidget);
    expect(find.textContaining('EMVCo'), findsOneWidget);
    expect(find.textContaining('Apple Payments Services LLC'), findsOneWidget);
  });
}
