import 'package:ai_driver/src/finders.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('text finders ignore obscured fields', (WidgetTester tester) async {
    // A passcode keypad: once "7" has been typed, find.text('7') would match
    // both the key and the obscured field's controller value, and the driver
    // would answer AMBIGUOUS for a tap that is perfectly unambiguous.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              TextField(obscureText: true, controller: TextEditingController(text: '7')),
              const Text('7'),
            ],
          ),
        ),
      ),
    );

    expect(find.text('7', findRichText: true).evaluate(), hasLength(2), reason: 'the stock finder collides');
    expect(byVisibleText('7').evaluate(), hasLength(1));
    expect(byVisibleTextContaining('7').evaluate(), hasLength(1));
  });

  testWidgets('text finders still match plain and editable text', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              const Text('Confirm'),
              TextField(controller: TextEditingController(text: 'typed')),
            ],
          ),
        ),
      ),
    );

    expect(byVisibleText('Confirm').evaluate(), hasLength(1));
    expect(byVisibleText('typed').evaluate(), hasLength(1));
    expect(byVisibleTextContaining('onfir').evaluate(), hasLength(1));
    expect(byVisibleText('nope').evaluate(), isEmpty);
  });
}
