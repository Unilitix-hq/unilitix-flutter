import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:unilitix/unilitix.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SDK is not initialized before init()', (tester) async {
    expect(Unilitix.isInitialized, false);
  });
}
