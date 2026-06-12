import 'dart:convert';

import 'package:flutter/material.dart';

void showHatchLogDetailsPopup(
  BuildContext context,
  Map<String, dynamic> rawData,
  String modalTitle,
) {
  final displayEntries = rawData.entries.where(
    (entry) => !_hiddenDetailKeys.contains(entry.key),
  );

  showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Text(
          modalTitle,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final entry in displayEntries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 2,
                        child: Text(
                          '${_cleanLabel(entry.key)}:',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Colors.blueGrey,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 3,
                        child: SelectableText(
                          _displayValue(entry.value),
                          style: const TextStyle(
                            fontWeight: FontWeight.w400,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Dismiss',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Color(0xff1f7a4d),
              ),
            ),
          ),
        ],
      );
    },
  );
}

const _hiddenDetailKeys = {
  'id',
  'farmId',
  'farm_id',
  'userId',
  'user_id',
  'tenant_id',
  'created_by',
  'deletedAt',
  'deleted_at',
  'isDeleted',
  'is_deleted',
};

String _cleanLabel(String key) {
  final spaced = key
      .replaceAll(RegExp(r'(?=[A-Z])'), ' ')
      .replaceAll('_', ' ')
      .trim();
  return spaced
      .split(RegExp(r'\s+'))
      .map((word) {
        if (word.isEmpty) {
          return '';
        }
        return word[0].toUpperCase() + word.substring(1);
      })
      .join(' ');
}

String _displayValue(Object? value) {
  if (value == null) {
    return 'N/A';
  }
  if (value is DateTime) {
    return value.toLocal().toString();
  }
  if (value is Map || value is Iterable) {
    return const JsonEncoder.withIndent('  ').convert(value);
  }
  return value.toString();
}
