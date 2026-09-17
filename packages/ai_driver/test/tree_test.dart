import 'package:ai_driver/src/ai_driver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AiDriver newDriver() => AiDriver.forTest(policy: const AiDriverPolicy(enableSemantics: false));

  testWidgets('a truncated dump says so', (WidgetTester tester) async {
    await tester.pumpWidget(const _App());

    final Map<String, Object?> small = await newDriver().debugCall('tree', <String, Object?>{'maxNodes': 12});
    expect(small['truncated'], isTrue);
    expect(small['text'], contains('truncated at 12 nodes'));
    expect(small['text'], isNot(contains('row 29')));

    final Map<String, Object?> full = await newDriver().debugCall('tree');
    expect(full['truncated'], isFalse);
    expect(full['text'], contains('row 29'));
  });

  testWidgets('a route hidden under an opaque one is skipped, so the route on top survives a small budget', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const _App());
    await tester.tap(find.byKey(const Key('open_sheet')));
    await tester.pumpAndSettle();

    // Overlay entries are walked last. Without skipping the off-stage home
    // route (30 rows with stale rects) the pushed route was exactly what a
    // 12-node budget lost.
    final Map<String, Object?> small = await newDriver().debugCall('tree', <String, Object?>{'maxNodes': 12});
    expect(small['text'], contains('pushed_marker'), reason: '${small['text']}');
    expect(small['text'], isNot(contains('row 0')));

    // The raw dump keeps everything: it is the tool for "why is this element here".
    final Map<String, Object?> raw = await newDriver().debugCall('tree', <String, Object?>{'summary': false});
    expect(raw['text'], contains('pushed_marker'));
    expect(raw['text'], contains('row 0'));
  });

  testWidgets('a finder dumps just that subtree', (WidgetTester tester) async {
    await tester.pumpWidget(const _App());
    await tester.tap(find.byKey(const Key('open_sheet')));
    await tester.pumpAndSettle();

    final Map<String, Object?> res = await newDriver().debugCall('tree', <String, Object?>{
      'finder': 'key:pushed_root',
      'maxNodes': 12,
    });
    expect(res['ok'], isTrue, reason: '$res');
    expect(res['root'], 'key=pushed_root');
    expect(res['text'], contains('pushed_marker'));
    expect(res['text'], isNot(contains('row 0')));
  });
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) => const MaterialApp(home: _Home());
}

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(
          children: <Widget>[
            ElevatedButton(
              key: const Key('open_sheet'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(
                    key: Key('pushed_root'),
                    body: Center(child: Text('pushed_marker')),
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
            for (int i = 0; i < 30; i++) Text('row $i'),
          ],
        ),
      ),
    );
  }
}
