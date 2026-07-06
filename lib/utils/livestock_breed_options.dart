import 'package:flutter/material.dart';

class LivestockBreedOption {
  final String key;
  final String label;
  final Color color;
  final Color borderColor;
  final Color? splitColor;

  const LivestockBreedOption({
    required this.key,
    required this.label,
    required this.color,
    this.borderColor = Colors.transparent,
    this.splitColor,
  });
}

/// Mirrors web `livestock-breed-options.ts` for offline-first mobile parity.
class LivestockBreedCatalog {
  static const poultryMeat = 'Poultry (Meat)';
  static const poultryEggs = 'Poultry (Eggs)';
  static const cattle = 'Cattle / Livestock';
  static const sheepGoat = 'Sheep / Goat';
  static const pigSwine = 'Pig / Swine';
  static const other = 'Other / Generic';

  static const categories = <String>[
    poultryMeat,
    poultryEggs,
    cattle,
    sheepGoat,
    pigSwine,
    other,
  ];

  static const optionsByCategory = <String, List<LivestockBreedOption>>{
    poultryMeat: [
      LivestockBreedOption(
        key: 'ross_308',
        label: 'White Broiler (Cobb 500 / Ross 308)',
        color: Color(0xFFFDFBF7),
        borderColor: Color(0xFFB8B8B8),
      ),
    ],
    poultryEggs: [
      LivestockBreedOption(
        key: 'isa_brown',
        label: 'Brown Layer (ISA Brown / Lohmann)',
        color: Color(0xFFB3541E),
      ),
      LivestockBreedOption(
        key: 'bovans_black',
        label: 'Black Layer (Bovans Black)',
        color: Color(0xFF222222),
      ),
    ],
    cattle: [
      LivestockBreedOption(
        key: 'local_zebu_sanga_white_fulani',
        label: 'Local Zebu / Sanga / White Fulani',
        color: Color(0xFFD2B48C),
      ),
      LivestockBreedOption(
        key: 'ndama_brown_crosses',
        label: 'Ndama / Brown Crosses',
        color: Color(0xFF5C2C16),
      ),
    ],
    sheepGoat: [
      LivestockBreedOption(
        key: 'west_african_dwarf',
        label: 'West African Dwarf (Local)',
        color: Color(0xFFFDFBF7),
        borderColor: Color(0xFFC29160),
        splitColor: Color(0xFF111111),
      ),
      LivestockBreedOption(
        key: 'sahelian_northern_cross',
        label: 'Sahelian / Northern Cross',
        color: Color(0xFFFDFBF7),
        borderColor: Color(0xFFD2B48C),
      ),
    ],
    pigSwine: [
      LivestockBreedOption(
        key: 'large_white',
        label: 'Large White / Landrace',
        color: Color(0xFFF6C3C3),
      ),
      LivestockBreedOption(
        key: 'ashanti_black_local_cross',
        label: 'Ashanti Black / Local Cross',
        color: Color(0xFF111111),
      ),
    ],
    other: [],
  };

  static List<LivestockBreedOption> optionsForCategory(String? category) {
    return optionsByCategory[normalizeCategory(category)] ??
        optionsByCategory[poultryMeat]!;
  }

  static String normalizeCategory(String? category) {
    switch ((category ?? '').trim().toUpperCase()) {
      case 'POULTRY (EGG)':
      case 'POULTRY (EGGS)':
      case 'POULTRY_LAYER':
        return poultryEggs;
      case 'CATTLE':
      case 'CATTLE / LIVESTOCK':
        return cattle;
      case 'SHEEP_GOAT':
      case 'SHEEP / GOAT':
        return sheepGoat;
      case 'PIG':
      case 'SWINE':
      case 'PIG / SWINE':
        return pigSwine;
      case 'OTHER':
      case 'OTHER / GENERIC':
        return other;
      case 'POULTRY_BROILER':
      case 'POULTRY (MEAT)':
      default:
        return poultryMeat;
    }
  }

  static String categoryToType(String category) {
    switch (normalizeCategory(category)) {
      case poultryEggs:
        return 'POULTRY_LAYER';
      case cattle:
        return 'CATTLE';
      case sheepGoat:
        return 'SHEEP_GOAT';
      case pigSwine:
        return 'PIG';
      case other:
        return 'OTHER';
      case poultryMeat:
      default:
        return 'POULTRY_BROILER';
    }
  }

  static String typeToCategory(String type) => normalizeCategory(type);

  static LivestockBreedOption optionForKey(String? key) {
    final normalized = normalizeBreedKey(key);
    for (final options in optionsByCategory.values) {
      for (final option in options) {
        if (option.key == normalized) return option;
      }
    }
    return LivestockBreedOption(
      key: normalized,
      label: key == null || key.trim().isEmpty ? 'N/A' : key.trim(),
      color: const Color(0xFFD2B48C),
    );
  }

  static String labelForKey(String? key) => optionForKey(key).label;

  static String normalizeBreedKey(String? value) {
    if (value == null || value.trim().isEmpty) return '';

    final normalized = value.trim().toLowerCase().replaceAll(RegExp(r'[\s/-]+'), '_');
    const legacyAliases = <String, String>{
      'broiler': 'ross_308',
      'ross_308': 'ross_308',
      'cobb_500': 'ross_308',
      'hubbard': 'ross_308',
      'layer': 'isa_brown',
      'isa_brown': 'isa_brown',
      'isa': 'isa_brown',
      'lohmann': 'isa_brown',
      'bovans_black': 'bovans_black',
      'leghorn': 'isa_brown',
      'large_white': 'large_white',
      'landrace': 'large_white',
      'white_fulani': 'local_zebu_sanga_white_fulani',
      'local_zebu_sanga_white_fulani': 'local_zebu_sanga_white_fulani',
      'ndama_brown_cross': 'ndama_brown_crosses',
      'ndama_brown_crosses': 'ndama_brown_crosses',
      'ashanti_black': 'ashanti_black_local_cross',
      'ashanti_black_local_cross': 'ashanti_black_local_cross',
    };

    return legacyAliases[normalized] ?? normalized;
  }

  static String? breedKeyForLabel(String? label) {
    if (label == null || label.trim().isEmpty) return null;
    for (final options in optionsByCategory.values) {
      for (final option in options) {
        if (option.label == label) return option.key;
      }
    }
    return normalizeBreedKey(label);
  }
}
