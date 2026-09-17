/// In-app agent for flutter_pilot.
///
/// Call [enableAiDriver] before `runApp` in a dedicated entrypoint
/// (conventionally `test_driver/ai_app.dart`). It registers
/// `ext.aiDriver.*` VM service extensions that let the flutter_pilot MCP
/// server find widgets, tap, type, wait for idle and capture screenshots
/// in-process, without OS-level input injection.
library;

export 'src/ai_driver.dart' show AiDriverPolicy, enableAiDriver, kAiDriverProtocolVersion;
