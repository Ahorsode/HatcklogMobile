import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/utils/livestock_breed_options.dart';

void main() {
  test('normalizeBreedKey maps legacy aliases to web keys', () {
    expect(
      LivestockBreedCatalog.normalizeBreedKey('Cobb 500'),
      'ross_308',
    );
    expect(
      LivestockBreedCatalog.normalizeBreedKey('white_fulani'),
      'local_zebu_sanga_white_fulani',
    );
    expect(
      LivestockBreedCatalog.normalizeBreedKey('ashanti_black'),
      'ashanti_black_local_cross',
    );
  });

  test('categoryToType matches web LivestockType values', () {
    expect(
      LivestockBreedCatalog.categoryToType(LivestockBreedCatalog.poultryMeat),
      'POULTRY_BROILER',
    );
    expect(
      LivestockBreedCatalog.categoryToType(LivestockBreedCatalog.other),
      'OTHER',
    );
  });
}
