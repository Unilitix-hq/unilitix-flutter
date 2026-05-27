import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/unilitix.dart';

void main() {
  test('SDK is not initialized by default', () {
    expect(Unilitix.isInitialized, false);
  });

  test('default config has expected values', () {
    const config = UnilitixConfig();
    expect(config.endpoint, 'https://api.unilitix.com');
    expect(config.autoTrackScreens, true);
    expect(config.autoTrackTaps, true);
    expect(config.autoTrackCrashes, true);
    expect(config.autoTrackRageTaps, true);
    expect(config.maskInputs, true);
    expect(config.sampleRate, 1.0);
    expect(config.flushIntervalSeconds, 30);
    expect(config.sessionTimeoutSeconds, 1800);
    expect(config.debug, false);
  });
}
