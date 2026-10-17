import 'dart:math';

/// Backoff policy for the flush scheduler.
///
/// Since 2.1.1 the SDK makes **one** request per flush cycle. When that
/// request fails in a retryable way (transport error, timeout, 5xx, 429) the
/// scheduler opens a backoff window computed by [delayFor] and skips cycles
/// until it closes; the data waits in the on-device queue. Consecutive
/// failures grow the window exponentially up to [maxDelayMs]; one success
/// resets it. A `Retry-After` header, when present, sets the window directly.
///
/// This replaces the pre-2.1.1 behaviour of up to [maxRetries] blocking
/// attempts inside a single HTTP call, which could hold a flush open for
/// minutes and multiplied load on a degraded link.
class RetryPolicy {
  /// Backoff exponent is clamped here, so the window never exceeds
  /// `2^maxRetries` seconds (capped again by [maxDelayMs]).
  static const int maxRetries = 5;
  static const int maxDelayMs = 300000; // 5 minutes

  static final Random _random = Random();

  /// Returns the backoff window after the [attempt]-th consecutive failure
  /// (0-based).
  ///
  /// If [retryAfterSeconds] is provided (parsed from a `Retry-After` header),
  /// it is used directly, clamped to [1, 60] seconds.
  ///
  /// Otherwise exponential backoff with +0–20% jitter is used:
  /// `(1000ms * 2^attempt) + jitter`, capped at [maxDelayMs].
  /// [attempt] is clamped to [0, 20] before the bit-shift to prevent
  /// int64 overflow.
  static Duration delayFor(int attempt, {int? retryAfterSeconds}) {
    if (retryAfterSeconds != null) {
      return Duration(seconds: retryAfterSeconds.clamp(1, 60));
    }
    final cappedAttempt = attempt.clamp(0, 20);
    final base = (1000 * (1 << cappedAttempt)).clamp(0, maxDelayMs);
    final jitterRange = max(1, base ~/ 5); // 20% of base, minimum 1
    final jitter = _random.nextInt(jitterRange);
    final ms = (base + jitter).clamp(0, maxDelayMs);
    return Duration(milliseconds: ms);
  }

  /// Whether a response with [statusCode] (null for a transport failure) is
  /// worth sending again later. 4xx other than 429 means the request itself
  /// is wrong and will never succeed; everything else is transient.
  static bool isRetryable(int? statusCode) {
    if (statusCode == null) return true;
    if (statusCode >= 400 && statusCode < 500 && statusCode != 429) {
      return false;
    }
    return statusCode >= 400;
  }

  /// Legacy helper kept for callers of the pre-2.1.1 API: combines
  /// [isRetryable] with the attempt budget.
  static bool shouldRetry({
    required int attempt,
    required int? statusCode,
  }) {
    if (attempt > maxRetries) return false;
    return isRetryable(statusCode);
  }
}
