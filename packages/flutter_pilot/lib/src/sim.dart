import 'dart:convert';
import 'dart:io';

final RegExp _udid = RegExp(r'^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$');

/// Minimal, allow-listed simulator control. Only `list`, `boot` and
/// `bootstatus` are ever invoked, and only for the device the session was
/// given.
class SimAdapter {
  static bool isIosSimulatorId(String device) => _udid.hasMatch(device);

  /// Returns `{udid: state}` for every available iOS simulator.
  static Future<Map<String, Map<String, Object?>>> listIos() async {
    if (!Platform.isMacOS) {
      return <String, Map<String, Object?>>{};
    }
    final ProcessResult r = await Process.run('xcrun', <String>['simctl', 'list', 'devices', 'available', '-j']);
    if (r.exitCode != 0) {
      return <String, Map<String, Object?>>{};
    }
    final Map<String, Object?> json = (jsonDecode(r.stdout as String) as Map).cast<String, Object?>();
    final Map<String, Map<String, Object?>> out = <String, Map<String, Object?>>{};
    final Map<String, Object?> devices = (json['devices'] as Map?)?.cast<String, Object?>() ?? <String, Object?>{};
    devices.forEach((String runtime, Object? list) {
      for (final Object? d in (list as List?) ?? <Object?>[]) {
        final Map<String, Object?> m = (d as Map).cast<String, Object?>();
        final String? udid = m['udid'] as String?;
        if (udid == null) {
          continue;
        }
        out[udid] = <String, Object?>{'name': m['name'], 'state': m['state'], 'runtime': runtime.split('.').last};
      }
    });
    return out;
  }

  /// Starts an installed app so `flutter attach` has something to attach to.
  /// Android goes through adb (`monkey` finds the launcher activity without
  /// knowing its name); iOS simulators through simctl. `clearData` wipes the
  /// app's storage first, which is how an onboarding flow gets re-run
  /// without a rebuild; it is Android-only, simctl has no equivalent short of
  /// reinstalling.
  static Future<Map<String, Object?>> startApp(String device, String appId, {bool clearData = false}) async {
    final Stopwatch sw = Stopwatch()..start();
    if (isIosSimulatorId(device)) {
      if (clearData) {
        throw UnsupportedError(
          'clearData is not supported on iOS simulators (simctl cannot clear app data; uninstall instead)',
        );
      }
      final ProcessResult r = await Process.run('xcrun', <String>['simctl', 'launch', device, appId]);
      if (r.exitCode != 0) {
        throw StateError('simctl launch $appId failed: ${r.stderr}');
      }
      return <String, Object?>{'started': appId, 'startMs': sw.elapsedMilliseconds};
    }
    if (clearData) {
      final ProcessResult clear = await Process.run('adb', <String>['-s', device, 'shell', 'pm', 'clear', appId]);
      if (clear.exitCode != 0 || !(clear.stdout as String).contains('Success')) {
        throw StateError('adb pm clear $appId failed: ${clear.stdout}${clear.stderr}');
      }
    }
    final ProcessResult r = await Process.run('adb', <String>[
      '-s',
      device,
      'shell',
      'monkey',
      '-p',
      appId,
      '-c',
      'android.intent.category.LAUNCHER',
      '1',
    ]);
    if (r.exitCode != 0 || (r.stdout as String).contains('No activities found')) {
      throw StateError('Could not start $appId on $device: ${r.stdout}${r.stderr}');
    }
    return <String, Object?>{'started': appId, 'cleared': clearData, 'startMs': sw.elapsedMilliseconds};
  }

  /// Boots the simulator if it is shut down and waits until it is usable.
  /// Returns the time spent, 0 if it was already booted or not an iOS sim.
  static Future<int> ensureBooted(String device, {void Function(String)? log}) async {
    if (!isIosSimulatorId(device)) {
      return 0;
    }
    final Stopwatch sw = Stopwatch()..start();
    final Map<String, Map<String, Object?>> sims = await listIos();
    final Map<String, Object?>? sim = sims[device];
    if (sim == null) {
      throw StateError('No available iOS simulator with UDID $device. Use list_devices.');
    }
    if (sim['state'] == 'Booted') {
      return 0;
    }
    log?.call('Booting simulator ${sim['name']} ($device)…');
    final ProcessResult boot = await Process.run('xcrun', <String>['simctl', 'boot', device]);
    if (boot.exitCode != 0 && !(boot.stderr as String).contains('Unable to boot device in current state: Booted')) {
      throw StateError('simctl boot failed: ${boot.stderr}');
    }
    await Process.run('xcrun', <String>['simctl', 'bootstatus', device, '-b']);
    // Show the window so a human can watch; harmless if already open.
    await Process.run('open', <String>['-a', 'Simulator']);
    return sw.elapsedMilliseconds;
  }
}
