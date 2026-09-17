// Regression tests for actions whose target leaves the tree as a result of the
// action: a tap that dismisses the bottom sheet it lives in, or that pushes a
// route replacing it. Reading `Element.widget` afterwards null-asserts, which
// used to turn a perfectly good tap into {ok: false, code: INTERNAL}.

import 'package:ai_driver/src/ai_driver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Semantics off: the handle would outlive the test and trip flutter_test's
  // leak check. Nothing here resolves by label.
  AiDriver newDriver(WidgetTester tester) =>
      AiDriver.forTest(policy: const AiDriverPolicy(enableSemantics: false))
        ..debugDispatch = (Finder f) async {
          await tester.tap(f, warnIfMissed: false);
          await tester.pumpAndSettle();
        };

  testWidgets('tap that dismisses its own bottom sheet reports the target it resolved', (WidgetTester tester) async {
    await tester.pumpWidget(const _App());
    await tester.tap(find.byKey(const Key('open_sheet')));
    await tester.pumpAndSettle();

    final Element target = find.byKey(const Key('sheet_confirm')).evaluate().single;
    final Map<String, Object?> res = await newDriver(
      tester,
    ).debugCall('tap', <String, Object?>{'finder': 'key:sheet_confirm', 'settleTimeoutMs': 0});

    expect(res['ok'], isTrue, reason: 'tap landed, so it must not report a failure: $res');
    expect(target.mounted, isFalse, reason: 'the sheet should be gone; otherwise this is not the regression');
    final Map<String, Object?> desc = (res['target']! as Map).cast<String, Object?>();
    expect(desc['key'], 'sheet_confirm');
    expect(desc['type'], 'ElevatedButton');
    expect(desc['rect'], isNotNull, reason: 'the rect is snapshotted before the tap, while it still has one');
    expect(res['targetUnmounted'], isTrue);
    expect(find.text('confirmed'), findsOneWidget);
  });

  testWidgets('tap that pushes a full-screen route over the target still reports it', (WidgetTester tester) async {
    await tester.pumpWidget(const _App());

    final Map<String, Object?> res = await newDriver(
      tester,
    ).debugCall('tap', <String, Object?>{'finder': 'key:open_details', 'settleTimeoutMs': 0});

    expect(res['ok'], isTrue, reason: '$res');
    expect(((res['target']! as Map)['key']), 'open_details');
    expect(find.byKey(const Key('details_text')), findsOneWidget);
  });

  testWidgets('describing an unmounted element degrades instead of throwing', (WidgetTester tester) async {
    await tester.pumpWidget(const _App());
    final Element target = find.byKey(const Key('open_sheet')).evaluate().single;

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(target.mounted, isFalse);

    expect(newDriver(tester).debugDescribe(target), <String, Object?>{
      'type': '<unmounted>',
      'rect': null,
      'unmounted': true,
    });
  });
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) => const MaterialApp(home: _Home());
}

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  bool _confirmed = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(_confirmed ? 'confirmed' : 'not confirmed'),
            ElevatedButton(
              key: const Key('open_sheet'),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (BuildContext sheetContext) => SizedBox(
                  height: 160,
                  child: Center(
                    child: ElevatedButton(
                      key: const Key('sheet_confirm'),
                      // Pops the route the tapped button lives in: the button
                      // element is defunct by the time the tap returns.
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        setState(() => _confirmed = true);
                      },
                      child: const Text('Confirm'),
                    ),
                  ),
                ),
              ),
              child: const Text('Open sheet'),
            ),
            ElevatedButton(
              key: const Key('open_details'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(
                    body: Center(child: Text('Details', key: Key('details_text'))),
                  ),
                ),
              ),
              child: const Text('Open details'),
            ),
          ],
        ),
      ),
    );
  }
}
