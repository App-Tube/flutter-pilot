# Changelog

## Unreleased
- CLI `flutter_pilot flow`: launch an app and run one flow file from the terminal.
- Example flow recipes for the counter app under `example/counter/test_driver/flows/`.
- README quick start.

## 0.1.0 — 2026-09-17

First working version. Drive a Flutter app in-process over the Dart VM service from an MCP client.

### ai_driver (in-app package)
- `enableAiDriver()` registers `ext.aiDriver.*` service extensions; no-op in release builds, no binding
  created before the app's own `runApp` (safe with `runZonedGuarded`).
- Finders: `key:`, `text:`, `contains:`, `type:`, `label:`, `tooltip:`, `outer > inner`; ambiguity reported with candidates.
- Actions: tap, long press, drag, scroll into view, enter text (via `TextInputClient`, formatters and `onChanged` fire), back.
- Reads: compact tree, flat `screen` summary with visibility rules, current route, text, clipboard, screenshot, frame hash.
- Settle: idle (no animations, no scheduled frame) or steady (animation count stable), with per-frame trace.
- Guardrails: refuses obscured/secret-looking fields; text finders never match obscured field contents.

### flutter_pilot (MCP server + CLI)
- Owns `flutter run --machine` / `flutter attach --machine`, raw VM service connection, runtime-error capture.
- Tools: launch/attach/stop, hot reload/restart, tree/screen/find/get_text/current_route/screenshot,
  tap/long_press/drag/scroll_into_view/enter_text/back/set_time_dilation, `run_flow` for multi-step journeys
  (inline steps or JSON flow files), wait_for_idle, runtime_errors, app_logs, list_devices.
- iOS simulator boot on demand; Android emulator via adb (`attach_app` can start / clear the app).
- Per-project fvm SDK, UTF-8 environment for CocoaPods, `--flavor` and `--dart-define-from-file` passthrough.
- CLI: `flutter_pilot mcp | run | smoke | devices`.
