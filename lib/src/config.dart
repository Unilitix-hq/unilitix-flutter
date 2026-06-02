/// Configuration for the Unilitix SDK.
///
/// Pass to [Unilitix.init]:
/// ```dart
/// await Unilitix.init(
///   config: const UnilitixConfig(apiKey: 'your_api_key'),
/// );
/// ```
class UnilitixConfig {
  /// Your Unilitix API key. Required.
  final String apiKey;

  /// Unilitix ingest API base URL.
  final String apiUrl;

  /// Automatically track user taps via [UnilitixGestureDetector].
  final bool autoTrackTaps;

  /// Automatically capture crash reports.
  final bool autoTrackCrashes;

  /// Automatically detect rage taps (3+ taps within 100 px / 1 s).
  final bool autoTrackRageTaps;

  /// How often to flush events to the server (seconds).
  final int flushIntervalSeconds;

  /// Maximum events per flush batch.
  final int flushBatchSize;

  /// Maximum events to queue offline before dropping oldest.
  final int maxOfflineEvents;

  /// Idle duration before a new session starts (seconds).
  final int sessionTimeoutSeconds;

  /// Enable verbose console logging.
  final bool debug;

  /// Mask text input fields in snapshots and screenshots.
  final bool maskInputs;

  /// Capture widget-tree snapshots.
  final bool captureSnapshots;

  /// Snapshot interval in milliseconds (clamped to 1000–60000).
  final int snapshotIntervalMs;

  /// Maximum snapshots per session.
  final int maxSnapshotsPerSession;

  /// Capture screenshots via RepaintBoundary.
  final bool captureScreenshots;

  /// Screenshot interval in milliseconds.
  final int screenshotIntervalMs;

  /// Screenshot JPEG quality (1–100).
  final int screenshotQuality;

  /// Maximum screenshot width in pixels.
  final int screenshotMaxWidth;

  /// Only upload screenshots on WiFi.
  final bool uploadScreenshotsOnWifiOnly;

  /// Maximum screenshots per session.
  final int maxScreenshotsPerSession;

  const UnilitixConfig({
    required this.apiKey,
    this.apiUrl = 'https://api.unilitix.com',
    this.autoTrackTaps = true,
    this.autoTrackCrashes = true,
    this.autoTrackRageTaps = true,
    this.flushIntervalSeconds = 30,
    this.flushBatchSize = 100,
    this.maxOfflineEvents = 1000,
    this.sessionTimeoutSeconds = 1800,
    this.debug = false,
    this.maskInputs = true,
    this.captureSnapshots = true,
    this.snapshotIntervalMs = 1000,
    this.maxSnapshotsPerSession = 200,
    this.captureScreenshots = true,
    this.screenshotIntervalMs = 1000,
    this.screenshotQuality = 30,
    this.screenshotMaxWidth = 480,
    this.uploadScreenshotsOnWifiOnly = true,
    this.maxScreenshotsPerSession = 300,
  });
}
