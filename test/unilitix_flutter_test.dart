import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/unilitix.dart';

void main() {
  test('SDK is not initialized by default', () {
    expect(Unilitix.isInitialized, false);
  });

  test('UnilitixConfig has correct defaults', () {
    const config = UnilitixConfig(apiKey: 'test_key');
    expect(config.apiUrl, 'https://api.unilitix.com');
    expect(config.autoTrackTaps, true);
    expect(config.sessionTimeoutSeconds, 1800);
    expect(config.flushBatchSize, 100);
    expect(config.maxOfflineEvents, 1000);
  });
}
