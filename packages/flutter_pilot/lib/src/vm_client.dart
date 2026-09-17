import 'dart:async';
import 'dart:convert';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

const String kInfoExtension = 'ext.aiDriver.info';

class RuntimeError {
  RuntimeError(this.at, this.text, this.data);

  final DateTime at;
  final String text;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toIso8601String(),
    'text': text,
    if (data['library'] != null) 'library': data['library'],
    if (data['errorsSinceReload'] != null) 'errorsSinceReload': data['errorsSinceReload'],
  };
}

/// Raised when the in-app driver returns `{ok:false}`.
class AiDriverCallException implements Exception {
  AiDriverCallException(this.code, this.message, this.data);

  final String code;
  final String message;
  final Map<String, Object?> data;

  @override
  String toString() => '$code: $message';
}

/// VM service connection to the app, scoped to the isolate that registered
/// `ext.aiDriver.*`.
class VmClient {
  VmClient._(this.service, this.wsUri);

  final VmService service;
  final String wsUri;

  String? _isolateId;
  final List<RuntimeError> errors = <RuntimeError>[];
  final List<String> stderr = <String>[];
  final List<StreamSubscription<Event>> _subs = <StreamSubscription<Event>>[];
  final Completer<void> _done = Completer<void>();

  String? get isolateId => _isolateId;
  Future<void> get onDone => _done.future;
  bool get isConnected => !_done.isCompleted;

  static Future<VmClient> connect(String wsUri, {Duration timeout = const Duration(seconds: 60)}) async {
    final VmService service = await vmServiceConnectUri(wsUri);
    final VmClient c = VmClient._(service, wsUri);
    service.onDone.then((_) {
      if (!c._done.isCompleted) {
        c._done.complete();
      }
    });
    await c._listen();
    await c.resolveIsolate(timeout: timeout);
    return c;
  }

  Future<void> _listen() async {
    for (final String stream in <String>[EventStreams.kExtension, EventStreams.kIsolate, EventStreams.kStderr]) {
      try {
        await service.streamListen(stream);
      } catch (_) {
        // Already listening or unsupported; not fatal.
      }
    }
    _subs.add(
      service.onExtensionEvent.listen((Event e) {
        if (e.extensionKind == 'Flutter.Error') {
          final Map<String, Object?> data = (e.extensionData?.data ?? <String, Object?>{}).cast<String, Object?>();
          final String text = (data['renderedErrorText'] ?? data['description'] ?? data['exception'] ?? '').toString();
          errors.add(RuntimeError(DateTime.now(), text, data));
          if (errors.length > 200) {
            errors.removeAt(0);
          }
        }
      }),
    );
    _subs.add(
      service.onStderrEvent.listen((Event e) {
        final String? b = e.bytes;
        if (b != null) {
          stderr.add(utf8.decode(base64.decode(b), allowMalformed: true));
          if (stderr.length > 500) {
            stderr.removeAt(0);
          }
        }
      }),
    );
    _subs.add(
      service.onIsolateEvent.listen((Event e) {
        if (e.kind == EventKind.kServiceExtensionAdded && e.extensionRPC == kInfoExtension) {
          _isolateId = e.isolate?.id;
        } else if (e.kind == EventKind.kIsolateExit && e.isolate?.id == _isolateId) {
          _isolateId = null;
        }
      }),
    );
  }

  /// Finds the isolate that registered the driver, polling until [timeout].
  Future<String> resolveIsolate({Duration timeout = const Duration(seconds: 30)}) async {
    final Stopwatch sw = Stopwatch()..start();
    while (true) {
      try {
        final VM vm = await service.getVM();
        for (final IsolateRef ref in vm.isolates ?? <IsolateRef>[]) {
          final String? id = ref.id;
          if (id == null) {
            continue;
          }
          try {
            final Isolate iso = await service.getIsolate(id);
            if (iso.extensionRPCs?.contains(kInfoExtension) ?? false) {
              _isolateId = id;
              return id;
            }
          } catch (_) {
            // Isolate went away between getVM and getIsolate.
          }
        }
      } catch (_) {
        // Connection hiccup; retry until timeout.
      }
      if (_isolateId != null) {
        return _isolateId!;
      }
      if (sw.elapsed > timeout) {
        throw TimeoutException(
          '$kInfoExtension is not registered in any isolate after ${timeout.inSeconds}s. '
          'Is enableAiDriver() called before runApp() in the launched entrypoint?',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

  /// Calls `ext.aiDriver.<name>` with JSON-encoded [args].
  Future<Map<String, Object?>> call(String name, [Map<String, Object?> args = const <String, Object?>{}]) async {
    String iso = _isolateId ?? await resolveIsolate(timeout: const Duration(seconds: 15));
    Response r;
    try {
      r = await service.callServiceExtension(
        'ext.aiDriver.$name',
        isolateId: iso,
        args: <String, dynamic>{'args': jsonEncode(args)},
      );
    } on RPCError catch (e) {
      // Isolate replaced (hot restart) or not yet runnable: resolve once more.
      if (e.code == RPCErrorKind.kInvalidParams.code ||
          e.code == RPCErrorKind.kIsolateMustBeRunnable.code ||
          e.code == RPCErrorKind.kMethodNotFound.code ||
          e.message.contains('Isolate') ||
          e.message.contains('isolate')) {
        _isolateId = null;
        iso = await resolveIsolate(timeout: const Duration(seconds: 15));
        r = await service.callServiceExtension(
          'ext.aiDriver.$name',
          isolateId: iso,
          args: <String, dynamic>{'args': jsonEncode(args)},
        );
      } else {
        rethrow;
      }
    }
    final Map<String, Object?> json = (r.json ?? <String, Object?>{}).cast<String, Object?>();
    if (json['ok'] != true) {
      throw AiDriverCallException(
        (json['code'] ?? 'UNKNOWN').toString(),
        (json['message'] ?? 'unknown error from ext.aiDriver.$name').toString(),
        json,
      );
    }
    json.remove('type'); // vm_service adds a type tag
    return json;
  }

  Future<void> dispose() async {
    for (final StreamSubscription<Event> s in _subs) {
      await s.cancel();
    }
    try {
      await service.dispose();
    } catch (_) {}
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}
