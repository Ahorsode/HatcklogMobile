import 'package:flutter/material.dart';

import '../../../core/models/app_user.dart';
import '../../../features/sync/data/worker_log_mutator.dart';
import '../../../utils/worker_log_edit_policy.dart';
import '../worker_module_definitions.dart';

Future<void> showWorkerLogActionsSheet({
  required BuildContext context,
  required AppUser currentUser,
  required WorkerModule module,
  required Map<String, Object?> row,
  required WorkerLogMutator logMutator,
  required VoidCallback onEdit,
  required VoidCallback onDeleted,
}) async {
  final recordId = row['id']?.toString() ?? '';
  if (recordId.isEmpty) {
    return;
  }
  final canMutate = canWorkerMutateLogRow(
    currentUserId: currentUser.id,
    row: row,
  );

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _titleFor(module, row),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                canMutate
                    ? 'You can edit or delete this entry for up to 24 hours after logging.'
                    : workerLogLockMessage(),
                style: TextStyle(
                  color: canMutate
                      ? const Color(0xff66736c)
                      : const Color(0xffb83b3b),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              if (canMutate) ...[
                FilledButton.icon(
                  onPressed: () {
                    Navigator.of(context).pop();
                    onEdit();
                  },
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit entry'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) {
                        return AlertDialog(
                          title: const Text('Delete log entry?'),
                          content: const Text(
                            'This removes the entry from your farm records. '
                            'You cannot undo this after 24 hours.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.of(dialogContext).pop(true),
                              child: const Text('Delete'),
                            ),
                          ],
                        );
                      },
                    );
                    if (confirmed != true || !context.mounted) {
                      return;
                    }
                    try {
                      await logMutator.deleteWorkerLog(
                        user: currentUser,
                        module: module,
                        recordId: recordId,
                      );
                      if (context.mounted) {
                        Navigator.of(context).pop();
                        onDeleted();
                      }
                    } on Object catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('$error')),
                        );
                      }
                    }
                  },
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete entry'),
                ),
              ] else
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
            ],
          ),
        ),
      );
    },
  );
}

String _titleFor(WorkerModule module, Map<String, Object?> row) {
  return switch (module) {
    WorkerModule.eggs => '${_asInt(row['eggs_collected'])} eggs logged',
    WorkerModule.feeding =>
      '${_asDouble(row['amount_consumed']).toStringAsFixed(2)} bags fed',
    WorkerModule.mortality => '${_asInt(row['count'])} birds logged',
    _ => 'Log entry',
  };
}

int _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _asDouble(Object? value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}
