import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  Map<String, String> get _headers => {
        'x-unilitix-key': apiKey,
        'User-Agent': 'Unilitix-Flutter/$sdkVersion',
        'Content-Type': 'application/json',
        'Content-Encoding': 'gzip',
        'Accept': 'application/json',
      };

  Uint8List _gzip(String json) {
    final codec = GZipCodec();
    return Uint8List.fromList(codec.encode(utf8.encode(json)));
  }

  Future<http.Response?> _postWithRetry(
    String path,
    Map<String, dynamic> body,
  ) async {
    final url = Uri.parse('$apiUrl$path');
    final bodyBytes = _gzip(jsonEncode(body));

    for (var attempt = 1; attempt <= RetryPolicy.maxRetries; attempt++) {
      try {
        final resp = await _client
            .post(url, headers: _headers, body: bodyBytes)
            .timeout(const Duration(seconds: 40));

        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          return resp;
        }

        final delay = RetryPolicy.delayFor(
          attempt: attempt,
          statusCode: resp.statusCode,
          retryAfterHeader: resp.headers['retry-after'],
        );
        if (delay < 0 ||
            !RetryPolicy.shouldRetry(
                attempt: attempt, statusCode: resp.statusCode)) {
          UnilitixLogger.w('API ${resp.statusCode} on $path — dropping batch');
          return resp;
        }
        await Future.delayed(Duration(milliseconds: delay));
      } on SocketException {
        if (attempt == RetryPolicy.maxRetries) return null;
        await Future.delayed(
          Duration(
              milliseconds:
                  RetryPolicy.delayFor(attempt: attempt, statusCode: null)),
        );
      } on TimeoutException {
        if (attempt == RetryPolicy.maxRetries) return null;
        await Future.delayed(
          Duration(
              milliseconds:
                  RetryPolicy.delayFor(attempt: attempt, statusCode: null)),
        );
      }
    }
    return null;
  }

  Future<bool> ingestSession(Map<String, dynamic> payload) async {
    final resp = await _postWithRetry('/v1/ingest/session', payload);
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
            headers: {'Content-Type': 'image/png'},
            body: bytes,
          )
          .timeout(const Duration(seconds: 60));
      return resp.statusCode < 300;
    } catch (_) {
      return false;
    }
  }

  Future<bool> confirmScreenshotUpload(Map<String, dynamic> payload) async {
    final resp =
        await _postWithRetry('/v1/ingest/screenshots/confirm', payload);
    return resp != null && resp.statusCode < 300;
  }

  void dispose() => _client.close();
}
