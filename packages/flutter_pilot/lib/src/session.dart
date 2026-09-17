import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'daemon.dart';
import 'sim.dart';
import 'vm_client.dart';

/// Lifecycle + action facade used by both the MCP server and the smoke CLI.
class PilotSession {
  PilotSession({required this.flutterExecutable, this.log});

  final String flutterExecutable;
  final void Function(String message)? log;

  FlutterDaemon? _daemon;
  VmClient? _vm;
  String state = 'idle';
  String? appId;
  String? deviceId;
  String? root;
  String? wsUri;
  String? dtdUri;
  Map<String, Object?>? appInfo;
  int _errorCursor = 0;
  int _shotCounter = 0;
  Directory? _shotDir;

  bool get isConnected => state == 'connected' && _vm != null && _daemon != null && _daemon!.isRunning;

  Map<String, Object?> status() => <String, Object?>{
    'state': state,
    'appId': appId,
    'deviceId': deviceId,
    'root': root,
    'wsUri': wsUri,
    'dtdUri': dtdUri,
    'runtimeErrors': _vm?.errors.length ?? 0,
    'app': appInfo,
  };

  // ---------------------------------------------------------------- lifecycle

  Future<Map<String, Object?>> launch({
    required String projectRoot,
    required String device,
    String target = 'test_driver/ai_app.dart',
    String? flavor,
    String? definesFile,
    List<String> extraArgs = const <String>[],
    Duration timeout = const Duration(minutes: 15),
  }) async {
    _checkProject(projectRoot, target);
    final Stopwatch sw = Stopwatch()..start();
    state = 'launching';
    root = projectRoot;
    try {
      final int bootMs = await SimAdapter.ensureBooted(device, log: log);
      final List<String> args = <String>[
        'run',
        '--machine',
        '-d',
        device,
        '-t',
        target,
        if (flavor != null) ...<String>['--flavor', flavor],
        if (definesFile != null) '--dart-define-from-file=$definesFile',
        ...extraArgs,
      ];
      return await _startAndConnect(projectRoot, args, sw, timeout, bootMs: bootMs, phase: 'buildAndLaunchMs');
    } catch (e) {
      await stop();
      rethrow;
    }
  }

  /// Attaches to an app that is already installed (and, with [start], starts
  /// it first) instead of rebuilding it: `flutter attach --machine`. Skips the
  /// whole Gradle/Xcode build, which on a big app is the largest single cost
  /// of a run when the code has not changed. The app must be a debug build
  /// whose entrypoint calls enableAiDriver(). [appId] is the Android package
  /// or iOS bundle id; it is required to start or clear the app and helps
  /// attach pick the right process. [clearData] wipes app storage first
  /// (Android only), so onboarding can be driven again from scratch.
  Future<Map<String, Object?>> attach({
    required String projectRoot,
    required String device,
    String target = 'test_driver/ai_app.dart',
    String? appId,
    bool start = false,
    bool clearData = false,
    List<String> extraArgs = const <String>[],
    Duration timeout = const Duration(minutes: 3),
  }) async {
    _checkProject(projectRoot, target);
    if ((start || clearData) && appId == null) {
      throw ArgumentError('appId is required to start or clear the app');
    }
    final Stopwatch sw = Stopwatch()..start();
    state = 'attaching';
    root = projectRoot;
    try {
      final int bootMs = await SimAdapter.ensureBooted(device, log: log);
      Map<String, Object?>? started;
      if (start || clearData) {
        started = await SimAdapter.startApp(device, appId!, clearData: clearData);
        log?.call('Started $appId on $device: $started');
      }
      final List<String> args = <String>[
        'attach',
        '--machine',
        '-d',
        device,
        '-t',
        target,
        if (appId != null) ...<String>['--app-id', appId],
        ...extraArgs,
      ];
      final Map<String, Object?> res = await _startAndConnect(
        projectRoot,
        args,
        sw,
        timeout,
        bootMs: bootMs,
        phase: 'attachMs',
      );
      if (started != null) {
        res['started'] = started;
      }
      return res;
    } catch (e) {
      await stop();
      rethrow;
    }
  }

  void _checkProject(String projectRoot, String target) {
    if (_daemon != null) {
      throw StateError('An app is already running (state=$state). Call stop_app first.');
    }
    final Directory rootDir = Directory(projectRoot);
    if (!rootDir.existsSync() || !File(p.join(projectRoot, 'pubspec.yaml')).existsSync()) {
      throw ArgumentError('projectRoot must contain a pubspec.yaml: $projectRoot');
    }
    if (!File(p.join(projectRoot, target)).existsSync()) {
      throw ArgumentError(
        'Entrypoint $target not found under $projectRoot. Create it with:\n'
        "import 'package:ai_driver/ai_driver.dart';\n"
        "import 'package:<app>/main.dart' as app;\n"
        'void main() { enableAiDriver(); app.main(); }',
      );
    }
  }

  /// Runs `flutter <run|attach> --machine`, waits for the app, connects the
  /// VM service and the driver, and waits for the first settled frame.
  Future<Map<String, Object?>> _startAndConnect(
    String projectRoot,
    List<String> args,
    Stopwatch sw,
    Duration timeout, {
    required int bootMs,
    required String phase,
  }) async {
    final String flutter = flutterFor(projectRoot);
    log?.call('Starting: $flutter ${args.join(' ')} (cwd $projectRoot)');
    final FlutterDaemon d = await FlutterDaemon.start(
      executable: flutter,
      args: args,
      workingDirectory: projectRoot,
      environment: <String, String>{
        ...Platform.environment,
        // CocoaPods dies with a Ruby Encoding error without a UTF-8 locale.
        if (!Platform.environment.containsKey('LANG')) 'LANG': 'en_US.UTF-8',
        if (!Platform.environment.containsKey('LC_ALL')) 'LC_ALL': 'en_US.UTF-8',
      },
    );
    _daemon = d;
    // Subscribe synchronously, before any event can arrive.
    final Future<DaemonEvent> startF = d.waitFor('app.start', timeout: timeout)..ignore();
    final Future<DaemonEvent> portF = d.waitFor('app.debugPort', timeout: timeout)..ignore();
    final Future<DaemonEvent> startedF = d.waitFor('app.started', timeout: timeout)..ignore();
    final Future<String?> dtdF = d.events
        .firstWhere((DaemonEvent e) => e.event == 'app.dtd')
        .then<String?>((DaemonEvent e) => e.params['uri'] as String?)
        .catchError((Object _) => null);
    d.events.where((DaemonEvent e) => e.event == 'app.stop').listen((_) => _onAppStopped());
    final Future<Never> exitF = d.exitCode.then((int code) {
      throw StateError(
        'flutter ${args.first} exited with code $code before the app started.\n'
        'Last output:\n${d.tailLogs(40).join('\n')}',
      );
    });
    exitF.ignore();

    final DaemonEvent start = await Future.any<DaemonEvent>(<Future<DaemonEvent>>[startF, exitF]);
    appId = start.params['appId'] as String?;
    deviceId = start.params['deviceId'] as String?;
    final DaemonEvent port = await Future.any<DaemonEvent>(<Future<DaemonEvent>>[portF, exitF]);
    wsUri = port.params['wsUri'] as String?;
    await Future.any<DaemonEvent>(<Future<DaemonEvent>>[startedF, exitF]);
    final int launchMs = sw.elapsedMilliseconds;
    log?.call('App started in ${launchMs}ms, connecting to VM service $wsUri');

    _vm = await VmClient.connect(wsUri!, timeout: const Duration(seconds: 90));
    _vm!.onDone.then((_) {
      if (state == 'connected') {
        state = 'disconnected';
      }
    });
    final int connectMs = sw.elapsedMilliseconds - launchMs;
    dtdUri = await dtdF.timeout(const Duration(seconds: 2), onTimeout: () => null);
    state = 'connected';
    appInfo = await _waitForDriverReady(const Duration(seconds: 90));
    final Map<String, Object?> idle = await _vm!.call('waitIdle', <String, Object?>{'timeoutMs': 30000});
    _errorCursor = 0;
    return <String, Object?>{
      'appId': appId,
      'deviceId': deviceId,
      'wsUri': wsUri,
      'dtdUri': dtdUri,
      'app': appInfo,
      'idle': idle,
      'timings': <String, Object?>{
        'simBootMs': bootMs,
        phase: launchMs - bootMs,
        'vmConnectMs': connectMs,
        'totalMs': sw.elapsedMilliseconds,
      },
    };
  }

  /// Prefers the project's fvm SDK so the app builds with its pinned Flutter.
  String flutterFor(String projectRoot) {
    final String fvm = p.join(projectRoot, '.fvm', 'flutter_sdk', 'bin', 'flutter');
    return File(fvm).existsSync() ? fvm : flutterExecutable;
  }

  /// Polls `info` until the app has created its WidgetsBinding (big apps do
  /// async work before runApp).
  Future<Map<String, Object?>> _waitForDriverReady(Duration timeout) async {
    final Stopwatch sw = Stopwatch()..start();
    while (true) {
      final Map<String, Object?> info = await _vm!.call('info');
      if (info['ready'] == true) {
        return info;
      }
      if (sw.elapsed > timeout) {
        throw StateError('The app did not initialize WidgetsBinding within ${timeout.inSeconds}s.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  void _onAppStopped() {
    if (state != 'idle') {
      state = 'disconnected';
    }
  }

  Future<Map<String, Object?>> stop() async {
    final FlutterDaemon? d = _daemon;
    final VmClient? vm = _vm;
    _daemon = null;
    _vm = null;
    state = 'idle';
    final Stopwatch sw = Stopwatch()..start();
    if (vm != null) {
      await vm.dispose();
    }
    if (d != null) {
      if (d.isRunning && appId != null) {
        try {
          await d.call('app.stop', <String, Object?>{'appId': appId}, const Duration(seconds: 15));
        } catch (_) {}
      }
      await d.kill();
    }
    appId = null;
    wsUri = null;
    dtdUri = null;
    appInfo = null;
    return <String, Object?>{'stopped': d != null, 'totalMs': sw.elapsedMilliseconds};
  }

  Future<Map<String, Object?>> hotReload({bool full = false}) async {
    _requireConnected();
    final Stopwatch sw = Stopwatch()..start();
    final int errorsBefore = _vm!.errors.length;
    final Object? result = await _daemon!.call('app.restart', <String, Object?>{
      'appId': appId,
      'fullRestart': full,
      'reason': 'manual',
    });
    final int reloadMs = sw.elapsedMilliseconds;
    final Map<String, Object?> res = (result as Map?)?.cast<String, Object?>() ?? <String, Object?>{};
    if (res['code'] != 0) {
      throw StateError(
        '${full ? 'hot restart' : 'hot reload'} failed: ${res['message']}\n${_daemon!.tailLogs(20).join('\n')}',
      );
    }
    if (full) {
      // New isolate: wait for the driver to re-register.
      await _vm!.resolveIsolate(timeout: const Duration(seconds: 30));
    }
    final Map<String, Object?> idle = await _vm!.call('waitIdle', <String, Object?>{'timeoutMs': 10000});
    return <String, Object?>{
      'kind': full ? 'hot_restart' : 'hot_reload',
      'message': res['message'],
      'idle': idle,
      'runtimeErrorsDuringStep': _vm!.errors.skip(errorsBefore).map((RuntimeError e) => e.toJson()).toList(),
      'timings': <String, Object?>{'reloadMs': reloadMs, 'totalMs': sw.elapsedMilliseconds},
    };
  }

  // ---------------------------------------------------------------- actions

  /// Forwards to `ext.aiDriver.<name>` and annotates the result with the
  /// round-trip time and any runtime errors raised while it ran.
  Future<Map<String, Object?>> act(String name, [Map<String, Object?> args = const <String, Object?>{}]) async {
    _requireConnected();
    final Stopwatch sw = Stopwatch()..start();
    final int errorsBefore = _vm!.errors.length;
    final Map<String, Object?> result = await _vm!.call(name, args);
    result['roundTripMs'] = sw.elapsedMilliseconds;
    final List<RuntimeError> during = _vm!.errors.skip(errorsBefore).toList();
    if (during.isNotEmpty) {
      result['runtimeErrorsDuringStep'] = during.map((RuntimeError e) => e.toJson()).toList();
    }
    return result;
  }

  /// Takes a screenshot, saves it under the system temp dir, and returns the
  /// PNG bytes plus metadata (without the base64 payload).
  Future<({List<int> png, Map<String, Object?> meta})> screenshot({double scale = 0.5}) async {
    final Map<String, Object?> r = await act('screenshot', <String, Object?>{'scale': scale});
    final List<int> png = base64Decode(r.remove('base64') as String);
    _shotDir ??= Directory(
      p.join(Directory.systemTemp.path, 'flutter_pilot', DateTime.now().toIso8601String().replaceAll(':', '-')),
    )..createSync(recursive: true);
    final File f = File(p.join(_shotDir!.path, '${(_shotCounter++).toString().padLeft(3, '0')}.png'));
    await f.writeAsBytes(png);
    r['path'] = f.path;
    return (png: png, meta: r);
  }

  List<Map<String, Object?>> runtimeErrors({bool clear = false, bool onlyNew = false}) {
    final VmClient? vm = _vm;
    if (vm == null) {
      return const <Map<String, Object?>>[];
    }
    final List<RuntimeError> list = onlyNew ? vm.errors.skip(_errorCursor).toList() : vm.errors;
    final List<Map<String, Object?>> out = list.map((RuntimeError e) => e.toJson()).toList();
    _errorCursor = vm.errors.length;
    if (clear) {
      vm.errors.clear();
      _errorCursor = 0;
    }
    return out;
  }

  List<String> appLogs(int tail) => _daemon?.tailLogs(tail) ?? const <String>[];

  void _requireConnected() {
    if (!isConnected) {
      throw StateError('No connected app (state=$state). Call launch_app first.');
    }
  }
}
