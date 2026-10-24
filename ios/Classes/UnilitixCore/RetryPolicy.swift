// VENDORED from UnilitixCore 0.6.0 (RetryPolicy.swift) by scripts/sync-ios-core.sh.
// Do not edit here; change UnilitixCore and re-run the script.

import Foundation

/// How the uploader reacts to a response (contract: "Upload and retry").
/// One request per flush cycle; a retryable failure keeps the data queued and
/// opens a backoff window during which flush cycles are skipped.
enum UploadOutcome: Equatable {
    /// 2xx (and 409, a duplicate the server already has): delete the batch.
    case accepted
    /// No response, 429 or 5xx: keep the data and back off.
    case retry(after: TimeInterval)
    /// 401/403: the key is wrong. Keep the data, pause uploads until restart.
    case authFailure
    /// Any other 4xx: the payload can never succeed. Drop the batch.
    case rejected
}

enum RetryPolicy {
    static let baseDelayMs = SdkContract.retryBaseDelayMs
    static let maxDelayMs = SdkContract.retryMaxDelayMs

    /// The backoff window after the `attempt`-th consecutive failure
    /// (0-based). A `Retry-After` value in seconds replaces it, clamped to
    /// the contract's bounds.
    static func delay(attempt: Int, retryAfterSeconds: Int? = nil,
                      jitter: (Int) -> Int = { $0 > 0 ? Int.random(in: 0..<$0) : 0 }) -> TimeInterval {
        if let ra = retryAfterSeconds {
            let clamped = min(max(ra, SdkContract.retryAfterMinSeconds), SdkContract.retryAfterMaxSeconds)
            return TimeInterval(clamped)
        }
        let exponent = min(max(attempt, 0), 20)
        let base = min(baseDelayMs * (1 << exponent), maxDelayMs)
        let ms = min(base + jitter(max(1, base / 5)), maxDelayMs)
        return TimeInterval(ms) / 1000
    }

    static func classify(status: Int?, headers: [String: String], attempt: Int) -> UploadOutcome {
        guard let status = status else {
            return .retry(after: delay(attempt: attempt))
        }
        switch status {
        case 200..<300, 409:
            return .accepted
        case 401, 403:
            return .authFailure
        case 429, 500...:
            return .retry(after: delay(attempt: attempt, retryAfterSeconds: retryAfter(headers)))
        case 400..<500:
            return .rejected
        default:
            return .retry(after: delay(attempt: attempt))
        }
    }

    /// `Retry-After` in its seconds form; the HTTP-date form is ignored.
    static func retryAfter(_ headers: [String: String]) -> Int? {
        for (k, v) in headers where k.lowercased() == "retry-after" {
            return Int(v.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
