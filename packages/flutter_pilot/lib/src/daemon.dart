import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One `{"event": ..., "params": ...}` message from `flutter run --machine`.
class DaemonEvent {
  DaemonEvent(this.event, this.params);

  final String event;
  final Map<String, Object?> params;

  @override
  String toString() => 'DaemonEvent($event, $params)';
}

class DaemonException implements Exception {
  DaemonException(this.method, this.error, [this.trace]);

  final String method;
  final Object? error;
  final Object? trace;

  @override
  String toString() => 'DaemonException($method): $error';
}

/// Parses one stdout line. The daemon wraps every message in `[...]`; any
/// other line is plain log output and yields an empty list.
List<Map<String, Object?>> parseDaemonLine(String line) {
  final String t = line.trim();
  if (!t.startsWith('[') || !t.endsWith(']')) {
    return const <Map<String, Object?>>[];
  }
  try {
    final Object? decoded = jsonDecode(t);
    if (decoded is List) {
      return decoded.whereType<Map>().map((Map m) => m.cast<String, Object?>()).toList();
    }
  } catch (_) {
    // Not JSON after all (e.g. a Dart list printed by the app).
  }
  return const <Map<String, Object?>>[];
}

/// Thin JSON-RPC client around a `flutter run --machine` process.
class FlutterDaemon {
  FlutterDaemon._(this._process, this.command);

  final Process _process;
  final List<String> command;

  int _nextId = 0;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  final StreamController<DaemonEvent> _events = StreamController<DaemonEvent>.broadcast();
  final Completer<int> _exit = Completer<int>();

  /// Ring buffer of app + tool output, newest last.
  final List<String> logs = <String>[];
  static const int maxLogs = 2000;

  Stream<DaemonEvent> get events => _events.stream;
  Future<int> get exitCode => _exit.future;
  bool get isRunning => !_exit.isCompleted;

  static Future<FlutterDaemon> start({
    required String executable,
    required List<String> args,
    required String workingDirectory,
    Map<String, String>? environment,
  }) async {
    final Process p = await Process.start(
      executable,
      args,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    final FlutterDaemon d = FlutterDaemon._(p, <String>[executable, ...args]);
    p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(d._onLine);
    p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((String l) => d._log('[stderr] $l'));
    p.exitCode.then((int code) {
      d._exit.complete(code);
      for (final Completer<Object?> c in d._pending.values) {
        c.completeError(DaemonException('*', 'flutter process exited with code $code'));
      }
      d._pending.clear();
      d._events.close();
    });
    return d;
  }

  void _log(String line) {
    logs.add(line);
    if (logs.length > maxLogs) {
      logs.removeRange(0, logs.length - maxLogs);
    }
  }

  void _onLine(String line) {
    final List<Map<String, Object?>> msgs = parseDaemonLine(line);
    if (msgs.isEmpty) {
      _log(line);
      return;
    }
    for (final Map<String, Object?> m in msgs) {
      if (m['event'] is String) {
        final DaemonEvent ev = DaemonEvent(
          m['event'] as String,
          (m['params'] as Map?)?.cast<String, Object?>() ?? <String, Object?>{},
        );
        if (ev.event == 'app.log') {
          final String text = (ev.params['log'] ?? '').toString();
          _log(ev.params['error'] == true ? '[error] $text' : text);
        } else if (ev.event == 'daemon.logMessage') {
          _log('[daemon:${ev.params['level']}] ${ev.params['message']}');
        }
        if (!_events.isClosed) {
          _events.add(ev);
        }
      } else if (m['id'] != null) {
        final int id = (m['id'] as num).toInt();
        final Completer<Object?>? c = _pending.remove(id);
        if (c == null) {
          continue;
        }
        if (m.containsKey('error')) {
          c.completeError(DaemonException('id=$id', m['error'], m['trace']));
        } else {
          c.complete(m['result']);
        }
      }
    }
  }

  Future<Object?> call(String method, [Map<String, Object?>? params, Duration timeout = const Duration(seconds: 120)]) {
    if (!isRunning) {
      throw DaemonException(method, 'flutter process is not running');
    }
    final int id = _nextId++;
    final Completer<Object?> c = Completer<Object?>();
    _pending[id] = c;
    _process.stdin.writeln(
      jsonEncode(<Object?>[
        <String, Object?>{'id': id, 'method': method, 'params': ?params},
      ]),
    );
    return c.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('daemon $method timed out after ${timeout.inSeconds}s');
      },
    );
  }

  /// Completes with the first matching event. Subscribe before the event can
  /// possibly fire (i.e. synchronously after [start] returns).
  Future<DaemonEvent> waitFor(
    String event, {
    Duration timeout = const Duration(minutes: 5),
    bool Function(DaemonEvent e)? where,
  }) {
    return events
        .firstWhere(
          (DaemonEvent e) => e.event == event && (where?.call(e) ?? true),
          orElse: () => throw DaemonException(
            event,
            'flutter process exited before "$event". Last output:\n${tailLogs(40).join('\n')}',
          ),
        )
        .timeout(
          timeout,
          onTimeout: () => throw TimeoutException('daemon event $event not seen within ${timeout.inSeconds}s'),
        );
  }

  Future<void> kill() async {
    if (!isRunning) {
      return;
    }
    _process.kill(ProcessSignal.sigterm);
    await exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return -9;
      },
    );
  }

  List<String> tailLogs(int n) => logs.length <= n ? List<String>.of(logs) : logs.sublist(logs.length - n);
}
