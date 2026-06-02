import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, GZipCodec;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'retry_policy.dart';
import '../logger/logger.dart';

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
        await Future.delayed(
            RetryPolicy.delayFor(attempt - 1, retryAfterSeconds: retryAfterSecs));
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

  Future<String?> initScreenshotUpload(Map<String, dynamic> metadata) async {
    final resp = await _postWithRetry('/v1/ingest/screenshots/init', metadata);
    if (resp == null || resp.statusCode >= 300) return null;
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return json['presignedUrl'] as String?;
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
      return resp.statusCode < 300;
    } catch (e, stack) {
      UnilitixLogger.e('uploadScreenshotBytes failed', e, stack);
      return false;
    }
  }

  Future<bool> confirmScreenshotUpload(Map<String, dynamic> payload) async {
    final resp =
        await _postWithRetry('/v1/ingest/screenshots/confirm', payload);
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
