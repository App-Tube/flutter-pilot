import 'dart:io';

import 'session.dart';

/// Launches the example app, drives it, and prints a latency table.
/// Exit code 0 only if every assertion passed.
Future<int> runSmoke({
  required PilotSession session,
  required String root,
  required String device,
  String target = 'test_driver/ai_app.dart',
  int taps = 20,
}) async {
  final Map<String, List<int>> samples = <String, List<int>>{};
  void sample(String op, Object? ms) => (samples[op] ??= <int>[]).add((ms as num).toInt());
  final List<String> failures = <String>[];
  void check(bool cond, String what) {
    if (!cond) {
      failures.add(what);
      stderr.writeln('  FAIL: $what');
    }
  }

  stderr.writeln('== launch ($device)');
  final Map<String, Object?> launch = await session.launch(projectRoot: root, device: device, target: target);
  final Map<String, Object?> t = (launch['timings'] as Map).cast<String, Object?>();
  stderr.writeln(
    '  simBoot ${t['simBootMs']}ms  build+launch ${t['buildAndLaunchMs']}ms  vmConnect ${t['vmConnectMs']}ms  '
    'first idle ${(launch['idle'] as Map)['settleMs']}ms',
  );
  stderr.writeln('  app: ${launch['app']}');

  try {
    stderr.writeln('== tree');
    final Map<String, Object?> tree = await session.act('tree');
    sample('get_tree', tree['roundTripMs']);
    stderr.writeln((tree['text'] as String).split('\n').take(25).join('\n'));
    stderr.writeln('  nodes=${tree['nodes']} roundTrip=${tree['roundTripMs']}ms');

    stderr.writeln('== wait_for_idle x5');
    for (int i = 0; i < 5; i++) {
      final Map<String, Object?> r = await session.act('waitIdle');
      sample('wait_for_idle', r['roundTripMs']);
    }

    stderr.writeln('== tap key:increment x$taps');
    for (int i = 0; i < taps; i++) {
      final Map<String, Object?> r = await session.act('tap', <String, Object?>{'finder': 'key:increment'});
      sample('tap (act)', r['actMs']);
      sample('tap (act+settle)', r['totalMs']);
      sample('tap (round trip)', r['roundTripMs']);
    }
    final Map<String, Object?> counter = await session.act('getText', <String, Object?>{'finder': 'key:counter_text'});
    sample('get_text', counter['roundTripMs']);
    check(counter['text'] == '$taps', 'counter shows ${counter['text']}, expected $taps');

    stderr.writeln('== tap key:increment, no settle, x$taps');
    for (int i = 0; i < taps; i++) {
      final Map<String, Object?> r = await session.act('tap', <String, Object?>{
        'finder': 'key:increment',
        'settleTimeoutMs': 0,
      });
      sample('tap no-settle (round trip)', r['roundTripMs']);
    }
    final Map<String, Object?> idleAfterBurst = await session.act('waitIdle');
    sample('wait_for_idle after burst', idleAfterBurst['settleMs']);
    final Map<String, Object?> counter2 = await session.act('getText', <String, Object?>{'finder': 'key:counter_text'});
    check(
      counter2['text'] == '${taps * 2}',
      'counter after no-settle burst shows ${counter2['text']}, expected ${taps * 2}',
    );

    stderr.writeln('== tap with frame hash x5');
    for (int i = 0; i < 5; i++) {
      final Map<String, Object?> r = await session.act('tap', <String, Object?>{
        'finder': 'key:increment',
        'hash': true,
      });
      sample('tap+hash (round trip)', r['roundTripMs']);
      check(r['changed'] == true, 'frame hash did not change after tap');
    }

    stderr.writeln('== enter_text key:name_field');
    final Map<String, Object?> typed = await session.act('enterText', <String, Object?>{
      'finder': 'key:name_field',
      'text': 'Pilot',
    });
    sample('enter_text (round trip)', typed['roundTripMs']);
    stderr.writeln('  settle: ${typed['settle']}');
    final Map<String, Object?> greeting = await session.act('getText', <String, Object?>{'finder': 'key:greeting'});
    check(greeting['text'] == 'Hello, Pilot', 'greeting shows ${greeting['text']}');

    stderr.writeln('== policy: enter_text into obscured field must be refused');
    try {
      await session.act('enterText', <String, Object?>{'finder': 'key:secret_field', 'text': 'hunter2'});
      check(false, 'typing into obscured field was allowed');
    } catch (e) {
      check('$e'.contains('POLICY_DENIED'), 'unexpected error for obscured field: $e');
    }

    stderr.writeln('== not found / ambiguous');
    try {
      await session.act('tap', <String, Object?>{'finder': 'key:does_not_exist'});
      check(false, 'tap on missing key succeeded');
    } catch (e) {
      check('$e'.contains('NOT_FOUND'), 'unexpected error for missing key: $e');
    }

    stderr.writeln('== screenshot x3 at 0.5 and 1.0');
    for (final double scale in <double>[0.5, 0.5, 0.5, 1.0]) {
      final ({List<int> png, Map<String, Object?> meta}) s = await session.screenshot(scale: scale);
      sample('screenshot@$scale (round trip)', s.meta['roundTripMs']);
      sample('screenshot@$scale (capture)', s.meta['captureMs']);
      sample('screenshot@$scale (png encode)', s.meta['encodeMs']);
      stderr.writeln('  ${s.meta['width']}x${s.meta['height']} ${s.meta['bytes']} bytes -> ${s.meta['path']}');
    }

    stderr.writeln('== hot_reload x3');
    for (int i = 0; i < 3; i++) {
      final Map<String, Object?> r = await session.hotReload();
      sample('hot_reload', (r['timings'] as Map)['reloadMs']);
      sample('hot_reload (+idle)', (r['timings'] as Map)['totalMs']);
      if (i == 0) {
        stderr.writeln('  ${r['message']}  idle: ${r['idle']}');
      }
    }
    final Map<String, Object?> afterReload = await session.act('getText', <String, Object?>{
      'finder': 'key:counter_text',
    });
    check(afterReload['text'] == '${taps * 2 + 5}', 'state lost across hot reload: ${afterReload['text']}');

    stderr.writeln('== hot_restart');
    final Map<String, Object?> restart = await session.hotReload(full: true);
    sample('hot_restart (+idle)', (restart['timings'] as Map)['totalMs']);
    final Map<String, Object?> afterRestart = await session.act('getText', <String, Object?>{
      'finder': 'key:counter_text',
    });
    check(afterRestart['text'] == '0', 'state not reset by hot restart: ${afterRestart['text']}');

    final List<Map<String, Object?>> errs = session.runtimeErrors();
    stderr.writeln('== runtime errors captured: ${errs.length}');
  } finally {
    stderr.writeln('== stop');
    await session.stop();
  }

  stderr.writeln('');
  stderr.writeln(
    'operation'.padRight(34) + 'n'.padLeft(4) + 'p50 ms'.padLeft(9) + 'p95 ms'.padLeft(9) + 'max ms'.padLeft(9),
  );
  for (final MapEntry<String, List<int>> e in samples.entries) {
    final List<int> s = List<int>.of(e.value)..sort();
    int pct(double q) => s[((s.length - 1) * q).round()];
    stderr.writeln(
      e.key.padRight(34) +
          '${s.length}'.padLeft(4) +
          '${pct(0.5)}'.padLeft(9) +
          '${pct(0.95)}'.padLeft(9) +
          '${s.last}'.padLeft(9),
    );
  }
  stderr.writeln('');
  if (failures.isEmpty) {
    stderr.writeln('SMOKE OK');
    return 0;
  }
  stderr.writeln('SMOKE FAILED: ${failures.length} check(s)');
  for (final String f in failures) {
    stderr.writeln('  - $f');
  }
  return 1;
}
