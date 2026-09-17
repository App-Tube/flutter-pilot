import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';

import 'flow.dart';
import 'session.dart';
import 'sim.dart';
import 'vm_client.dart';

const String _finderGrammar =
    'Finder shorthand: "key:<value>" (ValueKey), "text:<exact>", "contains:<substring>", '
    '"type:<WidgetType>", "label:<semantics label|identifier|tooltip>", "tooltip:<msg>", '
    'and "<outer> > <inner>" for descendants. A bare string means text:. Add "index" when several widgets match. '
    'Text finders ignore obscured fields, so a passcode keypad key does not collide with the digits already typed.';

const String _flowGrammar =
    'Step shorthand: "[?]<action> [<finder>|<route>|<ms>] [:: <text>] [x<N>] [as <name>]" — '
    '"tap label:Next", "?tap text:Not now" (skip if absent), "keypad 000000" (taps each digit), '
    '"enter_text key:email :: me@x.io", "wait_for text:Done", "expect_route /home", "wait 300", '
    '"clipboard as address", "get_text key:total as total". Map form adds timeoutMs/index/settleTimeoutMs. '
    r'"${name}" is filled from vars.';

const String _instructions =
    '''
flutter_pilot drives a Flutter app in-process over the Dart VM service (fast, no OS input injection).

Fast path: launch_app or attach_app (once) -> run_flow with every step you already know -> read the result.
One run_flow call replaces a whole tap/look/tap loop; only think again when a step fails, the result then carries
the screen it failed on. Known journeys live as JSON files in the app repo: run_flow(file: "test_driver/flows/x.json").
Reading a screen: prefer screen (flat list of visible texts/labels/fields with tap markers) over get_tree; use
get_tree only to pick a finder for something screen did not show. Do not add sleeps: use wait_for / expect_route.
Editing code: hot_reload -> screen/run_flow -> runtime_errors.
Every action waits for the UI to settle (idle, or a steady looping animation) and reports timings.
$_finderGrammar
$_flowGrammar
The app must be launched from an entrypoint that calls enableAiDriver() (package ai_driver) before runApp().
''';

/// The MCP server. One session (one running app) per server process.
base class PilotServer extends MCPServer with ToolsSupport {
  PilotServer(super.channel, {required this.session})
    : super.fromStreamChannel(
        implementation: Implementation(name: 'flutter_pilot', version: '0.1.0'),
        instructions: _instructions,
      ) {
    _registerTools();
  }

  final PilotSession session;

  static final ToolAnnotations _read = ToolAnnotations(readOnlyHint: true);
  static final ToolAnnotations _interact = ToolAnnotations(readOnlyHint: false, destructiveHint: false);
  static final ToolAnnotations _lifecycle = ToolAnnotations(readOnlyHint: false, destructiveHint: true);

  void _registerTools() {
    // ------------------------------------------------------------ lifecycle
    registerTool(
      Tool(
        name: 'list_devices',
        description: 'Lists iOS simulators (with boot state) and devices Flutter can see right now.',
        inputSchema: Schema.object(),
        annotations: _read,
      ),
      _listDevices,
    );
    registerTool(
      Tool(
        name: 'launch_app',
        description:
            'Builds and runs the app in debug mode on a simulator/emulator via `flutter run --machine`, '
            'boots the iOS simulator if needed, connects to the VM service and waits for the first idle frame. '
            'Takes 15s-3min depending on the app; only needed once per session (use hot_reload afterwards).',
        inputSchema: Schema.object(
          properties: <String, Schema>{
            'root': Schema.string(description: 'Absolute path of the Flutter project (contains pubspec.yaml).'),
            'device': Schema.string(
              description: 'Flutter device id: iOS simulator UDID, "emulator-5554", "macos", etc.',
            ),
            'target': Schema.string(
              description: 'Entrypoint that calls enableAiDriver(). Default test_driver/ai_app.dart',
            ),
            'flavor': Schema.string(description: 'Optional --flavor.'),
            'definesFile': Schema.string(description: 'Optional --dart-define-from-file path (relative to root).'),
            'extraArgs': Schema.list(description: 'Extra `flutter run` arguments.', items: Schema.string()),
          },
          required: <String>['root', 'device'],
        ),
        annotations: _lifecycle,
      ),
      _launch,
    );
    registerTool(
      Tool(
        name: 'attach_app',
        description:
            'Attaches to an already installed debug build via `flutter attach --machine` instead of rebuilding '
            '(seconds instead of a minute). With start=true the app is started first; with clearData=true its storage is '
            'wiped first (Android only), so onboarding can be re-run from scratch. Same result shape as launch_app.',
        inputSchema: Schema.object(
          properties: <String, Schema>{
            'root': Schema.string(description: 'Absolute path of the Flutter project (contains pubspec.yaml).'),
            'device': Schema.string(description: 'Flutter device id, e.g. "emulator-5554" or an iOS simulator UDID.'),
            'appId': Schema.string(
              description: 'Android package / iOS bundle id, e.g. com.example.app.staging. Needed for start/clearData.',
            ),
            'start': Schema.bool(
              description: 'Start the app before attaching (default false: it must already be running).',
            ),
            'clearData': Schema.bool(description: 'Android: `pm clear` the app first. Implies start.'),
            'target': Schema.string(description: 'Entrypoint used for hot restart. Default test_driver/ai_app.dart'),
            'extraArgs': Schema.list(description: 'Extra `flutter attach` arguments.', items: Schema.string()),
          },
          required: <String>['root', 'device'],
        ),
        annotations: _lifecycle,
      ),
      _attach,
    );
    registerTool(
      Tool(
        name: 'stop_app',
        description: 'Stops the running app and the flutter process.',
        inputSchema: Schema.object(),
        annotations: _lifecycle,
      ),
      (CallToolRequest r) => _guard(() => session.stop()),
    );
    registerTool(
      Tool(
        name: 'hot_reload',
        description:
            'Hot reloads the running app (keeps state) and waits for idle. Reports runtime errors raised during the reload.',
        inputSchema: Schema.object(),
        annotations: _lifecycle,
      ),
      (CallToolRequest r) => _guard(() => session.hotReload()),
    );
    registerTool(
      Tool(
        name: 'hot_restart',
        description: 'Hot restarts the running app (resets state) and waits for idle.',
        inputSchema: Schema.object(),
        annotations: _lifecycle,
      ),
      (CallToolRequest r) => _guard(() => session.hotReload(full: true)),
    );
    registerTool(
      Tool(
        name: 'session_status',
        description: 'Current session state, device, app info (DPR, logical size, platform) and error count.',
        inputSchema: Schema.object(),
        annotations: _read,
      ),
      (CallToolRequest r) => _guard(() async => session.status()),
    );
    registerTool(
      Tool(
        name: 'app_logs',
        description: 'Recent app / flutter tool output lines.',
        inputSchema: Schema.object(properties: <String, Schema>{'tail': Schema.int(description: 'Lines, default 100')}),
        annotations: _read,
      ),
      (CallToolRequest r) => _guard(
        () async => <String, Object?>{'lines': session.appLogs((r.arguments?['tail'] as num?)?.toInt() ?? 100)},
      ),
    );
    registerTool(
      Tool(
        name: 'runtime_errors',
        description:
            'Flutter framework errors (FlutterError.onError / Flutter.Error events) captured since launch, or since the last call with onlyNew.',
        inputSchema: Schema.object(
          properties: <String, Schema>{
            'onlyNew': Schema.bool(description: 'Only errors since the previous runtime_errors call.'),
            'clear': Schema.bool(description: 'Clear the buffer after reading.'),
          },
        ),
        annotations: _read,
      ),
      (CallToolRequest r) => _guard(
        () async => <String, Object?>{
          'errors': session.runtimeErrors(
            clear: r.arguments?['clear'] as bool? ?? false,
            onlyNew: r.arguments?['onlyNew'] as bool? ?? false,
          ),
        },
      ),
    );

    // ------------------------------------------------------------ read
    registerTool(
      Tool(
        name: 'wait_for_idle',
        description:
            'Waits until no animations run and no frame is scheduled (two stable frames). Returns idle=false with the reason on timeout.',
        inputSchema: Schema.object(properties: <String, Schema>{'timeoutMs': Schema.int(description: 'Default 2000')}),
        annotations: _read,
      ),
      (CallToolRequest r) => _guard(() => session.act('waitIdle', _args(r))),
    );
    registerTool(
      Tool(
        name: 'get_tree',
        description:
            'Compact indented dump of the widget tree: keys, texts, labels, interactive and structural widgets with '
            'their on-screen rects [x,y wxh] in logical px. Use it to pick finders. summary=false dumps every element. '
            'The walk stops at maxNodes and says so in the dump; overlay entries come last, so on a busy screen a pushed '
            'route or dialog is the first thing lost — raise maxNodes or pass a finder to dump just that subtree.',
        inputSchema: Schema.object(
          properties: <String, Schema>{
            'summary': Schema.bool(description: 'Default true.'),
            'maxNodes': Schema.int(description: 'Default 400.'),
            'finder': Schema.string(description: 'Dump only this widget\'s subtree. $_finderGrammar'),
          },
        ),
        annotations: _read,
      ),
      _tree,
    );
    registerTool(
      Tool(
        name: 'screen',
        description:
            'The cheap way to read a screen: current route plus a flat, top-to-bottom list of visible texts, '
            'labels and fields ("tap" prefix = under an interactive widget; key= when one is nearby). Off-stage routes, '
            'off-screen widgets and Text/RichText duplicates are dropped. Use get_tree only when this does not show '
            'what you need.',
        inputSchema: Schema.object(properties: <String, Schema>{'maxItems': Schema.int(description: 'Default 80.')}),
        annotations: _read,
      ),
      (CallToolRequest r) => _guard(() => session.act('screen', _args(r))),
    );
    registerTool(
      Tool(
        name: 'clipboard',
        description:
            'Text on the system clipboard, read from inside the app. Use after tapping a "Copy" button to get '
            'the full value the UI shows truncated (an address, an id).',
        inputSchema: Schema.object(),
        annotations: _read,
      ),
      (CallToolRequest r) => _guard(() => session.act('clipboard')),
    );
    registerTool(
      Tool(
        name: 'find',
        description: 'Resolves a finder without acting; returns match count and up to 10 candidates. $_finderGrammar',
        inputSchema: Schema.object(
          properties: <String, Schema>{'finder': Schema.string(description: 'Finder shorthand.')},
          required: <String>['finder'],
        ),
        annotations: _read,
      ),
      (CallToolRequest r) => _guard(() => session.act('find', _args(r))),
    );
    registerTool(
      Tool(
        name: 'get_text',
        description: 'Text of the matched widget (or concatenated texts of its descendants).',
        inputSchema: _finderSchema(),
        annotations: _read,
      ),
      (CallToolRequest r) => _guard(() => session.act('getText', _args(r))),
    );
    registerTool(
      Tool(
        name: 'current_route',
        description: 'Name and type of the topmost route (heuristic: route of the last Scaffold/dialog in the tree).',
        inputSchema: Schema.object(),
        annotations: _read,
      ),
      (CallToolRequest r) => _guard(() => session.act('currentRoute')),
    );
    registerTool(
      Tool(
        name: 'screenshot',
        description:
            'In-process screenshot of the Flutter view as PNG (platform views such as WebViews render blank). '
            'scale is relative to full device resolution; default 0.5. Also saved to disk (path in result).',
        inputSchema: Schema.object(
          properties: <String, Schema>{
            'scale': Schema.num(description: 'Fraction of physical resolution, default 0.5.'),
          },
        ),
        annotations: _read,
      ),
      _screenshot,
    );

    // ------------------------------------------------------------ interact
    registerTool(
      Tool(
        name: 'run_flow',
        description:
            'Runs a list of steps in one call and returns one compact result: per-step ok/ms, captured values '
            '(get_text/clipboard "as" names), and on the first failure the error plus the screen it failed on. '
            'Use it for everything you already know how to do; it is 10-30x cheaper than one tool call per tap. '
            'Steps come inline or from a JSON file ({"name","vars","defaults","steps"}) relative to the project root. '
            '$_flowGrammar Actions: ${FlowStep.actions.join(', ')}.',
        inputSchema: Schema.object(
          properties: <String, Schema>{
            'steps': Schema.list(
              description:
                  'Steps: shorthand strings or {action, finder, text, route, ms, timeoutMs, index, repeat, optional, as}.',
            ),
            'file': Schema.string(
              description:
                  'JSON flow file, absolute or relative to the launched project root. Inline steps are appended.',
            ),
            'vars': Schema.object(description: r'Values for ${name} placeholders, e.g. {"pin": "000000"}.'),
            'defaults': Schema.object(description: 'Per-step defaults: settleTimeoutMs, steadyMs, timeoutMs.'),
            'stopOnError': Schema.bool(description: 'Default true.'),
          },
        ),
        annotations: _interact,
      ),
      _runFlow,
    );
    registerTool(
      Tool(
        name: 'tap',
        description:
            'Taps the center of the matched widget with a real pointer sequence, then waits for the UI to settle. '
            'Fails with OBSCURED if something else would receive the tap, AMBIGUOUS if several widgets match. '
            'For several taps in a row use run_flow.',
        inputSchema: _finderSchema(
          extra: <String, Schema>{
            'hash': Schema.bool(
              description: 'Also compute a frame hash before/after to report whether pixels changed.',
            ),
            'settleTimeoutMs': Schema.int(description: 'Default 2000; 0 skips waiting for idle (raw action latency).'),
            'steadyMs': Schema.int(
              description:
                  'Treat a constant number of running animations as settled after this long '
                  '(default 500, longer than a page transition; 0 = only true idle counts).',
            ),
          },
        ),
        annotations: _interact,
      ),
      (CallToolRequest r) => _guard(() => session.act('tap', _args(r))),
    );
    registerTool(
      Tool(
        name: 'long_press',
        description: 'Long-presses the matched widget, then waits for idle.',
        inputSchema: _finderSchema(),
        annotations: _interact,
      ),
      (CallToolRequest r) => _guard(() => session.act('longPress', _args(r))),
    );
    registerTool(
      Tool(
        name: 'drag',
        description:
            'Drags from the matched widget by (dx, dy) logical px, then waits for idle. Use for scrolling lists.',
        inputSchema: _finderSchema(
          extra: <String, Schema>{
            'dx': Schema.num(description: 'Horizontal offset.'),
            'dy': Schema.num(description: 'Vertical offset (negative scrolls down).'),
          },
        ),
        annotations: _interact,
      ),
      (CallToolRequest r) => _guard(() => session.act('drag', _args(r))),
    );
    registerTool(
      Tool(
        name: 'scroll_into_view',
        description: 'Scrolls the nearest Scrollable so the matched widget becomes visible.',
        inputSchema: _finderSchema(),
        annotations: _interact,
      ),
      (CallToolRequest r) => _guard(() => session.act('scrollIntoView', _args(r))),
    );
    registerTool(
      Tool(
        name: 'enter_text',
        description:
            'Focuses the matched text field and replaces its text through the TextInputClient path '
            '(formatters and onChanged fire). Refuses obscured/secret fields (POLICY_DENIED).',
        inputSchema: _finderSchema(
          extra: <String, Schema>{
            'text': Schema.string(description: 'New full text of the field.'),
            'submit': Schema.bool(description: 'Also send TextInputAction.done.'),
            'settleTimeoutMs': Schema.int(description: 'Default 2000; 0 skips waiting for idle.'),
          },
          required: <String>['finder', 'text'],
        ),
        annotations: _interact,
      ),
      (CallToolRequest r) => _guard(() => session.act('enterText', _args(r))),
    );
    registerTool(
      Tool(
        name: 'back',
        description: 'Pops the current route on the root Navigator (like the system back button).',
        inputSchema: Schema.object(),
        annotations: _interact,
      ),
      (CallToolRequest r) => _guard(() => session.act('back')),
    );
    registerTool(
      Tool(
        name: 'set_time_dilation',
        description: 'Sets Flutter timeDilation (<1 speeds animations up, e.g. 0.1 to make spinners settle).',
        inputSchema: Schema.object(
          properties: <String, Schema>{'factor': Schema.num(description: 'Default 1.0')},
          required: <String>['factor'],
        ),
        annotations: _interact,
      ),
      (CallToolRequest r) => _guard(() => session.act('setTimeDilation', _args(r))),
    );
  }

  static ObjectSchema _finderSchema({
    Map<String, Schema> extra = const <String, Schema>{},
    List<String> required = const <String>['finder'],
  }) {
    return Schema.object(
      properties: <String, Schema>{
        'finder': Schema.string(description: 'Finder shorthand, e.g. key:increment, text:Save, type:TextField.'),
        'index': Schema.int(description: 'Which match to use when several widgets match (0-based).'),
        ...extra,
      },
      required: required,
    );
  }

  static Map<String, Object?> _args(CallToolRequest r) =>
      Map<String, Object?>.of(r.arguments ?? const <String, Object?>{});

  // ------------------------------------------------------------ impls

  Future<CallToolResult> _guard(Future<Map<String, Object?>> Function() body) async {
    try {
      final Map<String, Object?> result = await body();
      return CallToolResult(content: <Content>[TextContent(text: _pretty(result))]);
    } on AiDriverCallException catch (e) {
      return CallToolResult(isError: true, content: <Content>[TextContent(text: _pretty(e.data))]);
    } catch (e) {
      return CallToolResult(isError: true, content: <Content>[TextContent(text: '${e.runtimeType}: $e')]);
    }
  }

  static String _pretty(Map<String, Object?> m) => const JsonEncoder.withIndent('  ').convert(m);

  Future<CallToolResult> _listDevices(CallToolRequest r) => _guard(() async {
    final Map<String, Map<String, Object?>> sims = await SimAdapter.listIos();
    return <String, Object?>{
      'iosSimulators': sims.entries
          .map((MapEntry<String, Map<String, Object?>> e) => <String, Object?>{'id': e.key, ...e.value})
          .toList(),
      'hint':
          'Pass the id as "device" to launch_app; shut-down simulators are booted automatically. '
          'Android: start an emulator and use its id (e.g. emulator-5554).',
    };
  });

  Future<CallToolResult> _launch(CallToolRequest r) => _guard(() {
    final Map<String, Object?> a = _args(r);
    return session.launch(
      projectRoot: a['root'] as String,
      device: a['device'] as String,
      target: a['target'] as String? ?? 'test_driver/ai_app.dart',
      flavor: a['flavor'] as String?,
      definesFile: a['definesFile'] as String?,
      extraArgs: (a['extraArgs'] as List?)?.cast<String>() ?? const <String>[],
    );
  });

  Future<CallToolResult> _attach(CallToolRequest r) => _guard(() {
    final Map<String, Object?> a = _args(r);
    final bool clear = a['clearData'] as bool? ?? false;
    return session.attach(
      projectRoot: a['root'] as String,
      device: a['device'] as String,
      target: a['target'] as String? ?? 'test_driver/ai_app.dart',
      appId: a['appId'] as String?,
      start: (a['start'] as bool? ?? false) || clear,
      clearData: clear,
      extraArgs: (a['extraArgs'] as List?)?.cast<String>() ?? const <String>[],
    );
  });

  Future<CallToolResult> _runFlow(CallToolRequest r) => _guard(() {
    final Map<String, Object?> a = _args(r);
    return FlowRunner(session).run(
      steps: a['steps'] as List<Object?>?,
      file: a['file'] as String?,
      vars: (a['vars'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{},
      defaults: (a['defaults'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{},
      stopOnError: a['stopOnError'] as bool? ?? true,
    );
  });

  Future<CallToolResult> _tree(CallToolRequest r) async {
    try {
      final Map<String, Object?> res = await session.act('tree', _args(r));
      final String text = (res.remove('text') ?? '').toString();
      return CallToolResult(
        content: <Content>[
          TextContent(text: text),
          TextContent(text: _pretty(res)),
        ],
      );
    } on AiDriverCallException catch (e) {
      return CallToolResult(isError: true, content: <Content>[TextContent(text: _pretty(e.data))]);
    } catch (e) {
      return CallToolResult(isError: true, content: <Content>[TextContent(text: '${e.runtimeType}: $e')]);
    }
  }

  Future<CallToolResult> _screenshot(CallToolRequest r) async {
    try {
      final double scale = (r.arguments?['scale'] as num?)?.toDouble() ?? 0.5;
      final ({List<int> png, Map<String, Object?> meta}) shot = await session.screenshot(scale: scale);
      return CallToolResult(
        content: <Content>[
          ImageContent(data: base64Encode(shot.png), mimeType: 'image/png'),
          TextContent(text: _pretty(shot.meta)),
        ],
      );
    } on AiDriverCallException catch (e) {
      return CallToolResult(isError: true, content: <Content>[TextContent(text: _pretty(e.data))]);
    } catch (e) {
      return CallToolResult(isError: true, content: <Content>[TextContent(text: '${e.runtimeType}: $e')]);
    }
  }
}
