# flutter_pilot: design and roadmap

## Goal

Let an AI coding agent implement a Flutter change, run the app on a simulator or emulator, look at the result
right away, compare it to the design when needed, and write a report the human can trust. Two requirements drive
every decision: **speed** (the loop must feel like hot reload, not like a CI run) and **safety** (the agent is in
the driving seat of real apps, sometimes wallets).

## Why in-process

| operation | in-process over the VM service | OS-level (simctl / idb / adb / XCUITest) |
|---|---|---|
| tap | 2–30 ms | 300 ms – 2 s |
| screenshot | 30–80 ms | 300–900 ms |
| widget tree / screen summary | 30–150 ms | a11y tree 0.5–2 s |
| hot reload | 40 ms – 2 s | rebuild + relaunch 10–90 s |

The same code path works on iOS simulators, Android emulators and desktop. OS-level control is kept only for
what the Flutter view cannot see: simulator/emulator lifecycle, permission dialogs, share sheets, platform views
(WebView, video render blank in in-process captures).

## Decisions

1. **Not built on `enableFlutterDriverExtension()`.** It installs its own `WidgetsBinding` (so it cannot coexist with
   Patrol's or any other custom binding) and replaces the real keyboard. `ai_driver` reuses only the binding-free
   parts of flutter_test (`LiveWidgetController` for real pointer sequences) and registers plain
   `dart:developer` service extensions.
2. **The app creates the binding, not the driver.** `enableAiDriver()` only registers extensions; anything needing
   the binding is set up lazily on the first call, so apps that bootstrap inside `runZonedGuarded` keep one zone.
3. **The server owns the `flutter run --machine` process** (daemon protocol) and talks raw VM service; DTD is not
   required. `flutter attach --machine` is the fast path when the build is current.
4. **Settle, then act.** Every action returns after the UI is idle or steady, with timings, the resolved target and
   any runtime error raised during the step. A failed step says what went wrong (`NOT_FOUND`, `AMBIGUOUS`,
   `OBSCURED`, `TIMEOUT_SETTLE`, `POLICY_DENIED`) instead of leaving the agent to guess from a screenshot.
5. **Multi-step flows are one call.** Model round trips, not taps, dominate wall-clock time; `run_flow` executes a
   whole journey from a JSON file in the app repo so known paths cost seconds, not minutes.
6. **Reports come from an audit log, never from the model's memory** (not built yet, see below).

## Security model (target state)

Threats: secrets typed or captured (seed phrases, passcodes); wrong flavor or device (production backend);
destructive or lateral `simctl`/`adb` use; prompt injection through app content and logs; runaway sessions.

Mechanisms, in order of value per effort:

1. Flavor and device gate from a per-project config file: only listed flavors and defines files, simulators and
   emulators only, debug builds only. Runtime double-check through `ext.aiDriver.info`.
2. Device pinning and a fixed allow-list of `simctl`/`adb` subcommands; no shell tool at all.
3. Append-only audit log per step with redacted arguments, codes, frame hashes and screenshot paths.
4. Secret-field guard (shipped): obscured fields and secret-looking keys are refused unless the human unlocks the
   session; route-based sensitivity (blur screenshots on configured routes) still to do.
5. Content firewall: app text and logs returned as delimited untrusted data, redacted for seed-like word runs,
   base58 keys, bearer tokens and values from the defines file.
6. Budgets: actions, wall-clock, screenshots per session.
7. Tool tiers through MCP `ToolAnnotations` (shipped) so clients can auto-allow read tools and prompt on lifecycle.

## Roadmap

- **v0.1 (done):** launch/attach, hot reload, finders, actions, screen/tree/screenshot, settle rules, `run_flow`,
  secret-field guard, iOS simulator boot, `smoke` benchmark, CLI `run`.
- **v0.2 — policy and report:** `flutter_pilot.yaml` per project (allowed flavors, defines glob, sensitive routes,
  redaction patterns, budgets), audit log, `write_report` (markdown + screenshots + runtime errors + `git diff --stat`),
  `flutter_pilot init` and `doctor`.
- **v0.3 — design comparison (optional module):** fetch Figma nodes over REST with a read-only token, structured
  comparison first (text, font size/weight, colors, spacing from an in-app `describe` extension), pixel diff and
  heatmap second.
- **v0.4 — Android lifecycle and distribution:** boot AVDs on demand, `screencap` fallback for platform views,
  pub.dev publishing of both packages, optional Claude Code plugin with a skill encoding the loop.

## Known limits

- Platform views render blank in screenshots (fall back to `simctl io screenshot` / `adb screencap`).
- Screens with perpetual animations never reach true idle; the steady rule and `set_time_dilation` cover most cases.
- Plugins that exclude arm64 for simulators cannot run on Apple Silicon iOS 26+ simulators at all; that is a plugin
  problem, use the Android emulator meanwhile.
- The Flutter framework APIs used by `ai_driver` change a few times a year; expect a small compatibility pass per
  stable release. The daemon and VM service protocols are stable.
