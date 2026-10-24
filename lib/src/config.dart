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

  /// Automatically capture crash reports. On iOS also turns on app-hang
  /// (`ANR`) detection; see [appHangTimeoutMs].
  final bool autoTrackCrashes;

  /// iOS, with [autoTrackCrashes]: report an app hang (`ANR`) when the main
  /// (platform) thread does not respond for this long, in milliseconds,
  /// while the app is in the foreground. 0 turns hang detection off. Not
  /// used on Android, where the system's ANRs are reported. Not an SDK
  /// contract option (the native iOS SDK has the same default).
  final int appHangTimeoutMs;

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

  /// Contribute to the crowd-sourced power-outage map. Off by default.
  ///
  /// Double opt-in: this flag alone collects nothing. The app must also
  /// declare and itself request coarse location (`ACCESS_COARSE_LOCATION` on
  /// Android, `NSLocationWhenInUseUsageDescription` on iOS) — the SDK never
  /// asks for permission, it only reads a location the app already may — and
  /// consent must be [UnilitixConsent.granted] (nothing is collected or held
  /// while pending or denied).
  ///
  /// When on, the SDK records when the device is plugged in or unplugged and
  /// sends those events with an H3 resolution-7 cell (~5 km²) computed on the
  /// device and a daily-rotating salted device hash; coordinates and the
  /// install id never leave the device. See the README.
  final bool powerOutageContribution;

  const UnilitixConfig({
    required this.apiKey,
    this.apiUrl = 'https://api.unilitix.com',
    this.autoTrackTaps = true,
    this.autoTrackCrashes = true,
    this.appHangTimeoutMs = 2000,
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
    this.powerOutageContribution = false,
  });

  UnilitixConfig copyWith({
    String? apiKey,
    String? apiUrl,
    bool? autoTrackTaps,
    bool? autoTrackCrashes,
    int? appHangTimeoutMs,
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
    bool? powerOutageContribution,
  }) {
    return UnilitixConfig(
      apiKey: apiKey ?? this.apiKey,
      apiUrl: apiUrl ?? this.apiUrl,
      autoTrackTaps: autoTrackTaps ?? this.autoTrackTaps,
      autoTrackCrashes: autoTrackCrashes ?? this.autoTrackCrashes,
      appHangTimeoutMs: appHangTimeoutMs ?? this.appHangTimeoutMs,
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
      powerOutageContribution:
          powerOutageContribution ?? this.powerOutageContribution,
    );
  }
}
