import 'dart:convert';
import 'dart:io' show GZipCodec;

import 'package:http/http.dart' as http;

import '../generated/sdk_contract.dart';

/// Outcome of one `POST /v1/signals/power`.
class PowerPostResult {
  const PowerPostResult(this.status);

  /// HTTP status, or null when no response arrived.
  final int? status;

  bool get ok => status != null && status! >= 200 && status! < 300;

  /// A 4xx that resending the same body can never fix (not 401/402/403/
  /// 408/429): the batch is dropped.
  bool get rejected =>
      status != null &&
      status! >= 400 &&
      status! < 500 &&
      !const {401, 402, 403, 408, 429}.contains(status);
}

/// Uploads iOS power-outage signals.
///
/// Power-outage contribution is a Flutter-only feature (the native cores do
/// not have it), so it keeps its own small sender in 3.0.0: Android uploads
/// from the plugin (WorkManager, `PowerContribution.kt`), iOS from here.
/// Every other request is made by the native SDK.
class PowerTransport {
  PowerTransport({
    required this.apiKey,
    required this.apiUrl,
    required this.sdkVersion,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String apiKey;
  final String apiUrl;
  final String sdkVersion;
  final http.Client _client;

  /// One gzip POST; never throws.
  Future<PowerPostResult> post(Map<String, dynamic> body) async {
    try {
      final resp = await _client
          .post(
            Uri.parse('$apiUrl/v1/signals/power'),
            headers: {
              SdkContract.apiKeyHeader: apiKey,
              'User-Agent': 'Unilitix-Flutter/$sdkVersion',
              'Content-Type': 'application/json',
              'Content-Encoding': 'gzip',
            },
            body: GZipCodec().encode(utf8.encode(jsonEncode(body))),
          )
          .timeout(const Duration(seconds: SdkContract.requestTimeoutSeconds));
      return PowerPostResult(resp.statusCode);
    } catch (_) {
      return const PowerPostResult(null);
    }
  }
}
