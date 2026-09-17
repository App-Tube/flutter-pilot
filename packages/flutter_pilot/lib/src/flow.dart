import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'session.dart';
import 'vm_client.dart';

/// Runs a whole list of UI steps against the connected app in one call.
///
/// The slow part of driving an app from a model is not the tap, it is the
/// round trip: look, think, act, thirty times over. A flow moves the loop
/// into the server: the model sends the steps it already knows, gets back
/// one compact result, and only has to think again when a step fails, at
/// which point the result carries the screen it failed on.
///
/// Steps are maps (`{"action": "tap", "finder": "label:Next"}`) or the
/// shorthand string `"tap label:Next"`; see [FlowStep.parse]. A flow can also
/// be loaded from a JSON file checked into the app repo, so a known journey
/// (onboarding, login) is one call with zero rediscovery.
class FlowRunner {
  FlowRunner(this.session);

  final PilotSession session;

  static const Duration pollInterval = Duration(milliseconds: 100);

  /// Settle cap for flow steps unless the flow or the step says otherwise.
  static const int defaultSettleMs = 800;

  Future<Map<String, Object?>> run({
    List<Object?>? steps,
    String? file,
    Map<String, Object?> vars = const <String, Object?>{},
    Map<String, Object?> defaults = const <String, Object?>{},
    bool stopOnError = true,
  }) async {
    final Stopwatch sw = Stopwatch()..start();
    final _FlowSource src = _FlowSource.load(steps: steps, file: file, root: session.root);
    final Map<String, Object?> allVars = <String, Object?>{...src.vars, ...vars};
    // A flow synchronises with wait_for / expect_route, so a step does not
    // need the full single-tap settle budget: a screen that is still loading
    // data keeps starting animations for seconds, and waiting for that after
    // every tap was the remaining cost of a run.
    final Map<String, Object?> allDefaults = <String, Object?>{
      'settleTimeoutMs': defaultSettleMs,
      ...src.defaults,
      ...defaults,
    };
    final List<FlowStep> parsed = <FlowStep>[];
    for (int i = 0; i < src.steps.length; i++) {
      parsed.add(FlowStep.parse(src.steps[i], i, allVars, allDefaults));
    }

    final List<Map<String, Object?>> results = <Map<String, Object?>>[];
    final Map<String, Object?> captured = <String, Object?>{};
    final int errorsBefore = session.runtimeErrors(onlyNew: true).length;
    Map<String, Object?>? failure;
    int? failedAt;

    for (final FlowStep step in parsed) {
      final Stopwatch stepSw = Stopwatch()..start();
      final Map<String, Object?> out = <String, Object?>{'i': step.index, 'step': step.describe()};
      try {
        for (int n = 0; n < step.repeat; n++) {
          final Map<String, Object?> r = await _execute(step, captured);
          if (n == step.repeat - 1) {
            out.addAll(r);
          }
        }
        out['ok'] = true;
      } on AiDriverCallException catch (e) {
        if (step.optional && _isAbsence(e.code)) {
          out['ok'] = true;
          out['skipped'] = true;
          out['reason'] = e.code;
        } else {
          out['ok'] = false;
          failure = _compactError(e.code, e.message, e.data);
        }
      } on _StepFailure catch (e) {
        if (step.optional) {
          out['ok'] = true;
          out['skipped'] = true;
          out['reason'] = e.code;
        } else {
          out['ok'] = false;
          failure = <String, Object?>{'code': e.code, 'message': e.message, ...e.data};
        }
      } catch (e) {
        out['ok'] = false;
        failure = <String, Object?>{'code': 'INTERNAL', 'message': '$e'};
      }
      out['ms'] = stepSw.elapsedMilliseconds;
      results.add(out);
      if (failure != null) {
        failedAt = step.index;
        if (stopOnError) {
          break;
        }
        failure = null;
      }
    }

    final Map<String, Object?> result = <String, Object?>{
      'ok': failedAt == null,
      if (src.name != null) 'flow': src.name,
      'steps': results,
      'stepsRun': results.length,
      'stepsTotal': parsed.length,
      if (captured.isNotEmpty) 'captured': captured,
      'totalMs': sw.elapsedMilliseconds,
    };
    if (failedAt != null) {
      result['failedStep'] = failedAt;
      result['error'] = failure ?? results.lastWhere((Map<String, Object?> r) => r['ok'] == false)['error'];
      // The model has to think now: give it what it would ask for next.
      try {
        result['screen'] = await session.act('screen');
      } catch (e) {
        result['screen'] = <String, Object?>{'unavailable': '$e'};
      }
    }
    final List<Map<String, Object?>> errs = session.runtimeErrors(onlyNew: true);
    if (errs.length > errorsBefore) {
      result['runtimeErrorsDuringFlow'] = errs.skip(errorsBefore).toList();
    }
    return result;
  }

  /// What `optional` forgives: the target not being there. An ambiguous or
  /// obscured target is there, so that still fails.
  static bool _isAbsence(String code) => code == 'NOT_FOUND' || code == 'TIMEOUT';

  static Map<String, Object?> _compactError(String code, String message, Map<String, Object?> data) {
    final Map<String, Object?> d = Map<String, Object?>.of(data)
      ..remove('ok')
      ..remove('stack')
      ..remove('totalMs')
      ..remove('code')
      ..remove('message');
    return <String, Object?>{'code': code, 'message': message, ...d};
  }

  Future<Map<String, Object?>> _execute(FlowStep s, Map<String, Object?> captured) async {
    switch (s.action) {
      case 'tap':
      case 'long_press':
      case 'drag':
      case 'scroll_into_view':
        final Map<String, Object?> r = await session.act(_actName[s.action]!, s.actionArgs());
        return _slim(r);
      case 'enter_text':
        final Map<String, Object?> r = await session.act('enterText', s.actionArgs());
        return _slim(r);
      case 'keypad':
        // A PIN pad is not a text field: each digit is its own button. Tap
        // them one by one; the finder is a template with {c} for the digit.
        // Only the last digit gets the settle wait: that is the one that
        // may navigate. Waiting out the ink ripple after each of the others
        // is what a human never does either.
        final String text = s.args['text'] as String;
        final String template = s.finder ?? 'text:{c}';
        final List<String> chars = text.split('');
        Map<String, Object?> last = <String, Object?>{};
        for (int i = 0; i < chars.length; i++) {
          last = await session.act('tap', <String, Object?>{
            ...s.actionArgs(),
            'finder': template.replaceAll('{c}', chars[i]),
            if (i < chars.length - 1) 'settleTimeoutMs': 0,
          });
        }
        return <String, Object?>{'taps': text.length, ..._slim(last)};
      case 'back':
        return _slim(await session.act('back'));
      case 'wait':
        await Future<void>.delayed(Duration(milliseconds: s.ms ?? 500));
        return <String, Object?>{};
      case 'wait_idle':
        final Map<String, Object?> r = await session.act('waitIdle', <String, Object?>{
          'timeoutMs': s.timeoutMs ?? 2000,
          if (s.args['steadyMs'] != null) 'steadyMs': s.args['steadyMs'],
        });
        return <String, Object?>{'settled': r['settled'], 'idle': r['idle']};
      case 'wait_for':
      case 'wait_gone':
        return _pollFinder(s, gone: s.action == 'wait_gone');
      case 'expect':
        final Map<String, Object?> r = await session.act('find', <String, Object?>{'finder': s.finder});
        final int count = (r['count'] as num).toInt();
        final bool absent = s.args['absent'] == true;
        if (absent ? count != 0 : count == 0) {
          throw _StepFailure(
            absent ? 'UNEXPECTED_PRESENT' : 'NOT_FOUND',
            absent ? '${s.finder} is on screen but should not be' : 'No widget matches ${s.finder}',
            <String, Object?>{'count': count},
          );
        }
        return <String, Object?>{'count': count};
      case 'expect_route':
        return _pollRoute(s);
      case 'get_text':
        final Map<String, Object?> r = await session.act('getText', s.actionArgs());
        captured[s.captureName] = r['text'];
        return <String, Object?>{'text': r['text']};
      case 'clipboard':
        final Map<String, Object?> r = await session.act('clipboard');
        captured[s.captureName] = r['text'];
        return <String, Object?>{'text': r['text']};
      case 'screen':
        final Map<String, Object?> r = await session.act('screen', <String, Object?>{
          if (s.args['maxItems'] != null) 'maxItems': s.args['maxItems'],
        });
        return <String, Object?>{'screen': r};
      case 'screenshot':
        final ({List<int> png, Map<String, Object?> meta}) shot = await session.screenshot(
          scale: (s.args['scale'] as num?)?.toDouble() ?? 0.5,
        );
        return <String, Object?>{'path': shot.meta['path']};
      case 'hot_reload':
        final Map<String, Object?> r = await session.hotReload();
        return <String, Object?>{'message': r['message']};
      case 'hot_restart':
        final Map<String, Object?> r = await session.hotReload(full: true);
        return <String, Object?>{'message': r['message']};
      default:
        throw _StepFailure('BAD_STEP', 'Unknown action "${s.action}" (known: ${FlowStep.actions.join(', ')})');
    }
  }

  static const Map<String, String> _actName = <String, String>{
    'tap': 'tap',
    'long_press': 'longPress',
    'drag': 'drag',
    'scroll_into_view': 'scrollIntoView',
  };

  /// Keeps what a model needs from an action result and drops the timings
  /// and settle detail it would only skim.
  static Map<String, Object?> _slim(Map<String, Object?> r) {
    final Map<String, Object?> settle = (r['settle'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    return <String, Object?>{
      if (r['target'] is Map && (r['target'] as Map)['type'] != null) 'target': (r['target'] as Map)['type'],
      if (settle['settled'] == false) 'notSettled': settle['reason'],
      if (r['popped'] != null) 'popped': r['popped'],
    };
  }

  Future<Map<String, Object?>> _pollFinder(FlowStep s, {required bool gone}) async {
    final Duration timeout = Duration(milliseconds: s.timeoutMs ?? 5000);
    final Stopwatch sw = Stopwatch()..start();
    int count = -1;
    while (true) {
      final Map<String, Object?> r = await session.act('find', <String, Object?>{'finder': s.finder});
      count = (r['count'] as num).toInt();
      if (gone ? count == 0 : count > 0) {
        return <String, Object?>{'count': count, 'waitedMs': sw.elapsedMilliseconds};
      }
      if (sw.elapsed >= timeout) {
        throw _StepFailure(
          'TIMEOUT',
          gone
              ? '${s.finder} still on screen after ${timeout.inMilliseconds}ms'
              : '${s.finder} did not appear within ${timeout.inMilliseconds}ms',
          <String, Object?>{'count': count},
        );
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  Future<Map<String, Object?>> _pollRoute(FlowStep s) async {
    final Duration timeout = Duration(milliseconds: s.timeoutMs ?? 3000);
    final Stopwatch sw = Stopwatch()..start();
    String? actual;
    while (true) {
      final Map<String, Object?> r = await session.act('currentRoute');
      actual = r['route'] as String?;
      if (actual == s.route) {
        return <String, Object?>{'route': actual, 'waitedMs': sw.elapsedMilliseconds};
      }
      if (sw.elapsed >= timeout) {
        throw _StepFailure(
          'ROUTE_MISMATCH',
          'Expected route ${s.route}, on $actual after ${timeout.inMilliseconds}ms',
          <String, Object?>{'expected': s.route, 'actual': actual},
        );
      }
      await Future<void>.delayed(pollInterval);
    }
  }
}

class _StepFailure implements Exception {
  _StepFailure(this.code, this.message, [this.data = const <String, Object?>{}]);

  final String code;
  final String message;
  final Map<String, Object?> data;

  @override
  String toString() => '$code: $message';
}

/// Where the steps came from: an inline list, or a JSON file that may also
/// carry `name`, `vars` and `defaults`.
class _FlowSource {
  _FlowSource(
    this.steps, {
    this.name,
    this.vars = const <String, Object?>{},
    this.defaults = const <String, Object?>{},
  });

  final List<Object?> steps;
  final String? name;
  final Map<String, Object?> vars;
  final Map<String, Object?> defaults;

  static _FlowSource load({List<Object?>? steps, String? file, String? root}) {
    if (file == null) {
      if (steps == null || steps.isEmpty) {
        throw ArgumentError('run_flow needs "steps" or "file"');
      }
      return _FlowSource(steps);
    }
    final String path = p.isAbsolute(file) ? file : p.join(root ?? Directory.current.path, file);
    final File f = File(path);
    if (!f.existsSync()) {
      throw ArgumentError('Flow file not found: $path');
    }
    final Object? json = jsonDecode(f.readAsStringSync());
    if (json is List) {
      return _FlowSource(json, name: p.basenameWithoutExtension(path));
    }
    if (json is Map) {
      final Map<String, Object?> m = json.cast<String, Object?>();
      final List<Object?> fileSteps = (m['steps'] as List?) ?? const <Object?>[];
      return _FlowSource(
        <Object?>[...fileSteps, ...?steps],
        name: m['name'] as String? ?? p.basenameWithoutExtension(path),
        vars: (m['vars'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{},
        defaults: (m['defaults'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{},
      );
    }
    throw ArgumentError('Flow file must hold a JSON list of steps or {"steps": [...]}: $path');
  }
}

/// One parsed step.
class FlowStep {
  FlowStep._(this.index, this.action, this.args, {this.repeat = 1, this.optional = false});

  final int index;
  final String action;
  final Map<String, Object?> args;
  final int repeat;
  final bool optional;

  static const List<String> actions = <String>[
    'tap',
    'long_press',
    'drag',
    'scroll_into_view',
    'enter_text',
    'keypad',
    'back',
    'wait',
    'wait_idle',
    'wait_for',
    'wait_gone',
    'expect',
    'expect_route',
    'get_text',
    'clipboard',
    'screen',
    'screenshot',
    'hot_reload',
    'hot_restart',
  ];

  static const Set<String> _needsFinder = <String>{
    'tap',
    'long_press',
    'drag',
    'scroll_into_view',
    'enter_text',
    'wait_for',
    'wait_gone',
    'expect',
    'get_text',
  };

  String? get finder => args['finder'] as String?;
  String? get route => args['route'] as String?;
  int? get ms => (args['ms'] as num?)?.toInt();
  int? get timeoutMs => (args['timeoutMs'] as num?)?.toInt();
  String get captureName => (args['as'] as String?) ?? 'step$index';

  /// Arguments forwarded to the in-app action, with the flow-level defaults
  /// (settleTimeoutMs, steadyMs) filled in where the step has none.
  Map<String, Object?> actionArgs() => <String, Object?>{
    'finder': finder,
    if (args['index'] != null) 'index': args['index'],
    if (args['text'] != null) 'text': args['text'],
    if (args['submit'] != null) 'submit': args['submit'],
    if (args['dx'] != null) 'dx': args['dx'],
    if (args['dy'] != null) 'dy': args['dy'],
    if (args['settleTimeoutMs'] != null) 'settleTimeoutMs': args['settleTimeoutMs'],
    if (args['steadyMs'] != null) 'steadyMs': args['steadyMs'],
  };

  String describe() {
    final StringBuffer sb = StringBuffer();
    if (optional) {
      sb.write('?');
    }
    sb.write(action);
    if (finder != null) {
      sb.write(' $finder');
    }
    if (route != null) {
      sb.write(' $route');
    }
    if (args['text'] != null) {
      sb.write(' :: ${args['text']}');
    }
    if (action == 'wait' && ms != null) {
      sb.write(' $ms');
    }
    if (repeat > 1) {
      sb.write(' x$repeat');
    }
    if (args['as'] != null) {
      sb.write(' as ${args['as']}');
    }
    return sb.toString();
  }

  /// Accepts a map or the shorthand
  /// `[?]<action> [<finder>|<route>|<ms>] [:: <text>] [x<N>] [as <name>]`:
  /// `tap label:Next`, `?tap text:Not now`, `tap text:0 x6`, `keypad 000000`,
  /// `enter_text key:email :: me@x.io`, `expect_route /home`, `wait 300`,
  /// `clipboard as address`. `${name}` in any string is replaced from vars.
  /// Timeouts (`timeoutMs`) need the map form.
  static FlowStep parse(Object? raw, int index, Map<String, Object?> vars, Map<String, Object?> defaults) {
    Map<String, Object?> m;
    if (raw is String) {
      m = _parseShorthand(raw, index);
    } else if (raw is Map) {
      m = raw.cast<String, Object?>();
    } else {
      throw ArgumentError('Step $index must be a string or an object, got ${raw.runtimeType}');
    }
    m = m.map((String k, Object? v) => MapEntry<String, Object?>(k, v is String ? _substitute(v, vars, index) : v));
    final String? action = m['action'] as String?;
    if (action == null || !actions.contains(action)) {
      throw ArgumentError('Step $index: unknown action "$action" (known: ${actions.join(', ')})');
    }
    final Map<String, Object?> args =
        <String, Object?>{
            for (final MapEntry<String, Object?> d in defaults.entries)
              if (d.key == 'settleTimeoutMs' || d.key == 'steadyMs' || d.key == 'timeoutMs') d.key: d.value,
            ...m,
          }
          ..remove('action')
          ..remove('repeat')
          ..remove('optional');
    if (_needsFinder.contains(action) && args['finder'] == null) {
      throw ArgumentError('Step $index ($action) needs a finder');
    }
    if ((action == 'enter_text' || action == 'keypad') && args['text'] == null) {
      throw ArgumentError('Step $index ($action) needs text');
    }
    if (action == 'expect_route' && args['route'] == null) {
      throw ArgumentError('Step $index (expect_route) needs a route');
    }
    final int repeat = (m['repeat'] as num?)?.toInt() ?? 1;
    if (repeat < 1 || repeat > 100) {
      throw ArgumentError('Step $index: repeat must be 1..100');
    }
    return FlowStep._(index, action, args, repeat: repeat, optional: m['optional'] == true);
  }

  static final RegExp _repeatSuffix = RegExp(r'\s+x(\d+)$');
  static final RegExp _asSuffix = RegExp(r'\s+as\s+([A-Za-z_][A-Za-z0-9_]*)$');

  static Map<String, Object?> _parseShorthand(String raw, int index) {
    String s = raw.trim();
    final Map<String, Object?> m = <String, Object?>{};
    if (s.startsWith('?')) {
      m['optional'] = true;
      s = s.substring(1).trimLeft();
    }
    final RegExpMatch? asM = _asSuffix.firstMatch(s);
    if (asM != null) {
      m['as'] = asM.group(1);
      s = s.substring(0, asM.start);
    }
    final RegExpMatch? xM = _repeatSuffix.firstMatch(s);
    if (xM != null) {
      m['repeat'] = int.parse(xM.group(1)!);
      s = s.substring(0, xM.start);
    }
    final int sep = s.indexOf(' :: ');
    if (sep > 0) {
      m['text'] = s.substring(sep + 4);
      s = s.substring(0, sep);
    }
    final int space = s.indexOf(RegExp(r'\s'));
    final String action = space < 0 ? s : s.substring(0, space);
    final String rest = space < 0 ? '' : s.substring(space).trim();
    m['action'] = action;
    if (rest.isEmpty) {
      return m;
    }
    switch (action) {
      case 'wait':
        m['ms'] = int.tryParse(rest) ?? (throw ArgumentError('Step $index: wait needs milliseconds, got "$rest"'));
      case 'wait_idle':
        m['timeoutMs'] = int.tryParse(rest);
      case 'expect_route':
        m['route'] = rest;
      case 'screenshot':
        m['scale'] = double.tryParse(rest);
      case 'keypad':
        // `keypad 1234` or `keypad key:pin_{c} :: 1234`
        if (m['text'] == null) {
          m['text'] = rest;
        } else {
          m['finder'] = rest;
        }
      default:
        m['finder'] = rest;
    }
    return m;
  }

  static final RegExp _var = RegExp(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}');

  static String _substitute(String s, Map<String, Object?> vars, int index) {
    return s.replaceAllMapped(_var, (Match m) {
      final String name = m.group(1)!;
      if (!vars.containsKey(name)) {
        throw ArgumentError('Step $index: no value for \${$name}; pass it in "vars"');
      }
      return '${vars[name]}';
    });
  }
}
