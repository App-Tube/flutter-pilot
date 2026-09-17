# flutter_pilot

An MCP server that lets an AI agent drive a Flutter app **in-process** over the Dart VM service:
launch, hot reload, find widgets, tap, type, wait for idle, screenshot, read runtime errors.
No OS-level input injection, so the same code path works on the iOS Simulator, Android emulator
and desktop, and a tap costs milliseconds instead of seconds.

Status: **v0.1**. Works, fast, minimal. No reporting, no design compare, no policy config yet;
see [docs/ROADMAP.md](docs/ROADMAP.md) for the design and what comes next.

## Layout

```
packages/ai_driver      in-app package (dev dependency). enableAiDriver() registers ext.aiDriver.* extensions
packages/flutter_pilot  the MCP server + `smoke` benchmark CLI
example/counter         demo app with test_driver/ai_app.dart entrypoint
.mcp.json               Claude Code picks this up when the repo is the project root
```

## Quick start (5 minutes, nothing to configure)

Prerequisites: Flutter 3.35+ (3.41 tested), Xcode with an iOS simulator and/or Android SDK with an emulator,
`~/.pub-cache/bin` on your PATH.

```bash
git clone https://github.com/App-Tube/flutter-pilot.git && cd flutter-pilot
flutter pub get
cd packages/flutter_pilot
dart run bin/flutter_pilot.dart devices                                   # simulators and their state
dart run bin/flutter_pilot.dart smoke                                     # boots a simulator, benchmarks the counter app
dart run bin/flutter_pilot.dart flow --root ../../example/counter \
  --file test_driver/flows/count_and_greet.json --var name=Ada            # one multi-step flow, ~1.5 s after launch
```
Then open the repo in Claude Code: the checked-in `.mcp.json` starts the server from source, and
`launch_app(root: "<repo>/example/counter", device: "<udid from list_devices>")` gives you the same app to drive by hand.

## Use it on any Flutter app

1. Add the in-app package as a dev dependency (git for now, pub.dev later):
   ```yaml
   dev_dependencies:
     ai_driver:
       git:
         url: https://github.com/App-Tube/flutter-pilot.git
         path: packages/ai_driver
         ref: v0.1.0
   ```
2. Add an entrypoint `test_driver/ai_app.dart`:
   ```dart
   import 'package:ai_driver/ai_driver.dart';
   import 'package:my_app/main.dart' as app;

   void main() {
     enableAiDriver();   // no-op in release builds
     app.main();
   }
   ```
   Apps that need mocks (feature flags, biometrics, backends) register them here before `app.main()`.
3. Install the server once (puts a `flutter_pilot` executable in `~/.pub-cache/bin`, which must be on your PATH):
   ```bash
   dart pub global activate --source git https://github.com/App-Tube/flutter-pilot.git --git-path packages/flutter_pilot
   ```
   Then register it in the app's `.mcp.json` (or `~/.claude.json`):
   ```json
   { "mcpServers": { "flutter_pilot": { "command": "flutter_pilot", "args": ["mcp"] } } }
   ```
   Working from a checkout instead: `dart pub global activate --source path packages/flutter_pilot`. Inside this
   workspace the checked-in `.mcp.json` runs the server from source.
4. In Claude Code: `launch_app(root, device[, flavor, definesFile])` (or `attach_app` when the build is
   current) → `run_flow` with every step you already know → read the result. Look with `screen`, not `get_tree`.
   Editing code: `hot_reload` → `screen` / `run_flow` → `runtime_errors`.
   Apps with flavors pass them through, e.g. `flavor: "staging"`, `definesFile: ".env/staging.env"`;
   the server reads the defines file, the model never does. If the project has `.fvm/flutter_sdk`, that SDK is used.

Without Claude Code, the same launch from a terminal (keeps the app running until Enter):
```bash
cd packages/flutter_pilot && dart run bin/flutter_pilot.dart run --root /path/to/app --flavor myFlavor --defines .env/staging.env
```
It prints launch timings, the current route, the widget tree and saves a screenshot.

## Tools

| Tier | Tools |
|---|---|
| lifecycle | `list_devices`, `launch_app`, `attach_app`, `stop_app`, `hot_reload`, `hot_restart`, `session_status`, `app_logs`, `runtime_errors` |
| read | `screen`, `wait_for_idle`, `get_tree`, `find`, `get_text`, `clipboard`, `current_route`, `screenshot` |
| interact | `run_flow`, `tap`, `long_press`, `drag`, `scroll_into_view`, `enter_text`, `back`, `set_time_dilation` |

### The fast path: `run_flow`

Two ready-made recipes live in [`example/counter/test_driver/flows/`](example/counter/test_driver/flows/):
`count_and_greet.json` (tap ×3, type, assert, capture, screenshot) and `open_details.json` (navigate, `expect_route`,
optional step, `back`). Copy one into your app's `test_driver/flows/`, swap the finders, and run it with
`run_flow(file: ...)` from Claude Code or `flutter_pilot flow --root <app> --file <flow>` from a terminal.

Driving an app one tool call per tap is slow for a reason that has nothing to do with the tap (2 ms): every call is
a model round trip of several seconds. Measured on a large production wallet app's onboarding, 2026-09-17: 30 single calls took 8m30s;
the same journey as one `run_flow` took **11.8 s** on the first try and **7.8 s** after tuning (flow steps settle for at most 800 ms, keypad digits skip the settle except the last). Getting an app took 20 s with `attach_app` and 21–50 s with `launch_app`.

```json
run_flow(file: "test_driver/flows/create_wallet.json")
run_flow(steps: ["tap label:Get started", "wait_for label:Recovery phrase", "tap label:Recovery phrase",
                 "keypad ${pin}", "expect_route /mainRoute", "clipboard as address"], vars: {"pin": "000000"})
```

Step shorthand: `[?]<action> [<finder>|<route>|<ms>] [:: <text>] [x<N>] [as <name>]`. `?` = optional (skip if
absent; how you handle a prompt that may or may not appear), `xN` repeats, `:: text` is what to type, `as name`
stores a captured value. Actions: `tap`, `long_press`, `drag`, `scroll_into_view`, `enter_text`, `keypad` (taps
one key per character; PIN pads are buttons, not fields), `back`, `wait`, `wait_idle`, `wait_for`, `wait_gone`,
`expect`, `expect_route`, `get_text`, `clipboard`, `screen`, `screenshot`, `hot_reload`, `hot_restart`. Map form
adds `timeoutMs`, `index`, `settleTimeoutMs`, `steadyMs`, `optional`, `repeat`. A flow file is
`{"name", "vars", "defaults", "steps"}` and lives in the app repo (`test_driver/flows/`), so a known journey is
one call with zero rediscovery. The result is one compact object: per-step `ok`/`ms`, `captured`, and on the
first failure the `error` and the `screen` it failed on.

### Reading a screen: `screen`

A flat, top-to-bottom list of visible texts, labels and fields (`tap "Get started" @20,780 387x44`), deduplicated
(Text/RichText pairs, a Semantics label repeating its child), with hidden things removed: routes under an opaque
route, non-selected `IndexedStack` tabs, `Offstage`/`Visibility`/`Opacity(0)`, off-screen rects, icon glyphs.
Around 60 lines for a busy wallet home instead of a 1200-node tree. `get_tree` (summary mode) applies the same
visibility rules; use it with a `finder` when you need structure.

### `attach_app`

`flutter attach --machine` to an installed debug build instead of rebuilding: seconds instead of a minute when the
code has not changed. `start: true` starts the app (adb `monkey` / `simctl launch`), `clearData: true` wipes its
storage first (Android `pm clear`), which is how onboarding is re-run from scratch without a rebuild.

Finder shorthand: `key:<value>`, `text:<exact>`, `contains:<sub>`, `type:<Widget>`, `label:<semantics|tooltip>`,
`tooltip:<msg>`, and `<outer> > <inner>` for descendants. Ambiguous matches fail with candidates; pass `index`.
Text finders skip obscured fields, so a passcode keypad key does not collide with the digits already typed.

Every action waits for the UI to settle and returns timings, the resolved target and any runtime errors raised
during the step. Settled means idle (no animations, no scheduled frame, two stable frames) **or steady**: the number
of running animations unchanged for `steadyMs` (500 ms, longer than a page transition). Screens with a looping
video, shimmer or animated card never idle, and without the steady rule every tap on them cost the full 2 s
timeout. The result says which it was (`idle: false, settled: true, reason: STEADY_ANIMATION`).
`settleTimeoutMs: 0` skips the wait; `steadyMs: 0` insists on true idle. `wait_for_idle(trace: true)` returns the per-frame
animation counts, which is how to see what a screen that never settles is doing. A screen still loading data (shimmer →
content → new loops) is not steady and is not meant to be: synchronise on the next element with `wait_for` instead.
The target is captured before the gesture, so a tap that dismisses a sheet or pushes a route still reports
what it hit, with `targetUnmounted: true`.
`enter_text` refuses obscured fields and keys that look secret (`POLICY_DENIED`).

`get_tree` stops at `maxNodes` (400) and says so in the dump. Routes hidden under an opaque one are skipped, so
the route on top is no longer what a small budget loses; pass `finder` to dump one subtree, `summary: false` for
the raw element tree.

## Benchmark

```
cd packages/flutter_pilot && dart run bin/flutter_pilot.dart smoke
```
Boots the first iPhone simulator if needed, launches `example/counter`, drives it, asserts state, prints a table.
Measured on this Mac (M-series, iPhone 18 Pro simulator, iOS 27, Flutter 3.41.6, debug build), 2026-09-17:

| operation | p50 | notes |
|---|---|---|
| build + launch (warm) | 12–16 s | cold first build 30 s |
| VM service connect | 47 ms | |
| get_tree (33 nodes) | 32 ms | |
| tap, raw (`settleTimeoutMs: 0`) | 2 ms | round trip incl. VM service |
| tap + wait for idle | 413 ms | almost all of it is the Material ink ripple animation |
| enter_text (focus + type + idle) | ~1 s | includes keyboard animation |
| screenshot @0.5 (603×1311, 48 KB) | 27 ms | PNG encode is 21 ms of it |
| screenshot @1.0 (1206×2622, 100 KB) | 74 ms | |
| hot_reload | 40 ms | + idle 50 ms |
| hot_restart + idle | 650 ms | |

## Design notes

- Not built on `enableFlutterDriverExtension()`: it installs its own binding (incompatible with Patrol's) and
  disables the real keyboard. `ai_driver` reuses only the binding-free parts of flutter_test
  (`LiveWidgetController` for real pointer sequences) and types through `EditableTextState.updateEditingValue`
  so formatters and `onChanged` fire.
- `EditableText.debugDeterministicCursor` is switched on: on iOS the cursor blink is an animation and a focused
  field would otherwise never count as idle.
- Screenshots are `OffsetLayer.toImage` of the root render view: platform views (WebView, video) render blank.
- The server owns `flutter run --machine` (daemon protocol) and talks raw VM service; DTD is not required.

## Troubleshooting big apps (seen on a real wallet app, 2026-09-17)

- **`launch_app` fails in `pod install`** with "specs repository is too out-of-date": run `pod repo update` once, then retry.
  Note `pod install` may rewrite the `COCOAPODS:` line in `ios/Podfile.lock` if your CocoaPods version differs from the team's.
- **iOS 26+/Xcode 26+ simulator: "Unable to find a destination"** and Flutter warns that a plugin does not support arm64:
  that plugin's podspec sets `EXCLUDED_ARCHS[sdk=iphonesimulator*] = arm64`, so the simulator build is x86_64 only and cannot
  run on Apple Silicon without Rosetta. Fix the plugin (ship an `aarch64-apple-ios-sim` slice as an xcframework) or use the
  Android emulator; flutter_pilot drives both identically.
- **Android: "'X' isn't a type"** for generated code that exists in git, or Gradle "uses this output of task
  compileFlutterBuild<OtherFlavor> without declaring a dependency": a stale `build/app/intermediates/flutter/<otherFlavor>/flutter_build.d`
  from an older build declares your generated sources as that task's outputs, and Gradle's stale-output cleanup deletes them.
  Remove that variant directory (or `flutter clean`), regenerate the code, retry.
- **Empty `get_tree` right after launch**: the app is on a splash without keys/text/Scaffold. `current_route` is null there;
  `wait_for_idle` again after a second or two, or use `flutter_pilot run`, which waits up to 20 s for the first real route.

## Known gaps (v0.1)

Android emulator boot (works if the emulator is already running), config file / per-project policy,
audit log and report, design (Figma) compare, pub.dev publishing. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Development

```bash
flutter pub get                      # workspace root
dart analyze packages example
(cd packages/flutter_pilot && dart test)
(cd packages/ai_driver && flutter test)
dart format packages example/counter/lib example/counter/test_driver   # 120 columns, see analysis_options.yaml
```
CI runs the same on every push and pull request. Licensed under MIT.
