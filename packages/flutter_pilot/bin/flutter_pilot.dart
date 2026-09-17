import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:flutter_pilot/flutter_pilot.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> argv) async {
  final ArgParser parser = ArgParser()
    ..addOption('flutter', help: 'Path to the flutter executable (default: project .fvm SDK, else auto-detect).')
    ..addFlag('help', abbr: 'h', negatable: false);
  parser.addCommand('mcp');
  parser.addCommand('devices');
  parser.addCommand('smoke')
    ..addOption('root', help: 'Flutter project to launch (default: example/counter next to this package).')
    ..addOption('device', help: 'Device id (default: first available iPhone simulator).')
    ..addOption('target', defaultsTo: 'test_driver/ai_app.dart')
    ..addOption('taps', defaultsTo: '20');
  parser.addCommand('flow')
    ..addOption('root', help: 'Flutter project to launch.', mandatory: true)
    ..addOption(
      'file',
      help: 'Flow JSON file, relative to root (e.g. test_driver/flows/count_and_greet.json).',
      mandatory: true,
    )
    ..addOption('device', help: 'Device id (default: first available iPhone simulator).')
    ..addOption('target', defaultsTo: 'test_driver/ai_app.dart')
    ..addOption('flavor', help: 'Passed as --flavor.')
    ..addOption('defines', help: 'Passed as --dart-define-from-file (relative to root).')
    ..addMultiOption('var', help: 'Flow variable, name=value. Repeatable.');
  parser.addCommand('run')
    ..addOption('root', help: 'Flutter project to launch.', mandatory: true)
    ..addOption('device', help: 'Device id (default: first available iPhone simulator).')
    ..addOption('target', defaultsTo: 'test_driver/ai_app.dart')
    ..addOption('flavor', help: 'Passed as --flavor.')
    ..addOption('defines', help: 'Passed as --dart-define-from-file (relative to root).')
    ..addFlag(
      'hold',
      defaultsTo: true,
      help: 'Keep the app running until Enter / Ctrl-C (off when stdin is not a terminal).',
    );

  final ArgResults args = parser.parse(argv);
  if (args['help'] == true || args.command == null) {
    stderr.writeln('usage: flutter_pilot [--flutter <path>] <mcp|run|flow|smoke|devices> [options]\n${parser.usage}');
    stderr.writeln('\nrun options:\n${parser.commands['run']!.usage}');
    stderr.writeln('\nflow options:\n${parser.commands['flow']!.usage}');
    stderr.writeln('\nsmoke options:\n${parser.commands['smoke']!.usage}');
    exitCode = args.command == null ? 64 : 0;
    return;
  }
  final String flutter = await resolveFlutter(args['flutter'] as String?);

  switch (args.command!.name) {
    case 'mcp':
      // stdout is the MCP transport: never print to it.
      final PilotSession session = PilotSession(flutterExecutable: flutter, log: stderr.writeln);
      PilotServer(
        stdioChannel(input: stdin, output: stdout),
        session: session,
      );
      ProcessSignal.sigterm.watch().listen((_) async {
        await session.stop();
        exit(0);
      });
      return;
    case 'devices':
      final Map<String, Map<String, Object?>> sims = await SimAdapter.listIos();
      for (final MapEntry<String, Map<String, Object?>> e in sims.entries) {
        stdout.writeln(
          '${e.key}  ${e.value['state']!.toString().padRight(9)} ${e.value['runtime']}  ${e.value['name']}',
        );
      }
      return;
    case 'smoke':
      final ArgResults s = args.command!;
      final String root = s['root'] as String? ?? _defaultExampleRoot();
      final String device = s['device'] as String? ?? await _firstIphone();
      final PilotSession session = PilotSession(flutterExecutable: flutter, log: stderr.writeln);
      exitCode = await runSmoke(
        session: session,
        root: root,
        device: device,
        target: s['target'] as String,
        taps: int.parse(s['taps'] as String),
      );
      return;
    case 'run':
      exitCode = await _run(args.command!, flutter);
      return;
    case 'flow':
      exitCode = await _flow(args.command!, flutter);
      return;
  }
}

/// Launches an app, runs one flow file, prints the compact result, stops.
Future<int> _flow(ArgResults s, String flutter) async {
  final String root = p.normalize(p.absolute(s['root'] as String));
  final String device = s['device'] as String? ?? await _firstIphone();
  final Map<String, Object?> vars = <String, Object?>{
    for (final String kv in s['var'] as List<String>)
      if (kv.contains('=')) kv.substring(0, kv.indexOf('=')): kv.substring(kv.indexOf('=') + 1),
  };
  final PilotSession session = PilotSession(flutterExecutable: flutter, log: stderr.writeln);
  final Stopwatch sw = Stopwatch()..start();
  try {
    try {
      await session.launch(
        projectRoot: root,
        device: device,
        target: s['target'] as String,
        flavor: s['flavor'] as String?,
        definesFile: s['defines'] as String?,
      );
    } catch (e) {
      stderr.writeln('launch failed: $e');
      return 1;
    }
    stderr.writeln('launched in ${sw.elapsedMilliseconds}ms, running ${s['file']}');
    final Stopwatch flowSw = Stopwatch()..start();
    final Map<String, Object?> result = await FlowRunner(session).run(file: s['file'] as String, vars: vars);
    stderr.writeln(const JsonEncoder.withIndent('  ').convert(result));
    stderr.writeln('flow took ${flowSw.elapsedMilliseconds}ms');
    return result['ok'] == true ? 0 : 1;
  } finally {
    await session.stop();
  }
}

/// Launches an app, prints what the driver sees, saves a screenshot, and
/// optionally keeps it running so a human can poke at it or attach Claude Code.
Future<int> _run(ArgResults s, String flutter) async {
  final String root = p.normalize(p.absolute(s['root'] as String));
  final String device = s['device'] as String? ?? await _firstIphone();
  final PilotSession session = PilotSession(flutterExecutable: flutter, log: stderr.writeln);
  final Stopwatch sw = Stopwatch()..start();
  late final StreamSubscription<ProcessSignal> sigint;
  sigint = ProcessSignal.sigint.watch().listen((_) async {
    stderr.writeln('\nstopping…');
    await session.stop();
    exit(130);
  });
  try {
    final Map<String, Object?> launch;
    try {
      launch = await session.launch(
        projectRoot: root,
        device: device,
        target: s['target'] as String,
        flavor: s['flavor'] as String?,
        definesFile: s['defines'] as String?,
      );
    } catch (e) {
      stderr.writeln('launch failed: $e');
      return 1;
    }
    stderr.writeln(
      'launched in ${sw.elapsedMilliseconds}ms: ${const JsonEncoder.withIndent('  ').convert(launch['timings'])}',
    );
    stderr.writeln('app: ${launch['app']}');
    stderr.writeln('idle: ${launch['idle']}');
    // Big apps show a splash first: give the first real route up to 20s.
    Map<String, Object?> route = await session.act('currentRoute');
    final Stopwatch splash = Stopwatch()..start();
    while (route['route'] == null && splash.elapsed < const Duration(seconds: 20)) {
      await Future<void>.delayed(const Duration(seconds: 1));
      await session.act('waitIdle', <String, Object?>{'timeoutMs': 5000});
      route = await session.act('currentRoute');
    }
    stderr.writeln('route: ${route['route']} (${route['routeType']}) after ${splash.elapsedMilliseconds}ms');
    final Map<String, Object?> tree = await session.act('tree');
    final List<String> lines = (tree['text'] as String).split('\n');
    stderr.writeln('tree (${tree['nodes']} nodes, ${tree['roundTripMs']}ms):');
    stderr.writeln(lines.take(60).join('\n'));
    if (lines.length > 60) {
      stderr.writeln('  … ${lines.length - 60} more lines');
    }
    final ({List<int> png, Map<String, Object?> meta}) shot = await session.screenshot();
    stderr.writeln(
      'screenshot: ${shot.meta['path']} (${shot.meta['width']}x${shot.meta['height']}, ${shot.meta['roundTripMs']}ms)',
    );
    final List<Map<String, Object?>> errs = session.runtimeErrors();
    stderr.writeln('runtime errors so far: ${errs.length}');
    for (final Map<String, Object?> e in errs.take(5)) {
      stderr.writeln('  - ${(e['text'] ?? '').toString().split('\n').first}');
    }
    final bool hold = (s['hold'] as bool) && stdin.hasTerminal;
    if (hold) {
      stderr.writeln('\nApp is running. Press Enter to stop.');
      await stdin.transform(utf8.decoder).transform(const LineSplitter()).firstWhere((_) => true, orElse: () => '');
    }
    return errs.isEmpty ? 0 : 2;
  } finally {
    await sigint.cancel();
    await session.stop();
  }
}

String _defaultExampleRoot() {
  // <repo>/packages/flutter_pilot/bin/flutter_pilot.dart -> <repo>/example/counter
  final String script = Platform.script.toFilePath();
  final String repo = p.normalize(p.join(p.dirname(script), '..', '..', '..'));
  return p.join(repo, 'example', 'counter');
}

Future<String> _firstIphone() async {
  final Map<String, Map<String, Object?>> sims = await SimAdapter.listIos();
  final Iterable<MapEntry<String, Map<String, Object?>>> iphones = sims.entries.where(
    (MapEntry<String, Map<String, Object?>> e) => '${e.value['name']}'.startsWith('iPhone'),
  );
  final MapEntry<String, Map<String, Object?>>? booted = iphones
      .where((MapEntry<String, Map<String, Object?>> e) => e.value['state'] == 'Booted')
      .firstOrNull;
  final MapEntry<String, Map<String, Object?>>? pick = booted ?? iphones.firstOrNull;
  if (pick == null) {
    throw StateError('No iPhone simulator available; pass --device.');
  }
  stderr.writeln('Using simulator ${pick.value['name']} (${pick.key}, ${pick.value['state']})');
  return pick.key;
}
