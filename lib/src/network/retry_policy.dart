import 'dart:math';

/// Retry policy matching the Unilitix Android SDK behaviour.
class RetryPolicy {
  static const int maxRetries = 5;
  static const int maxDelayMs = 300000; // 5 minutes

  /// Returns the delay in milliseconds before attempt [attempt] (1-based).
  /// Returns -1 if the error is a 4xx client error (drop immediately).
  static int delayFor({
    required int attempt,
    required int? statusCode,
    String? retryAfterHeader,
  }) {
    if (statusCode != null) {
      if (statusCode >= 400 && statusCode < 500 && statusCode != 429) {
        return -1; // drop
      }
      if (statusCode == 429) {
        final ra =
            retryAfterHeader != null ? int.tryParse(retryAfterHeader) : null;
        return ra != null
            ? min(ra * 1000, maxDelayMs)
            : min(1000 * pow(2, attempt - 1).toInt(), maxDelayMs);
      }
    }
    return min(1000 * pow(2, attempt - 1).toInt(), maxDelayMs);
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
