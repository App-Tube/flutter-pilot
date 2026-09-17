import 'package:ai_driver/ai_driver.dart';
import 'package:counter/main.dart' as app;

/// Entrypoint used by flutter_pilot: same app, plus the in-process driver.
void main() {
  enableAiDriver();
  app.main();
}
