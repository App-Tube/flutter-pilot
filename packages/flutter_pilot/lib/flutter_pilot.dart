/// flutter_pilot: an MCP server that drives a Flutter app in-process.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

export 'src/daemon.dart' show DaemonEvent, DaemonException, FlutterDaemon, parseDaemonLine;
export 'src/flow.dart' show FlowRunner, FlowStep;
export 'src/server.dart' show PilotServer;
export 'src/session.dart' show PilotSession;
export 'src/sim.dart' show SimAdapter;
export 'src/smoke.dart' show runSmoke;
export 'src/vm_client.dart' show AiDriverCallException, RuntimeError, VmClient;

/// Finds a `flutter` executable: explicit path, `FLUTTER_PILOT_FLUTTER`,
/// the Flutter SDK that owns the running Dart VM, then PATH, then fvm's
/// default.
Future<String> resolveFlutter(String? explicit) async {
  final List<String> candidates = <String>[?explicit, ?Platform.environment['FLUTTER_PILOT_FLUTTER']];
  // <sdk>/bin/cache/dart-sdk/bin/dart -> <sdk>/bin/flutter
  final String dart = Platform.resolvedExecutable;
  final int idx = dart.indexOf('${p.separator}bin${p.separator}cache${p.separator}dart-sdk${p.separator}');
  if (idx > 0) {
    candidates.add(p.join(dart.substring(0, idx), 'bin', 'flutter'));
  }
  for (final String c in candidates) {
    if (File(c).existsSync()) {
      return c;
    }
  }
  final ProcessResult which = await Process.run(Platform.isWindows ? 'where' : 'which', <String>['flutter']);
  if (which.exitCode == 0) {
    final String found = (which.stdout as String).trim().split('\n').first;
    if (found.isNotEmpty) {
      return found;
    }
  }
  final String home = Platform.environment['HOME'] ?? '';
  final String fvm = p.join(home, 'fvm', 'default', 'bin', 'flutter');
  if (File(fvm).existsSync()) {
    return fvm;
  }
  throw StateError('flutter executable not found; pass --flutter or set FLUTTER_PILOT_FLUTTER');
}
