import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/services/batch_analytics_service.dart';

void main() {
  group('batch analytics calculations', () {
    test('layer FCR uses egg output denominator', () {
      expect(
        calculateFeedConversionRatio(
          livestockType: 'POULTRY_LAYER',
          totalFeed: 160,
          eggOutput: 100,
          birdBiomassGain: 0,
        ),
        1.6,
      );
    });

    test('broiler FCR uses biomass gain denominator', () {
      expect(
        calculateFeedConversionRatio(
          livestockType: 'POULTRY_BROILER',
          totalFeed: 180,
          eggOutput: 0,
          birdBiomassGain: 100,
        ),
        1.8,
      );
    });

    test('mortality rate is dead birds over initial population', () {
      expect(
        calculateMortalityRatePercentage(totalDeadBirds: 35, initialPopulation: 1000),
        3.5,
      );
    });

    test('biomass gain clamps negative weight delta to zero', () {
      expect(
        calculateBatchBiomassGain(
          initialAverageWeight: 2.5,
          latestAverageWeight: 2.0,
          currentBirdCount: 500,
        ),
        0,
      );
    });

    test('returns zero FCR when denominator is zero', () {
      expect(
        calculateFeedConversionRatio(
          livestockType: 'POULTRY_BROILER',
          totalFeed: 100,
          eggOutput: 0,
          birdBiomassGain: 0,
        ),
        0,
      );
    });
  });
}
