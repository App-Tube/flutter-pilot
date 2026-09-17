import 'package:flutter_pilot/flutter_pilot.dart';
import 'package:test/test.dart';

void main() {
  const Map<String, Object?> noVars = <String, Object?>{};
  const Map<String, Object?> noDefaults = <String, Object?>{};

  group('FlowStep.parse shorthand', () {
    test('action and finder', () {
      final FlowStep s = FlowStep.parse('tap label:Get started', 0, noVars, noDefaults);
      expect(s.action, 'tap');
      expect(s.finder, 'label:Get started');
      expect(s.repeat, 1);
      expect(s.optional, isFalse);
      expect(s.describe(), 'tap label:Get started');
    });

    test('? prefix marks the step optional', () {
      final FlowStep s = FlowStep.parse('?tap text:Not now', 3, noVars, noDefaults);
      expect(s.optional, isTrue);
      expect(s.finder, 'text:Not now');
      expect(s.describe(), '?tap text:Not now');
    });

    test('xN suffix repeats', () {
      final FlowStep s = FlowStep.parse('tap text:0 x6', 0, noVars, noDefaults);
      expect(s.repeat, 6);
      expect(s.finder, 'text:0', reason: 'the repeat suffix must not leak into the finder');
    });

    test(':: separates the text to type', () {
      final FlowStep s = FlowStep.parse('enter_text key:email :: me@x.io', 0, noVars, noDefaults);
      expect(s.finder, 'key:email');
      expect(s.args['text'], 'me@x.io');
    });

    test('keypad takes the digits as text and an optional finder template', () {
      final FlowStep plain = FlowStep.parse('keypad 000000', 0, noVars, noDefaults);
      expect(plain.args['text'], '000000');
      expect(plain.finder, isNull);
      final FlowStep templated = FlowStep.parse('keypad key:pin_{c} :: 1234', 0, noVars, noDefaults);
      expect(templated.args['text'], '1234');
      expect(templated.finder, 'key:pin_{c}');
    });

    test('as suffix names the captured value', () {
      final FlowStep s = FlowStep.parse('clipboard as address', 7, noVars, noDefaults);
      expect(s.action, 'clipboard');
      expect(s.captureName, 'address');
      expect(FlowStep.parse('clipboard', 7, noVars, noDefaults).captureName, 'step7');
    });

    test('wait takes milliseconds, expect_route a route', () {
      expect(FlowStep.parse('wait 300', 0, noVars, noDefaults).ms, 300);
      expect(FlowStep.parse('expect_route /mainRoute', 0, noVars, noDefaults).route, '/mainRoute');
      expect(() => FlowStep.parse('wait soon', 0, noVars, noDefaults), throwsArgumentError);
    });

    test(r'${name} is filled from vars, missing vars fail loudly', () {
      final FlowStep s = FlowStep.parse('keypad ${r'${pin}'}', 0, <String, Object?>{'pin': '000000'}, noDefaults);
      expect(s.args['text'], '000000');
      expect(() => FlowStep.parse('keypad ${r'${pin}'}', 0, noVars, noDefaults), throwsArgumentError);
    });

    test('unknown action and missing finder are rejected', () {
      expect(() => FlowStep.parse('poke label:x', 0, noVars, noDefaults), throwsArgumentError);
      expect(() => FlowStep.parse('tap', 0, noVars, noDefaults), throwsArgumentError);
      expect(() => FlowStep.parse('enter_text key:x', 0, noVars, noDefaults), throwsArgumentError);
    });
  });

  group('FlowStep.parse map form', () {
    test('passes through action arguments and repeat/optional', () {
      final FlowStep s = FlowStep.parse(
        <String, Object?>{'action': 'wait_for', 'finder': 'text:Done', 'timeoutMs': 8000, 'optional': true},
        2,
        noVars,
        noDefaults,
      );
      expect(s.timeoutMs, 8000);
      expect(s.optional, isTrue);
      expect(s.actionArgs(), <String, Object?>{'finder': 'text:Done'});
    });

    test('defaults fill settle/steady/timeout only where the step has none', () {
      final Map<String, Object?> defaults = <String, Object?>{'settleTimeoutMs': 1500, 'steadyMs': 300, 'other': 1};
      final FlowStep s = FlowStep.parse('tap key:go', 0, noVars, defaults);
      expect(s.actionArgs(), <String, Object?>{'finder': 'key:go', 'settleTimeoutMs': 1500, 'steadyMs': 300});
      final FlowStep own = FlowStep.parse(
        <String, Object?>{'action': 'tap', 'finder': 'key:go', 'steadyMs': 0},
        0,
        noVars,
        defaults,
      );
      expect(own.actionArgs()['steadyMs'], 0);
      expect(own.args.containsKey('other'), isFalse);
    });

    test('rejects a step that is neither string nor map', () {
      expect(() => FlowStep.parse(42, 0, noVars, noDefaults), throwsArgumentError);
    });
  });
}
