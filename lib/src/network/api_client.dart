import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, GZipCodec;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'retry_policy.dart';
import '../generated/ingest_models.dart';
import '../logger/logger.dart';
import '../storage/pending_screenshot.dart';

/// A presigned-URL slot returned by the batch screenshot init endpoint.
class ScreenshotSlot {
  final int ordinal;
  final String presignedUrl;
  const ScreenshotSlot({required this.ordinal, required this.presignedUrl});
}

/// HTTP client for the Unilitix ingest API.
class ApiClient {
  final String apiKey;
  final String apiUrl;
  final String sdkVersion;

  late final http.Client _client;

  ApiClient({
    required this.apiKey,
    required this.apiUrl,
    required this.sdkVersion,
  }) {
    _client = http.Client();
  }

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

  Future<http.Response?> _postWithRetry(
    String path,
    Map<String, dynamic> body,
  ) async {
    final url = Uri.parse('$apiUrl$path');
    final bodyBytes = _gzip(utf8.encode(jsonEncode(body)));

    for (var attempt = 1; attempt <= RetryPolicy.maxRetries; attempt++) {
      try {
        final resp = await _client
            .post(url, headers: _headers, body: bodyBytes)
            .timeout(const Duration(seconds: 40));

        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          return resp;
        }

        if (!RetryPolicy.shouldRetry(
            attempt: attempt, statusCode: resp.statusCode)) {
          UnilitixLogger.w('API ${resp.statusCode} on $path — dropping batch');
          return resp;
        }
        final retryAfterSecs = resp.headers['retry-after'] != null
            ? int.tryParse(resp.headers['retry-after']!)
            : null;
        await Future.delayed(RetryPolicy.delayFor(attempt - 1,
            retryAfterSeconds: retryAfterSecs));
      } on SocketException {
        if (attempt == RetryPolicy.maxRetries) return null;
        await Future.delayed(RetryPolicy.delayFor(attempt - 1));
      } on TimeoutException {
        if (attempt == RetryPolicy.maxRetries) return null;
        await Future.delayed(RetryPolicy.delayFor(attempt - 1));
      }
    }
    return null;
  }

  Future<bool> ingestSession(Map<String, dynamic> payload) async {
    final resp = await _postWithRetry('/v1/ingest/session', payload);
    return resp != null && resp.statusCode < 300;
  }

  /// Returns the raw response so callers can inspect status codes (e.g. 400/409).
  Future<http.Response?> ingestSessionRaw(Map<String, dynamic> payload) =>
      _postWithRetry('/v1/ingest/session', payload);

  Future<bool> ingestEvents({
    required String sessionId,
    required List<Map<String, dynamic>> events,
  }) async {
    final resp = await _postWithRetry('/v1/ingest/events', {
      'sessionId': sessionId,
      'events': events,
    });
    return resp != null && resp.statusCode < 300;
  }

  Future<bool> ingestSnapshots(Map<String, dynamic> payload) async {
    final resp = await _postWithRetry('/v1/ingest/snapshots', payload);
    return resp != null && resp.statusCode < 300;
  }

  Future<List<ScreenshotSlot>?> initScreenshotUpload({
    required String sessionId,
    required int count,
    required List<int> ordinals,
  }) async {
    final resp = await _postWithRetry(
      '/v1/ingest/screenshots/init',
      ScreenshotInitRequest(
        sessionId: sessionId,
        count: count,
        ordinals: ordinals,
      ).toJson(),
    );
    if (resp == null || resp.statusCode >= 300) return null;
    try {
      final parsed = ScreenshotInitResponse.fromJson(
          jsonDecode(resp.body) as Map<String, dynamic>);
      return parsed.slots
          .map((s) => ScreenshotSlot(
                ordinal: s.ordinal,
                presignedUrl: s.presignedUrl,
              ))
          .toList();
    } catch (e, stack) {
      UnilitixLogger.e('screenshots/init: unexpected response shape', e, stack);
      return null;
    }
  }

  Future<bool> uploadScreenshotBytes(
      String presignedUrl, Uint8List bytes) async {
    try {
      final resp = await _client
          .put(
            Uri.parse(presignedUrl),
            headers: {'Content-Type': 'image/webp'},
            body: bytes,
          )
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode >= 300) {
        UnilitixLogger.e(
          'uploadScreenshotBytes failed: ${resp.statusCode}',
          null,
          null,
        );
      }
      return resp.statusCode < 300;
    } catch (e, stack) {
      UnilitixLogger.e('uploadScreenshotBytes failed', e, stack);
      return false;
    }
  }

  /// Confirms an uploaded screenshot and sends its metadata (screen name,
  /// viewport, size, capture time). The server stores that metadata only
  /// from this call, so sending just the ordinal (as versions before 2.0.74
  /// did) left replay frames without a screen name or capture time.
  Future<bool> confirmScreenshotUpload(
      String sessionId, PendingScreenshot screenshot) async {
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
    final resp = await _postWithRetry('/v1/ingest/screenshots/confirm', body);
    return resp != null && resp.statusCode < 300;
  }

  Future<bool> identify({
    required String anonymousId,
    required String customUserId,
    Map<String, dynamic>? traits,
  }) async {
    final resp = await _postWithRetry('/v1/ingest/identify', {
      'anonymousId': anonymousId,
      'customUserId': customUserId,
      if (traits != null) 'traits': traits,
    });
    return resp != null && resp.statusCode < 300;
  }

  void dispose() => _client.close();
}
