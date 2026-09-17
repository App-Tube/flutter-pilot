import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_test/flutter_test.dart' show Finder, LiveWidgetController, find;

import 'errors.dart';
import 'finders.dart';
import 'screen.dart';
import 'tree.dart';

/// Bumped whenever the `ext.aiDriver.*` request/response shape changes.
const String kAiDriverProtocolVersion = '0.1.0';

/// Guardrails applied inside the app process.
class AiDriverPolicy {
  const AiDriverPolicy({
    this.allowSensitiveText = false,
    this.sensitiveKeyPatterns = const <String>['passcode', 'pin', 'mnemonic', 'seed', 'private', 'password', 'secret'],
    this.enableSemantics = true,
    this.deterministicCursor = true,
  });

  /// When false (default), `enterText` refuses obscured fields and fields
  /// whose key matches [sensitiveKeyPatterns].
  final bool allowSensitiveText;
  final List<String> sensitiveKeyPatterns;

  /// Keep the semantics tree alive so `label:` finders and accessibility
  /// identifiers resolve. Small per-frame cost.
  final bool enableSemantics;

  /// Disables the text-cursor blink animation (`EditableText.debugDeterministicCursor`).
  /// On iOS the blink is an AnimationController, so a focused field would
  /// otherwise never count as idle.
  final bool deterministicCursor;
}

AiDriver? _instance;

/// Registers the `ext.aiDriver.*` service extensions. Idempotent. No-op in
/// release mode.
void enableAiDriver({AiDriverPolicy policy = const AiDriverPolicy()}) {
  if (_instance != null) {
    return;
  }
  if (kReleaseMode) {
    debugPrint('ai_driver: refusing to enable in release mode');
    return;
  }
  // Deliberately no WidgetsFlutterBinding.ensureInitialized() here: the app
  // must create the binding itself, in its own zone (runZonedGuarded etc).
  // Everything binding-dependent is set up lazily on the first call.
  _instance = AiDriver._(policy).._register();
}

typedef _Handler = Future<Map<String, Object?>> Function(Map<String, Object?> args);

class _Resolved {
  _Resolved(this.spec, this.finder, this.element);

  final FinderSpec spec;
  final Finder finder;
  final Element element;
}

class _HitCheck {
  _HitCheck({this.obscuredBy, required this.offscreen});

  final String? obscuredBy;
  final bool offscreen;
  bool get ok => obscuredBy == null;
}

class AiDriver {
  AiDriver._(this.policy);

  final AiDriverPolicy policy;
  late final LiveWidgetController _controller = LiveWidgetController(WidgetsBinding.instance);
  SemanticsHandle? _semantics;
  bool _ready = false;
  int _actionCount = 0;
  Future<void> _queue = Future<void>.value();

  WidgetsBinding get _binding => WidgetsBinding.instance;
  SchedulerBinding get _scheduler => SchedulerBinding.instance;

  bool get _bindingInitialized {
    try {
      WidgetsBinding.instance;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// First-call setup that needs the binding. Throws NOT_READY (retryable)
  /// while the app has not yet reached ensureInitialized()/runApp().
  void _ensureReady() {
    if (_ready) {
      return;
    }
    if (!_bindingInitialized) {
      throw const AiDriverException(
        'NOT_READY',
        'WidgetsBinding is not initialized yet; the app main() has not reached runApp(). Retry shortly.',
      );
    }
    if (policy.enableSemantics) {
      _semantics = SemanticsBinding.instance.ensureSemantics();
    }
    if (policy.deterministicCursor) {
      EditableText.debugDeterministicCursor = true;
    }
    _ready = true;
  }

  Map<String, _Handler> get _handlers => <String, _Handler>{
    'info': _info,
    'waitIdle': _waitIdle,
    'tree': _tree,
    'screen': _screen,
    'find': _find,
    'clipboard': _clipboard,
    'tap': _tap,
    'longPress': _longPress,
    'drag': _drag,
    'scrollIntoView': _scrollIntoView,
    'enterText': _enterText,
    'getText': _getText,
    'screenshot': _screenshot,
    'frameHash': _frameHashHandler,
    'currentRoute': _currentRoute,
    'back': _back,
    'setTimeDilation': _setTimeDilation,
  };

  void _register() {
    _handlers.forEach((String name, _Handler handler) {
      developer.registerExtension(
        'ext.aiDriver.$name',
        (String method, Map<String, String> params) => _dispatch(name, handler, params),
      );
    });
    developer.postEvent('aiDriver.ready', <String, Object?>{'protocolVersion': kAiDriverProtocolVersion});
  }

  /// Test-only driver that registers nothing, so several can coexist in one
  /// process (`developer.registerExtension` refuses a second registration).
  @visibleForTesting
  static AiDriver forTest({AiDriverPolicy policy = const AiDriverPolicy()}) => AiDriver._(policy);

  /// Test-only: the description this driver would put in a result's `target`.
  @visibleForTesting
  Map<String, Object?> debugDescribe(Element element) => _candidate(element);

  /// Test-only: runs a handler the way an `ext.aiDriver.<name>` call would,
  /// returning the same decoded `{ok: true, ...}` / `{ok: false, code, ...}`
  /// payload the MCP server sees.
  @visibleForTesting
  Future<Map<String, Object?>> debugCall(String name, [Map<String, Object?> args = const <String, Object?>{}]) async {
    final _Handler? handler = _handlers[name];
    if (handler == null) {
      throw ArgumentError.value(name, 'name', 'no such aiDriver handler');
    }
    final developer.ServiceExtensionResponse response = await _dispatch(name, handler, <String, String>{
      'args': jsonEncode(args),
    });
    return (jsonDecode(response.result!) as Map).cast<String, Object?>();
  }

  // All handlers run serialized: flutter_test's gesture helpers are guarded
  // against overlapping use and two pointer sequences at once make no sense.
  Future<developer.ServiceExtensionResponse> _dispatch(String name, _Handler handler, Map<String, String> params) {
    final Completer<developer.ServiceExtensionResponse> completer = Completer<developer.ServiceExtensionResponse>();
    _queue = _queue.then((_) async {
      completer.complete(await _run(name, handler, params));
    });
    return completer.future;
  }

  Future<developer.ServiceExtensionResponse> _run(String name, _Handler handler, Map<String, String> params) async {
    final Stopwatch sw = Stopwatch()..start();
    Map<String, Object?> args = <String, Object?>{};
    try {
      final String? raw = params['args'];
      if (raw != null && raw.isNotEmpty) {
        args = (jsonDecode(raw) as Map).cast<String, Object?>();
      }
      if (name != 'info') {
        _ensureReady();
      }
      final Map<String, Object?> result = await handler(args);
      result['ok'] = true;
      result['totalMs'] ??= sw.elapsedMilliseconds;
      return developer.ServiceExtensionResponse.result(jsonEncode(result));
    } on AiDriverException catch (e) {
      return developer.ServiceExtensionResponse.result(
        jsonEncode(<String, Object?>{
          'ok': false,
          'code': e.code,
          'message': e.message,
          ...e.data,
          'totalMs': sw.elapsedMilliseconds,
        }),
      );
    } catch (e, st) {
      return developer.ServiceExtensionResponse.result(
        jsonEncode(<String, Object?>{
          'ok': false,
          'code': 'INTERNAL',
          'message': '$e',
          'stack': '$st'.split('\n').take(10).join('\n'),
          'totalMs': sw.elapsedMilliseconds,
        }),
      );
    }
  }

  // ---------------------------------------------------------------- info

  Future<Map<String, Object?>> _info(Map<String, Object?> args) async {
    if (!_bindingInitialized) {
      return <String, Object?>{'protocolVersion': kAiDriverProtocolVersion, 'ready': false, 'debugMode': kDebugMode};
    }
    _ensureReady();
    final ui.FlutterView? view = _binding.platformDispatcher.implicitView;
    final double dpr = view?.devicePixelRatio ?? 1.0;
    return <String, Object?>{
      'protocolVersion': kAiDriverProtocolVersion,
      'ready': true,
      'debugMode': kDebugMode,
      'profileMode': kProfileMode,
      'platform': defaultTargetPlatform.name,
      'devicePixelRatio': dpr,
      'logicalSize': view == null ? null : <double>[view.physicalSize.width / dpr, view.physicalSize.height / dpr],
      'viewPadding': view == null
          ? null
          : <String, double>{
              'top': view.padding.top / dpr,
              'bottom': view.padding.bottom / dpr,
              'left': view.padding.left / dpr,
              'right': view.padding.right / dpr,
            },
      'firstFrameRasterized': _binding.firstFrameRasterized,
      'semanticsEnabled': _semantics != null,
      'actionCount': _actionCount,
      'timeDilation': timeDilation,
    };
  }

  // ---------------------------------------------------------------- idle

  Future<Map<String, Object?>> _waitIdle(Map<String, Object?> args) async {
    final int timeoutMs = (args['timeoutMs'] as num?)?.toInt() ?? 2000;
    return _settle(
      Duration(milliseconds: timeoutMs),
      steady: _steadyArg(args),
      trace: args['trace'] == true,
    );
  }

  /// Default window after which a constant number of running animations
  /// counts as settled. Longer than a Material (300ms) or Cupertino (400ms)
  /// page transition, so a transition in flight is never mistaken for a
  /// looping background.
  static const Duration defaultSteady = Duration(milliseconds: 500);

  Duration _steadyArg(Map<String, Object?> args) {
    final num? ms = args['steadyMs'] as num?;
    return ms == null ? defaultSteady : Duration(milliseconds: ms.toInt());
  }

  Duration _settleArg(Map<String, Object?> args) =>
      Duration(milliseconds: (args['settleTimeoutMs'] as num?)?.toInt() ?? 2000);

  /// Waits until no transient callbacks (animations) are registered and no
  /// frame is scheduled, for two consecutive frames. Never throws: on
  /// timeout it reports which condition was still busy.
  ///
  /// Screens with a looping video, a shimmer or an animated background never
  /// reach that state, and waiting the full timeout after every tap is what
  /// made driving such an app slow. So when the number of running animations
  /// has not changed for [steady] (longer than any page transition), the
  /// screen is reported as `settled` with reason STEADY_ANIMATION: whatever
  /// the action started has finished or become permanent (a toast, a new
  /// screen with its own loops). `idle` stays false in that case, so callers
  /// that need true idleness can tell. "Unchanged" rather than "back to the
  /// lowest count": an action that lands on a busier screen never returns
  /// to the old count, and that was the case that still hit the timeout.
  Future<Map<String, Object?>> _settle(Duration timeout, {Duration steady = defaultSteady, bool trace = false}) async {
    if (timeout <= Duration.zero) {
      return <String, Object?>{'idle': null, 'settled': null, 'skipped': true, 'settleMs': 0, 'frames': 0};
    }
    final Stopwatch sw = Stopwatch()..start();
    int frames = 0;
    int stable = 0;
    int lastTransient = -1;
    int streakStartMs = 0;
    // Debug aid: per-frame "<ms>:<transient><p if a frame is pending>".
    final List<String>? samples = trace ? <String>[] : null;
    if (!_binding.firstFrameRasterized) {
      try {
        await _binding.waitUntilFirstFrameRasterized.timeout(timeout);
      } on TimeoutException {
        return <String, Object?>{
          'idle': false,
          'reason': 'NO_FIRST_FRAME',
          'settleMs': sw.elapsedMilliseconds,
          'frames': frames,
        };
      }
    }
    while (true) {
      final int transient = _scheduler.transientCallbackCount;
      final bool pendingFrame = _scheduler.hasScheduledFrame;
      if (samples != null && samples.length < 300) {
        samples.add('${sw.elapsedMilliseconds}:$transient${pendingFrame ? 'p' : ''}');
      }
      if (transient == 0 && !pendingFrame) {
        stable++;
        if (stable >= 2) {
          return <String, Object?>{
            'idle': true,
            'settled': true,
            'settleMs': sw.elapsedMilliseconds,
            'frames': frames,
            'trace': ?samples,
          };
        }
      } else {
        stable = 0;
      }
      if (transient > 0 && steady > Duration.zero) {
        if (transient != lastTransient) {
          lastTransient = transient;
          streakStartMs = sw.elapsedMilliseconds;
        }
        if (sw.elapsedMilliseconds - streakStartMs >= steady.inMilliseconds) {
          return <String, Object?>{
            'idle': false,
            'settled': true,
            'reason': 'STEADY_ANIMATION',
            'transientCallbacks': transient,
            'settleMs': sw.elapsedMilliseconds,
            'frames': frames,
            'trace': ?samples,
          };
        }
      }
      if (sw.elapsed > timeout) {
        return <String, Object?>{
          'idle': false,
          'settled': false,
          'reason': transient > 0 ? 'ANIMATING' : 'PENDING_FRAME',
          'transientCallbacks': transient,
          'settleMs': sw.elapsedMilliseconds,
          'frames': frames,
          'trace': ?samples,
        };
      }
      await _scheduler.endOfFrame;
      frames++;
    }
  }

  // ---------------------------------------------------------------- tree / find

  Future<Map<String, Object?>> _tree(Map<String, Object?> args) async {
    final bool summary = args['summary'] as bool? ?? true;
    final int maxNodes = (args['maxNodes'] as num?)?.toInt() ?? 400;
    // A finder narrows the dump to one subtree, which is the way out when a
    // big screen truncates before the interesting part (overlay entries, and
    // so any pushed route, are walked last).
    if (args['finder'] != null) {
      final _Resolved resolved = _resolve(args);
      final TreeDump sub = TreeDumper(summary: summary, maxNodes: maxNodes).dump(resolved.element);
      return <String, Object?>{
        'text': sub.text,
        'nodes': sub.count,
        'truncated': sub.truncated,
        'root': resolved.spec.description,
      };
    }
    final Element? root = _binding.rootElement;
    if (root == null) {
      return <String, Object?>{'text': '<no root element: runApp not called yet>', 'nodes': 0, 'truncated': false};
    }
    TreeDump dump = TreeDumper(summary: summary, maxNodes: maxNodes).dump(root);
    String? note;
    if (dump.count == 0 && summary) {
      // Splash screens etc. have nothing keyed or textual: show raw elements.
      dump = TreeDumper(summary: false, maxNodes: maxNodes < 120 ? maxNodes : 120).dump(root);
      note = 'no keyed/text/interactive widgets found; showing the raw element tree instead';
    }
    return <String, Object?>{'text': dump.text, 'nodes': dump.count, 'truncated': dump.truncated, 'note': ?note};
  }

  /// Flat list of visible labels, texts and fields with a `tap` marker; see
  /// [ScreenSummary]. The cheap way to read a screen.
  Future<Map<String, Object?>> _screen(Map<String, Object?> args) async {
    final int maxItems = (args['maxItems'] as num?)?.toInt() ?? 80;
    final Element? root = _binding.rootElement;
    if (root == null) {
      return <String, Object?>{'items': const <String>[], 'count': 0, 'route': null};
    }
    final ui.FlutterView? view = _binding.platformDispatcher.implicitView;
    final Size size = view == null ? const Size(1e9, 1e9) : view.physicalSize / view.devicePixelRatio;
    final Map<String, Object?> route = await _currentRoute(args);
    return <String, Object?>{'route': route['route'], ...ScreenSummary(maxItems: maxItems).summarize(root, size)};
  }

  /// Text on the system clipboard, read from inside the app process (the
  /// only place a sandboxed platform lets it be read). This is how a flow
  /// gets the full value behind a "Copy" button that the UI shows truncated.
  Future<Map<String, Object?>> _clipboard(Map<String, Object?> args) async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    return <String, Object?>{'text': data?.text, 'length': data?.text?.length ?? 0};
  }

  Future<Map<String, Object?>> _find(Map<String, Object?> args) async {
    final FinderSpec spec = parseFinder(args['finder']);
    final List<Element> matches = spec.finder.evaluate().toList();
    return <String, Object?>{
      'finder': spec.description,
      'count': matches.length,
      'candidates': matches.take(10).map(_candidate).toList(),
    };
  }

  /// Describes an element for a result or an error payload.
  ///
  /// Never throws. An action can unmount its own target (a tap that dismisses
  /// the sheet it is in, or pushes a route over it), and `Element.widget`
  /// null-asserts on a defunct element, so a description read after the fact
  /// must degrade instead of turning a successful action into INTERNAL.
  /// Callers that want the real thing snapshot it before they act.
  Map<String, Object?> _candidate(Element e) {
    if (!e.mounted) {
      return <String, Object?>{'type': '<unmounted>', 'rect': null, 'unmounted': true};
    }
    try {
      final Widget w = e.widget;
      final Rect? r = rectOf(e);
      return <String, Object?>{
        'type': w.runtimeType.toString(),
        if (keyString(w.key) != null) 'key': keyString(w.key),
        if (textOf(w) != null) 'text': textOf(w),
        if (labelOf(w) != null) 'label': labelOf(w),
        'rect': r == null ? null : <int>[r.left.round(), r.top.round(), r.width.round(), r.height.round()],
      };
    } catch (_) {
      // Unmounted between the check and the read, or a widget getter that
      // depends on a disposed controller.
      return <String, Object?>{'type': '<unmounted>', 'rect': null, 'unmounted': true};
    }
  }

  _Resolved _resolve(Map<String, Object?> args) {
    final FinderSpec spec = parseFinder(args['finder']);
    final int? index = (args['index'] as num?)?.toInt();
    final List<Element> matches = spec.finder.evaluate().toList();
    if (matches.isEmpty) {
      throw AiDriverException('NOT_FOUND', 'No widget matches ${spec.description}', <String, Object?>{
        'finder': spec.description,
      });
    }
    if (index != null) {
      if (index < 0 || index >= matches.length) {
        throw AiDriverException(
          'BAD_ARGS',
          'index $index out of range, ${matches.length} matches for ${spec.description}',
        );
      }
      return _Resolved(spec, spec.finder.at(index), matches[index]);
    }
    if (matches.length > 1) {
      throw AiDriverException(
        'AMBIGUOUS',
        '${matches.length} widgets match ${spec.description}; pass "index" or a more specific finder',
        <String, Object?>{'finder': spec.description, 'candidates': matches.take(8).map(_candidate).toList()},
      );
    }
    return _Resolved(spec, spec.finder, matches.single);
  }

  // ---------------------------------------------------------------- pointer actions

  /// Test-only replacement for the gesture dispatch. Widget tests drive
  /// gestures (and pump frames) with a WidgetTester; [LiveWidgetController]
  /// needs a binding that actually produces frames, which `flutter test` does
  /// not. Everything around the dispatch stays the real code path.
  @visibleForTesting
  Future<void> Function(Finder finder)? debugDispatch;

  Future<Map<String, Object?>> _tap(Map<String, Object?> args) =>
      _pointerAction(args, debugDispatch ?? (Finder f) => _controller.tap(f, warnIfMissed: false));

  Future<Map<String, Object?>> _longPress(Map<String, Object?> args) =>
      _pointerAction(args, debugDispatch ?? (Finder f) => _controller.longPress(f, warnIfMissed: false));

  Future<Map<String, Object?>> _drag(Map<String, Object?> args) {
    final double dx = (args['dx'] as num?)?.toDouble() ?? 0;
    final double dy = (args['dy'] as num?)?.toDouble() ?? 0;
    return _pointerAction(
      args,
      debugDispatch ?? (Finder f) => _controller.drag(f, Offset(dx, dy), warnIfMissed: false),
    );
  }

  Future<Map<String, Object?>> _pointerAction(
    Map<String, Object?> args,
    Future<void> Function(Finder finder) action,
  ) async {
    final Stopwatch sw = Stopwatch()..start();
    final _Resolved resolved = _resolve(args);
    bool scrolled = false;
    _HitCheck hit = _hitCheck(resolved.finder, resolved.element);
    if (!hit.ok && hit.offscreen) {
      await _controller.ensureVisible(resolved.finder);
      await _settle(const Duration(milliseconds: 500));
      scrolled = true;
      hit = _hitCheck(resolved.finder, resolved.element);
    }
    if (!hit.ok) {
      throw AiDriverException(
        'OBSCURED',
        'Target ${resolved.spec.description} is not hit-testable at its center; topmost render object there is ${hit.obscuredBy}',
        <String, Object?>{'target': _candidate(resolved.element), 'offscreen': hit.offscreen},
      );
    }
    final bool wantHash = args['hash'] as bool? ?? false;
    final String? before = wantHash ? await _frameHash(0.1) : null;
    // Snapshot the target now: the action itself may unmount it (a tap that
    // dismisses its bottom sheet, or pushes a route that replaces it), and
    // then there is nothing left to describe afterwards.
    final Map<String, Object?> target = _candidate(resolved.element);
    final int resolveMs = sw.elapsedMilliseconds;
    _actionCount++;
    await action(resolved.finder);
    final int actMs = sw.elapsedMilliseconds - resolveMs;
    final Map<String, Object?> settle = await _settle(_settleArg(args), steady: _steadyArg(args));
    final String? after = wantHash ? await _frameHash(0.1) : null;
    return <String, Object?>{
      'target': target,
      if (!resolved.element.mounted) 'targetUnmounted': true,
      'scrolledIntoView': scrolled,
      'settle': settle,
      if (wantHash) 'frameHashBefore': before,
      if (wantHash) 'frameHashAfter': after,
      if (wantHash) 'changed': before != after,
      'resolveMs': resolveMs,
      'actMs': actMs,
      'totalMs': sw.elapsedMilliseconds,
    };
  }

  _HitCheck _hitCheck(Finder finder, Element element) {
    final RenderObject? target = element.renderObject;
    if (target is! RenderBox || !target.attached || !target.hasSize) {
      return _HitCheck(obscuredBy: 'nothing (target not laid out)', offscreen: true);
    }
    final Offset center = _controller.getCenter(finder, warnIfMissed: false);
    final RenderView view = RendererBinding.instance.renderViews.first;
    final bool offscreen = !(Offset.zero & view.size).contains(center);
    // Not WidgetController.hitTestOnBinding: that casts the platform
    // dispatcher to a test double and throws under a real binding.
    final HitTestResult result = HitTestResult();
    view.hitTest(result, position: center);
    RenderObject? top;
    for (final HitTestEntry<HitTestTarget> entry in result.path) {
      final HitTestTarget t = entry.target;
      if (t is RenderObject) {
        top ??= t;
        if (_isSelfOrDescendant(t, target)) {
          return _HitCheck(offscreen: offscreen);
        }
      }
    }
    return _HitCheck(obscuredBy: top?.runtimeType.toString() ?? 'nothing', offscreen: offscreen);
  }

  bool _isSelfOrDescendant(RenderObject candidate, RenderObject ancestor) {
    RenderObject? node = candidate;
    while (node != null) {
      if (identical(node, ancestor)) {
        return true;
      }
      node = node.parent;
    }
    return false;
  }

  Future<Map<String, Object?>> _scrollIntoView(Map<String, Object?> args) async {
    final Stopwatch sw = Stopwatch()..start();
    final _Resolved resolved = _resolve(args);
    final Map<String, Object?> before = _candidate(resolved.element);
    await _controller.ensureVisible(resolved.finder);
    final Map<String, Object?> settle = await _settle(const Duration(milliseconds: 2000));
    // The post-scroll rect is the interesting one, but a lazy list can rebuild
    // the element away while scrolling, so fall back to the pre-scroll one.
    final bool stillThere = resolved.element.mounted;
    return <String, Object?>{
      'target': stillThere ? _candidate(resolved.element) : before,
      if (!stillThere) 'targetUnmounted': true,
      'settle': settle,
      'totalMs': sw.elapsedMilliseconds,
    };
  }

  // ---------------------------------------------------------------- text

  Future<Map<String, Object?>> _enterText(Map<String, Object?> args) async {
    final Stopwatch sw = Stopwatch()..start();
    final String? text = args['text'] as String?;
    if (text == null) {
      throw const AiDriverException('BAD_ARGS', 'text is required');
    }
    final _Resolved resolved = _resolve(args);
    Finder editable = resolved.element.widget is EditableText
        ? resolved.finder
        : find.descendant(of: resolved.finder, matching: find.byType(EditableText));
    final int count = editable.evaluate().length;
    if (count == 0) {
      throw AiDriverException('NOT_FOUND', 'No EditableText under ${resolved.spec.description}');
    }
    if (count > 1) {
      editable = editable.first;
    }
    final EditableTextState state = _controller.state<EditableTextState>(editable);
    final String keyStr = (keyString(resolved.element.widget.key) ?? '').toLowerCase();
    final bool sensitiveKey = policy.sensitiveKeyPatterns.any(keyStr.contains);
    if (!policy.allowSensitiveText && (state.widget.obscureText || sensitiveKey)) {
      throw AiDriverException(
        'POLICY_DENIED',
        state.widget.obscureText
            ? 'Refusing to type into an obscured (secret) field'
            : 'Refusing to type into a field whose key looks sensitive ($keyStr)',
        <String, Object?>{'target': _candidate(resolved.element)},
      );
    }
    if (!state.widget.focusNode.hasFocus) {
      await _controller.tap(editable, warnIfMissed: false);
      await _settle(const Duration(milliseconds: 500));
    }
    final int focusMs = sw.elapsedMilliseconds;
    // Same reason as in _pointerAction: submitting can navigate away.
    final Map<String, Object?> target = _candidate(resolved.element);
    _actionCount++;
    state.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
    final bool submit = args['submit'] as bool? ?? false;
    if (submit) {
      state.performAction(TextInputAction.done);
    }
    final Map<String, Object?> settle = await _settle(_settleArg(args), steady: _steadyArg(args));
    return <String, Object?>{
      'target': target,
      if (!resolved.element.mounted) 'targetUnmounted': true,
      'textLength': text.length,
      'submitted': submit,
      'settle': settle,
      'focusMs': focusMs,
      'totalMs': sw.elapsedMilliseconds,
    };
  }

  Future<Map<String, Object?>> _getText(Map<String, Object?> args) async {
    final _Resolved resolved = _resolve(args);
    String? text = textOf(resolved.element.widget);
    if (text == null) {
      final List<String> parts = <String>[];
      void collect(Element e) {
        final String? t = textOf(e.widget);
        if (t != null) {
          parts.add(t);
          return; // RichText children repeat the same text
        }
        e.visitChildren(collect);
      }

      resolved.element.visitChildren(collect);
      text = parts.isEmpty ? null : parts.join(' ');
    }
    return <String, Object?>{'text': text, 'target': _candidate(resolved.element)};
  }

  // ---------------------------------------------------------------- pixels

  /// `scale` is relative to the device's physical resolution (1.0 = full
  /// res). Default 0.5 keeps PNGs small enough for a model to look at.
  Future<Map<String, Object?>> _screenshot(Map<String, Object?> args) async {
    final Stopwatch sw = Stopwatch()..start();
    final double scale = (args['scale'] as num?)?.toDouble() ?? 0.5;
    final ui.Image image = await _capture(scale);
    final int captureMs = sw.elapsedMilliseconds;
    final ByteData? bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final int width = image.width;
    final int height = image.height;
    image.dispose();
    if (bytes == null) {
      throw const AiDriverException('INTERNAL', 'PNG encoding returned null');
    }
    final Uint8List list = bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    final int encodeMs = sw.elapsedMilliseconds - captureMs;
    return <String, Object?>{
      'base64': base64Encode(list),
      'width': width,
      'height': height,
      'scale': scale,
      'bytes': list.length,
      'captureMs': captureMs,
      'encodeMs': encodeMs,
      'totalMs': sw.elapsedMilliseconds,
    };
  }

  Future<Map<String, Object?>> _frameHashHandler(Map<String, Object?> args) async {
    final Stopwatch sw = Stopwatch()..start();
    final double scale = (args['scale'] as num?)?.toDouble() ?? 0.1;
    final String hash = await _frameHash(scale);
    return <String, Object?>{'hash': hash, 'scale': scale, 'totalMs': sw.elapsedMilliseconds};
  }

  Future<ui.Image> _capture(double scale) async {
    final RenderView renderView = RendererBinding.instance.renderViews.first;
    final ContainerLayer? layer = renderView.debugLayer;
    if (layer is! OffsetLayer) {
      throw const AiDriverException('NO_FRAME', 'Render view has no layer yet; nothing has been painted');
    }
    // paintBounds is in physical pixels, so pixelRatio here is a plain scale.
    return layer.toImage(renderView.paintBounds, pixelRatio: scale);
  }

  Future<String> _frameHash(double scale) async {
    final ui.Image image = await _capture(scale);
    final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    if (data == null) {
      return 'none';
    }
    final Uint8List bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    int h = 0xcbf29ce484222325;
    for (final int b in bytes) {
      h ^= b;
      h *= 0x100000001b3;
    }
    return h.toRadixString(16);
  }

  // ---------------------------------------------------------------- navigation

  Future<Map<String, Object?>> _currentRoute(Map<String, Object?> args) async {
    String? name;
    String? routeType;
    int navigators = 0;
    void visit(Element e) {
      final Widget w = e.widget;
      if (w is Navigator) {
        navigators++;
      }
      if (w is Scaffold || w is CupertinoPageScaffold || w is Dialog || w is AlertDialog || w is BottomSheet) {
        final ModalRoute<Object?>? r = ModalRoute.of(e);
        if (r != null) {
          name = r.settings.name;
          routeType = r.runtimeType.toString();
        }
      }
      e.visitChildren(visit);
    }

    final Element? root = _binding.rootElement;
    if (root != null) {
      visit(root);
    }
    return <String, Object?>{'route': name, 'routeType': routeType, 'navigators': navigators};
  }

  Future<Map<String, Object?>> _back(Map<String, Object?> args) async {
    final Stopwatch sw = Stopwatch()..start();
    final Finder nav = find.byType(Navigator);
    if (nav.evaluate().isEmpty) {
      throw const AiDriverException('NOT_FOUND', 'No Navigator in the tree');
    }
    final NavigatorState state = _controller.state<NavigatorState>(nav.first);
    _actionCount++;
    final bool popped = await state.maybePop();
    final Map<String, Object?> settle = await _settle(const Duration(milliseconds: 2000));
    return <String, Object?>{'popped': popped, 'settle': settle, 'totalMs': sw.elapsedMilliseconds};
  }

  Future<Map<String, Object?>> _setTimeDilation(Map<String, Object?> args) async {
    final double factor = (args['factor'] as num?)?.toDouble() ?? 1.0;
    if (factor <= 0) {
      throw const AiDriverException('BAD_ARGS', 'factor must be > 0');
    }
    timeDilation = factor;
    return <String, Object?>{'timeDilation': timeDilation};
  }
}
