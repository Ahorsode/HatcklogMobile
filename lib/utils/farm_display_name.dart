import '../core/storage/local_database.dart';

Future<String> resolveFarmDisplayLabel(
  LocalDatabase database,
  String farmId, {
  String fallbackName = '',
}) async {
  if (farmId.trim().isEmpty) {
    return 'Active Farm Monitor';
  }

  try {
    final rows = await database.queryLocalRecords(
      'farms',
      columns: const ['name'],
      where: 'id = ?',
      whereArgs: [farmId.trim()],
      limit: 1,
    );
    if (rows.isEmpty) {
      final fallback = fallbackName.trim();
      if (fallback.isNotEmpty) {
        return 'Active Farm Monitor - $fallback';
      }
      return 'Active Farm Monitor';
    }
    final name = rows.first['name']?.toString().trim() ?? '';
    if (name.isEmpty) {
      final fallback = fallbackName.trim();
      if (fallback.isNotEmpty) {
        return 'Active Farm Monitor - $fallback';
      }
      return 'Active Farm Monitor';
    }
    return 'Active Farm Monitor - $name';
  } on Object {
    return 'Active Farm Monitor';
  }
}

Future<String> resolveFarmName(
  LocalDatabase database,
  String farmId,
) async {
  if (farmId.trim().isEmpty) {
    return 'Farm';
  }

  try {
    final rows = await database.queryLocalRecords(
      'farms',
      columns: const ['name'],
      where: 'id = ?',
      whereArgs: [farmId.trim()],
      limit: 1,
    );
    if (rows.isEmpty) {
      return 'Farm';
    }
    final name = rows.first['name']?.toString().trim() ?? '';
    return name.isEmpty ? 'Farm' : name;
  } on Object {
    return 'Farm';
  }
}
