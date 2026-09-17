import 'package:flutter_pilot/flutter_pilot.dart';
import 'package:test/test.dart';

void main() {
  group('parseDaemonLine', () {
    test('decodes a wrapped event', () {
      final List<Map<String, Object?>> msgs = parseDaemonLine(
        '[{"event":"app.debugPort","params":{"appId":"abc","port":1234,"wsUri":"ws://127.0.0.1:1234/tok=/ws"}}]',
      );
      expect(msgs, hasLength(1));
      expect(msgs.single['event'], 'app.debugPort');
      expect((msgs.single['params'] as Map)['wsUri'], 'ws://127.0.0.1:1234/tok=/ws');
    });

    test('decodes a response with id', () {
      final List<Map<String, Object?>> msgs = parseDaemonLine(
        '[{"id":3,"result":{"code":0,"message":"Reloaded 1 of 600 libraries"}}]',
      );
      expect(msgs.single['id'], 3);
      expect((msgs.single['result'] as Map)['code'], 0);
    });

    test('ignores plain log lines and non-JSON brackets', () {
      expect(parseDaemonLine('Launching lib/main.dart on iPhone 17 Pro in debug mode...'), isEmpty);
      expect(parseDaemonLine('[not json]'), isEmpty);
      expect(parseDaemonLine('  '), isEmpty);
      expect(parseDaemonLine('[1, 2, 3]'), isEmpty);
    });

    test('handles several messages in one line', () {
      final List<Map<String, Object?>> msgs = parseDaemonLine('[{"event":"a","params":{}},{"event":"b","params":{}}]');
      expect(msgs.map((Map<String, Object?> m) => m['event']), <String>['a', 'b']);
    });
  });
}
