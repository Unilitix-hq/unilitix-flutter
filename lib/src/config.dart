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

  /// Occlude text input fields (`TextField`, `TextFormField`,
  /// `CupertinoTextField`, `EditableText`) in wireframe snapshots and paint
  /// over them in pixel screenshots. Inputs are masked even inside a
  /// [UnilitixUnmasked] subtree.
  final bool maskInputs;

  /// Redact every text widget: in wireframe snapshots the characters are
  /// replaced by bullets (length preserved); in pixel screenshots the text's
  /// bounds are painted over. On by default: balances, names, phone numbers
  /// and OTPs are usually rendered as plain [Text]. Wrap copy that is safe and
  /// useful to see (headings, button labels) in [UnilitixUnmasked].
  final bool maskAllText;

  /// Black out image widgets (Image, RawImage, CircleAvatar, FadeInImage) in
  /// screenshots and mark them masked in snapshots. Off by default.
  final bool maskImages;

  /// Paint an opaque box over every [UnilitixPrivate] subtree (and images when
  /// [maskImages] is on) in pixel screenshots before they leave the device.
  final bool maskScreenshots;

  /// Fraction of sessions (0.0–1.0) for which session replay (wireframe
  /// snapshots and screenshots) is captured; decided once per session.
  /// Events, crashes and performance are always collected. 1.0 records every
  /// session; 0.1 records one in ten; 0 disables replay without touching the
  /// other `capture*` flags.
  final double replaySampleRate;

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

  /// Hard cap on screenshots per session (safety net; capture is
  /// change-driven so a normal session stays far below it).
  final int maxScreenshotsPerSession;

  /// Rolling one-minute budget for screenshots, so a continuously redrawing
  /// screen (ticker, animation) cannot flood the session.
  final int maxScreenshotsPerMinute;

  /// Take a frame at least this often while the screen is static, so long
  /// idle screens still appear in replay.
  final int screenshotHeartbeatMs;

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
    this.maskAllText = true,
    this.maskImages = false,
    this.maskScreenshots = true,
    this.replaySampleRate = 1.0,
    this.captureSnapshots = true,
    this.snapshotIntervalMs = 1000,
    this.maxSnapshotsPerSession = 1500,
    this.captureScreenshots = true,
    this.screenshotIntervalMs = 1000,
    this.screenshotQuality = 30,
    this.screenshotMaxWidth = 480,
    this.uploadScreenshotsOnWifiOnly = true,
    this.maxScreenshotsPerSession = 1500,
    this.maxScreenshotsPerMinute = 20,
    this.screenshotHeartbeatMs = 10000,
  });

  UnilitixConfig copyWith({
    String? apiKey,
    String? apiUrl,
    bool? autoTrackTaps,
    bool? autoTrackCrashes,
    bool? autoTrackRageTaps,
    int? flushIntervalSeconds,
    int? flushBatchSize,
    int? maxOfflineEvents,
    int? sessionTimeoutSeconds,
    bool? debug,
    bool? maskInputs,
    bool? maskAllText,
    bool? maskImages,
    bool? maskScreenshots,
    double? replaySampleRate,
    bool? captureSnapshots,
    int? snapshotIntervalMs,
    int? maxSnapshotsPerSession,
    bool? captureScreenshots,
    int? screenshotIntervalMs,
    int? screenshotQuality,
    int? screenshotMaxWidth,
    bool? uploadScreenshotsOnWifiOnly,
    int? maxScreenshotsPerSession,
    int? maxScreenshotsPerMinute,
    int? screenshotHeartbeatMs,
  }) {
    return UnilitixConfig(
      apiKey: apiKey ?? this.apiKey,
      apiUrl: apiUrl ?? this.apiUrl,
      autoTrackTaps: autoTrackTaps ?? this.autoTrackTaps,
      autoTrackCrashes: autoTrackCrashes ?? this.autoTrackCrashes,
      autoTrackRageTaps: autoTrackRageTaps ?? this.autoTrackRageTaps,
      flushIntervalSeconds: flushIntervalSeconds ?? this.flushIntervalSeconds,
      flushBatchSize: flushBatchSize ?? this.flushBatchSize,
      maxOfflineEvents: maxOfflineEvents ?? this.maxOfflineEvents,
      sessionTimeoutSeconds:
          sessionTimeoutSeconds ?? this.sessionTimeoutSeconds,
      debug: debug ?? this.debug,
      maskInputs: maskInputs ?? this.maskInputs,
      maskAllText: maskAllText ?? this.maskAllText,
      maskImages: maskImages ?? this.maskImages,
      maskScreenshots: maskScreenshots ?? this.maskScreenshots,
      replaySampleRate: replaySampleRate ?? this.replaySampleRate,
      captureSnapshots: captureSnapshots ?? this.captureSnapshots,
      snapshotIntervalMs: snapshotIntervalMs ?? this.snapshotIntervalMs,
      maxSnapshotsPerSession:
          maxSnapshotsPerSession ?? this.maxSnapshotsPerSession,
      captureScreenshots: captureScreenshots ?? this.captureScreenshots,
      screenshotIntervalMs: screenshotIntervalMs ?? this.screenshotIntervalMs,
      screenshotQuality: screenshotQuality ?? this.screenshotQuality,
      screenshotMaxWidth: screenshotMaxWidth ?? this.screenshotMaxWidth,
      uploadScreenshotsOnWifiOnly:
          uploadScreenshotsOnWifiOnly ?? this.uploadScreenshotsOnWifiOnly,
      maxScreenshotsPerSession:
          maxScreenshotsPerSession ?? this.maxScreenshotsPerSession,
      maxScreenshotsPerMinute:
          maxScreenshotsPerMinute ?? this.maxScreenshotsPerMinute,
      screenshotHeartbeatMs:
          screenshotHeartbeatMs ?? this.screenshotHeartbeatMs,
    );
  }
}
