/// Structured failure returned to the server as `{ok:false, code, message}`.
class AiDriverException implements Exception {
  const AiDriverException(this.code, this.message, [this.data = const <String, Object?>{}]);

  /// Stable machine-readable code, e.g. `NOT_FOUND`, `AMBIGUOUS`, `OBSCURED`,
  /// `POLICY_DENIED`, `BAD_ARGS`.
  final String code;
  final String message;
  final Map<String, Object?> data;

  @override
  String toString() => 'AiDriverException($code): $message';
}
