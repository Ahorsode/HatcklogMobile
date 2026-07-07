import 'package:flutter/material.dart';

import '../../utils/egg_sale_allocation_utils.dart';

Future<Map<String, Object?>?> showEggSizePickerDialog({
  required BuildContext context,
  required List<Map<String, Object?>> eggInventoryRows,
}) {
  return showDialog<Map<String, Object?>>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: const Text('Select egg size'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final row in eggInventoryRows)
                ListTile(
                  leading: const Icon(Icons.egg_outlined),
                  title: Text(eggSizeLabelFromRow(row)),
                  subtitle: Text(
                    '${row['stock_level'] ?? 0} in stock',
                  ),
                  onTap: () => Navigator.of(context).pop(row),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      );
    },
  );
}
