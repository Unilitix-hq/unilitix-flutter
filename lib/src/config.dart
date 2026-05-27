part of '../unilitix.dart';

/// Configuration for the Unilitix SDK.
///
/// All fields have sensible defaults — pass only what you
/// need to override:
/// ```dart
/// await Unilitix.init(
///   'your_api_key',
///   config: UnilitixConfig(debug: true),
/// );
/// ```
class UnilitixConfig {
  /// Your Unilitix API endpoint.
  /// Defaults to the Unilitix cloud.
  final String endpoint;

  /// Enable verbose console logging.
  /// Automatically enabled in debug builds.
  final bool debug;

  /// Automatically track screen navigation.
  /// Requires [Unilitix.observer] on [MaterialApp].
  /// Default: true
  final bool autoTrackScreens;

  /// Automatically track user taps.
  /// Default: true
  final bool autoTrackTaps;

  /// Automatically capture crash reports.
  /// Default: true
  final bool autoTrackCrashes;

  /// Automatically detect rage taps (frustrated users).
  /// Default: true
  final bool autoTrackRageTaps;

  /// How often to flush events to the server (seconds).
  /// Default: 30
  final int flushIntervalSeconds;

  /// How long before an idle session expires (seconds).
  /// Default: 1800 (30 minutes)
  final int sessionTimeoutSeconds;

  /// Automatically mask text input fields.
  /// Recommended for apps handling sensitive data.
  /// Default: true
  final bool maskInputs;

  /// What fraction of sessions to capture (0.0–1.0).
  /// Default: 1.0 (100%)
  final double sampleRate;

  const UnilitixConfig({
    this.endpoint = 'https://api.unilitix.com',
    this.debug = false,
    this.autoTrackScreens = true,
    this.autoTrackTaps = true,
    this.autoTrackCrashes = true,
    this.autoTrackRageTaps = true,
    this.flushIntervalSeconds = 30,
    this.sessionTimeoutSeconds = 1800,
    this.maskInputs = true,
    this.sampleRate = 1.0,
  });
}
