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

  /// Automatically track screen navigation via [Unilitix.observer].
  final bool autoTrackScreens;

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

  /// Fraction of sessions to capture (0.0–1.0).
  final double sampleRate;

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

  /// Mask text inputs in screenshots.
  final bool maskInputsInScreenshots;

  const UnilitixConfig({
    required this.apiKey,
    this.apiUrl = 'https://api.unilitix.io',
    this.autoTrackScreens = true,
    this.autoTrackTaps = true,
    this.autoTrackCrashes = true,
    this.autoTrackRageTaps = true,
    this.flushIntervalSeconds = 30,
    this.flushBatchSize = 100,
    this.maxOfflineEvents = 1000,
    this.sessionTimeoutSeconds = 1800,
    this.debug = false,
    this.maskInputs = true,
    this.sampleRate = 1.0,
    this.captureSnapshots = true,
    this.snapshotIntervalMs = 1000,
    this.maxSnapshotsPerSession = 200,
    this.captureScreenshots = true,
    this.screenshotIntervalMs = 1000,
    this.screenshotQuality = 30,
    this.screenshotMaxWidth = 480,
    this.uploadScreenshotsOnWifiOnly = true,
    this.maxScreenshotsPerSession = 300,
    this.maskInputsInScreenshots = true,
  });
}
