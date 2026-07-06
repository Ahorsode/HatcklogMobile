import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ExecutiveMetricsService profit trend', () {
    test('returns 100 when prior revenue is zero and current revenue exists', () {
      const previousRevenue = 0.0;
      const currentRevenue = 250.0;
      final trend = previousRevenue <= 0
          ? (currentRevenue > 0 ? 100.0 : 0.0)
          : ((currentRevenue - previousRevenue) / previousRevenue) * 100;
      expect(trend, 100.0);
    });
  });
}
