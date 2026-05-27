import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/unilitix.dart';

void main() {
  testWidgets('SDK not initialized by default', (tester) async {
    expect(Unilitix.isInitialized, false);
  });
}
