// The `screen` handler: a flat list of what is visible right now, without the
// noise that made tree dumps expensive to read (Text/RichText pairs, routes
// hidden under an opaque one, a Semantics label repeating its child's text).

import 'package:ai_driver/src/ai_driver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AiDriver newDriver() => AiDriver.forTest(policy: const AiDriverPolicy(enableSemantics: false));

  Future<List<String>> items(AiDriver d) async {
    final Map<String, Object?> res = await d.debugCall('screen');
    expect(res['ok'], isTrue, reason: '$res');
    return (res['items']! as List).cast<String>();
  }

  testWidgets('a labelled button is one tap item, not a label plus a text', (WidgetTester tester) async {
    await tester.pumpWidget(const _App());
    final List<String> lines = await items(newDriver());

    expect(lines.where((String l) => l.contains('"Get started"')), hasLength(1));
    expect(lines.singleWhere((String l) => l.contains('"Get started"')), startsWith('tap '));
    expect(lines.singleWhere((String l) => l.contains('"Just a title"')), startsWith('text '));
  });

  testWidgets('an obscured field shows as a field without its value', (WidgetTester tester) async {
    await tester.pumpWidget(const _App());
    await tester.enterText(find.byKey(const Key('secret')), 'hunter2');
    await tester.pump();

    final List<String> lines = await items(newDriver());
    final String field = lines.singleWhere((String l) => l.contains('field(obscured)'));
    expect(field, isNot(contains('hunter2')));
    expect(field, contains('key=secret'));
  });

  testWidgets('a route under an opaque pushed route is not listed', (WidgetTester tester) async {
    await tester.pumpWidget(const _App());
    await tester.tap(find.byKey(const Key('push')));
    await tester.pumpAndSettle();

    final Map<String, Object?> res = await newDriver().debugCall('screen');
    final List<String> lines = (res['items']! as List).cast<String>();
    expect(res['route'], '/second');
    expect(lines.any((String l) => l.contains('"Second page"')), isTrue);
    expect(
      lines.any((String l) => l.contains('"Get started"')),
      isFalse,
      reason: 'the home route is off-stage under the opaque second route: $lines',
    );
  });

  testWidgets('only the selected IndexedStack tab is listed, and icon glyphs are not items', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const _Tabs());
    final List<String> lines = await items(newDriver());
    expect(lines.any((String l) => l.contains('"Shown tab"')), isTrue, reason: '$lines');
    expect(
      lines.any((String l) => l.contains('"Hidden tab"')),
      isFalse,
      reason: 'the other tab is laid out but never painted: $lines',
    );
    expect(lines, hasLength(1), reason: 'the star icon glyph must not show up as text: $lines');
  });

  testWidgets('a whole-screen GestureDetector does not make everything tappable', (WidgetTester tester) async {
    await tester.pumpWidget(const _App());
    final List<String> lines = await items(newDriver());
    expect(
      lines.singleWhere((String l) => l.contains('"Just a title"')),
      startsWith('text '),
      reason: 'the dismiss-keyboard detector wraps the body but is not a real button',
    );
  });
}

class _Tabs extends StatelessWidget {
  const _Tabs();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: IndexedStack(
          index: 1,
          children: const <Widget>[
            Center(child: Text('Hidden tab')),
            Center(child: Row(children: <Widget>[Icon(Icons.star), Text('Shown tab')])),
          ],
        ),
      ),
    );
  }
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      routes: <String, WidgetBuilder>{'/second': (_) => const Scaffold(body: Center(child: Text('Second page')))},
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: GestureDetector(
            onTap: () {},
            behavior: HitTestBehavior.opaque,
            child: Column(
              children: <Widget>[
                const Text('Just a title'),
                Semantics(
                  label: 'Get started',
                  button: true,
                  child: GestureDetector(
                    onTap: () {},
                    child: const SizedBox(width: 200, height: 44, child: Text('Get started')),
                  ),
                ),
                const TextField(key: Key('secret'), obscureText: true),
                ElevatedButton(
                  key: const Key('push'),
                  onPressed: () => Navigator.of(context).pushNamed('/second'),
                  child: const Text('Push'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
