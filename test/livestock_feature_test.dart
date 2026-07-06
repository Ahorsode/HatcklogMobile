import 'package:flutter_test/flutter_test.dart';

import 'package:hatchlog_m/features/livestock/data/livestock_models.dart';
import 'package:hatchlog_m/utils/livestock_breed_options.dart';

void main() {
  test('species filter matches poultry types', () {
    expect(
      LivestockSpeciesFilter.poultry.matchesBatchType('POULTRY_BROILER'),
      isTrue,
    );
    expect(
      LivestockSpeciesFilter.cattle.matchesBatchType('POULTRY_LAYER'),
      isFalse,
    );
  });

  test('create draft maps category to db type', () {
    final draft = CreateLivestockDraft(
      batchName: 'Unit A',
      category: LivestockBreedCatalog.poultryEggs,
      breedKey: 'isa_brown',
      houseId: 'house-1',
      initialCount: 500,
      arrivalDate: DateTime(2026, 1, 1),
    );
    expect(draft.type, 'POULTRY_LAYER');
  });

  test('batch record computes mortality from counts', () {
    final batch = LivestockBatchRecord.fromMap({
      'id': 'b1',
      'farm_id': 'f1',
      'house_id': 'h1',
      'batch_name': 'Alpha',
      'breed_type': 'ross_308',
      'type': 'POULTRY_BROILER',
      'status': 'active',
      'initial_count': 1000,
      'current_count': 900,
      'isolation_count': 20,
      'arrival_date': '2026-01-01T00:00:00.000',
    });
    expect(batch.mortalityCount, 80);
    expect(batch.hasMissingCost, isTrue);
  });
}
