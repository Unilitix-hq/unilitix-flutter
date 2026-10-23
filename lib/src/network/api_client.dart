import 'dart:async';
import 'dart:convert';
import 'dart:io' show IOException, GZipCodec;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'retry_policy.dart';
import '../generated/ingest_models.dart';
import '../logger/logger.dart';
import '../storage/pending_screenshot.dart';
import '../generated/sdk_contract.dart';

/// A presigned-URL slot returned by the batch screenshot init endpoint.
class ScreenshotSlot {
  final int ordinal;
  final String presignedUrl;
  const ScreenshotSlot({required this.ordinal, required this.presignedUrl});
}

/// Outcome of the screenshot init call: the HTTP result plus the parsed
/// slots when the call succeeded.
class ScreenshotInitResult {
  final ApiResult result;
  final List<ScreenshotSlot>? slots;
  const ScreenshotInitResult(this.result, this.slots);
}

/// The outcome of one request to the ingest API.
///
/// Every call makes exactly one attempt. The caller (the flush scheduler)
/// decides what to do with a failure: [retryable] outcomes keep the data in
/// the on-device queue and open a backoff window; [rejected] outcomes drop
/// the batch because resending the same bytes can never succeed;
/// [isAuthFailure] pauses uploads until the key is fixed.
class ApiResult {
  /// HTTP status, or null when no response arrived (DNS, TCP, TLS, timeout,
  /// connection reset).
  final int? status;
  final String body;
  final Map<String, String> headers;

  /// The transport error when [status] is null.
  final Object? error;

  const ApiResult({
    this.status,
    this.body = '',
    this.headers = const {},
    this.error,
  });

  const ApiResult.transport(Object error) : this(status: null, error: error);

  bool get ok => status != null && status! >= 200 && status! < 300;

  /// 401/403: the key is wrong, not the request.
  bool get isAuthFailure => status == 401 || status == 403;

  /// Transient failure: no response, 5xx or 429.
  bool get retryable => !ok && RetryPolicy.isRetryable(status);

  /// Permanent client-side rejection (4xx other than 401/403/429): the
  /// payload is malformed for this server and must not be retried.
  bool get rejected =>
      status != null &&
      status! >= 400 &&
      status! < 500 &&
      status != 429 &&
      !isAuthFailure;

  /// Parsed `Retry-After` header (seconds form only), if the server sent one.
  int? get retryAfterSeconds {
    final raw = headers['retry-after'];
    return raw == null ? null : int.tryParse(raw.trim());
  }

  /// Short description for logs; never includes the body.
  String describe() =>
      status != null ? 'HTTP $status' : 'no response (${error.runtimeType})';
}

/// HTTP client for the Unilitix ingest API.
class ApiClient {
  final String apiKey;
  final String apiUrl;
  final String sdkVersion;

  /// Per-request budget. Mobile links in the markets this SDK targets can be
  /// slow, but a request that has not completed in this long is better
  /// abandoned and the data kept for the next cycle.
  final Duration requestTimeout;

  final http.Client _client;

  ApiClient({
    required this.apiKey,
    required this.apiUrl,
    required this.sdkVersion,
    this.requestTimeout =
        const Duration(seconds: SdkContract.requestTimeoutSeconds),

    /// Injectable for tests (`MockClient`); production uses a plain client.
    http.Client? client,
  }) : _client = client ?? http.Client();

  Map<String, String> get _headers {
    final h = <String, String>{
      'x-unilitix-key': apiKey,
      'User-Agent': 'Unilitix-Flutter/$sdkVersion',
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (!kIsWeb) h['Content-Encoding'] = 'gzip';
    return h;
  }

  /// Returns gzip-compressed bytes on native platforms.
  /// Returns the original bytes unchanged on web (dart:io GZipCodec
  /// is not available in Flutter web).
  List<int> _gzip(List<int> bytes) {
    if (kIsWeb) return bytes;
    return GZipCodec().encode(bytes);
  }

  /// One attempt, never throws. Every failure mode the HTTP stack can
  /// produce — [TimeoutException], [http.ClientException], and the whole
  /// [IOException] family (SocketException, HttpException,
  /// HandshakeException, "Connection closed before full header") — is turned
  /// into an [ApiResult] with a null status so the scheduler can back off
  /// instead of the error surfacing in the host app as a crash.
  Future<ApiResult> _post(String path, Map<String, dynamic> body) async {
    final url = Uri.parse('$apiUrl$path');
    try {
      final bodyBytes = _gzip(utf8.encode(jsonEncode(body)));
      final resp = await _client
          .post(url, headers: _headers, body: bodyBytes)
          .timeout(requestTimeout);
      final result = ApiResult(
        status: resp.statusCode,
        body: resp.body,
        headers: resp.headers,
      );
      if (!result.ok) {
        UnilitixLogger.w('${result.describe()} on $path');
      }
      return result;
    } on TimeoutException catch (e) {
      return ApiResult.transport(e);
    } on http.ClientException catch (e) {
      return ApiResult.transport(e);
    } on IOException catch (e) {
      return ApiResult.transport(e);
    } catch (e) {
      // Anything else (a JSON encoding error for an unserialisable property,
      // an unexpected platform error) must not escape the SDK either.
      UnilitixLogger.w('Request to $path failed: ${e.runtimeType}');
      return ApiResult.transport(e);
    }
  }

  Future<ApiResult> ingestSession(Map<String, dynamic> payload) =>
      _post('/v1/ingest/session', payload);

  Future<ApiResult> ingestEvents({
    required String sessionId,
    required List<Map<String, dynamic>> events,
  }) =>
      _post('/v1/ingest/events', {
        'sessionId': sessionId,
        'events': events,
      });

  Future<ApiResult> ingestSnapshots(Map<String, dynamic> payload) =>
      _post('/v1/ingest/snapshots', payload);

  /// Reserves upload slots for one batch. [format] is the encoding of every
  /// frame in the batch (see [screenshotFormatOf]); the API stores the frames
  /// under that extension.
  Future<ScreenshotInitResult> initScreenshotUpload({
    required String sessionId,
    required int count,
    required List<int> ordinals,
    String format = 'jpeg',
  }) async {
    final result = await _post(
      '/v1/ingest/screenshots/init',
      ScreenshotInitRequest(
        sessionId: sessionId,
        count: count,
        ordinals: ordinals,
        format: format,
      ).toJson(),
    );
    if (!result.ok) return ScreenshotInitResult(result, null);
    try {
      final parsed = ScreenshotInitResponse.fromJson(
          jsonDecode(result.body) as Map<String, dynamic>);
      return ScreenshotInitResult(
        result,
        parsed.slots
            .map((s) => ScreenshotSlot(
                  ordinal: s.ordinal,
                  presignedUrl: s.presignedUrl,
                ))
            .toList(),
      );
    } catch (e) {
      UnilitixLogger.w('screenshots/init: unexpected response shape: $e');
      return ScreenshotInitResult(result, null);
    }
  }

  Future<bool> uploadScreenshotBytes(
      String presignedUrl, Uint8List bytes) async {
    try {
      final resp = await _client
          .put(
            Uri.parse(presignedUrl),
            headers: {'Content-Type': screenshotContentType(bytes)},
            body: bytes,
          )
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode >= 300) {
        UnilitixLogger.w('uploadScreenshotBytes failed: ${resp.statusCode}');
      }
      return resp.statusCode < 300;
    } catch (e) {
      UnilitixLogger.w('uploadScreenshotBytes failed: ${e.runtimeType}');
      return false;
    }
  }

  /// Confirms an uploaded screenshot and sends its metadata (screen name,
  /// viewport, size, capture time). The server stores that metadata only
  /// from this call, so sending just the ordinal (as versions before 2.0.74
  /// did) left replay frames without a screen name or capture time.
  Future<ApiResult> confirmScreenshotUpload(
      String sessionId, PendingScreenshot screenshot) {
    final body = ScreenshotConfirmRequest(
      sessionId: sessionId,
      screenshots: [
        ScreenshotConfirmItem(
          ordinal: screenshot.ordinal,
          screenName: screenshot.screenName,
          viewportWidth: screenshot.viewportWidth,
          viewportHeight: screenshot.viewportHeight,
          bytes: screenshot.imageBytes.length,
          capturedAt: DateTime.fromMillisecondsSinceEpoch(
            screenshot.capturedAt,
            isUtc: true,
          ).toIso8601String(),
        ),
      ],
    ).toJson();
    return _post('/v1/ingest/screenshots/confirm', body);
  }

  Future<ApiResult> identify({
    required String anonymousId,
    required String customUserId,
    Map<String, dynamic>? traits,
  }) =>
      _post('/v1/ingest/identify', {
        'anonymousId': anonymousId,
        'customUserId': customUserId,
        if (traits != null) 'traits': traits,
      });

  /// Power-outage contribution: `{cell, device, events}` (see
  /// `lib/src/power/power_signals.dart`). One attempt, gzip, the same headers
  /// and outcome semantics as every other call: the caller keeps the events
  /// on [ApiResult.retryable] or [ApiResult.isAuthFailure] and drops them on
  /// [ApiResult.ok] or [ApiResult.rejected].
  Future<ApiResult> postPowerSignals(Map<String, dynamic> body) =>
      _post('/v1/signals/power', body);

  void dispose() => _client.close();
}

/// The encoding of a captured frame, from its leading bytes: `jpeg` (native
/// capture on Android and iOS), `png` (the Dart fallback on web, desktop and
/// Android < 26) or `webp`. Unknown bytes count as jpeg, the common case.
/// Versions before 2.2.1 labelled every frame `image/webp`.
String screenshotFormatOf(Uint8List b) {
  if (b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'png';
  }
  if (b.length >= 12 &&
      b[0] == 0x52 &&
      b[1] == 0x49 &&
      b[2] == 0x46 &&
      b[3] == 0x46 &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'webp';
  }
  return 'jpeg';
}

/// The Content-Type matching [screenshotFormatOf].
String screenshotContentType(Uint8List bytes) =>
    'image/${screenshotFormatOf(bytes)}';
