/// Retry policy matching the Unilitix Android SDK behaviour.
class RetryPolicy {
  static const int maxRetries = 5;
  static const int maxDelayMs = 300000; // 5 minutes

  /// Returns the delay before the next attempt.
  ///
  /// If [retryAfterSeconds] is provided (parsed from a `Retry-After` header),
  /// it is used directly, clamped to [1, 60] seconds.
  ///
  /// Otherwise exponential backoff is used: `1000ms * 2^attempt`, capped at
  /// [maxDelayMs]. [attempt] is clamped to [0, 20] before the bit-shift to
  /// prevent int64 overflow (`2^21` already exceeds [maxDelayMs]; anything
  /// higher is wasted cycles).
  static Duration delayFor(int attempt, {int? retryAfterSeconds}) {
    if (retryAfterSeconds != null) {
      return Duration(seconds: retryAfterSeconds.clamp(1, 60));
    }
    final cappedAttempt = attempt.clamp(0, 20);
    final ms = (1000 * (1 << cappedAttempt)).clamp(0, maxDelayMs);
    return Duration(milliseconds: ms);
  }

  static bool shouldRetry({
    required int attempt,
    required int? statusCode,
  }) {
    if (attempt > maxRetries) return false;
    if (statusCode != null &&
        statusCode >= 400 &&
        statusCode < 500 &&
        statusCode != 429) {
      return false;
    }
    return true;
  }
}
