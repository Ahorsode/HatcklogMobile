import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/app_user.dart';
import '../../core/storage/local_database.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({
    super.key,
    required this.currentUser,
    required this.localDatabase,
  });

  final AppUser currentUser;
  final LocalDatabase localDatabase;

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  StreamSubscription<void>? _subscription;
  List<_TrashRecord> _records = const [];
  bool _loading = true;

  static const _tables = <_TrashTable>[
    _TrashTable('batches', 'Livestock', 'batch_name'),
    _TrashTable('inventory', 'Inventory', 'item_name'),
    _TrashTable('egg_production', 'Eggs', 'log_date'),
    _TrashTable('daily_feeding_logs', 'Feeding', 'log_date'),
    _TrashTable('mortality', 'Mortality', 'log_date'),
    _TrashTable('quarantine', 'Quarantine', 'log_date'),
    _TrashTable('expenses', 'Expenses', 'category'),
    _TrashTable('financial_transactions', 'Finance', 'category'),
    _TrashTable('sales', 'Sales', 'sale_date'),
    _TrashTable('orders', 'Orders', 'order_date'),
  ];

  @override
  void initState() {
    super.initState();
    _subscription = widget.localDatabase
        .watchTables(_tables.map((table) => table.name))
        .listen((_) => _loadTrash());
    _loadTrash();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _loadTrash() async {
    final records = <_TrashRecord>[];
    try {
      for (final table in _tables) {
        final rows = await widget.localDatabase.queryLocalRecords(
          table.name,
          where: 'farm_id = ? and is_deleted = 1',
          whereArgs: [widget.currentUser.activeFarmId],
          orderBy: 'deleted_at desc',
        );
        for (final row in rows) {
          records.add(_TrashRecord(table: table, row: row));
        }
      }
    } on StateError {
      records.clear();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _records = records;
      _loading = false;
    });
  }

  Future<void> _restore(_TrashRecord record) async {
    final id = record.id;
    if (id.isEmpty) {
      return;
    }
    await widget.localDatabase.updateLocalRecord(
      record.table.name,
      {'is_deleted': 0, 'deleted_at': null},
      where: 'id = ?',
      whereArgs: [id],
    );
    await widget.localDatabase.insertPendingInput(
      PendingSyncInput(
        userId: widget.currentUser.id,
        inputType: 'restore_record',
        payload: {
          'farm_id': widget.currentUser.activeFarmId,
          'table': record.table.name,
          'record_id': id,
        },
        createdAt: DateTime.now(),
      ),
    );
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${record.table.label} restored.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    _loadTrash();
  }

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<_TrashRecord>>{};
    for (final record in _records) {
      grouped.putIfAbsent(record.table.label, () => []).add(record);
    }
    return Scaffold(
      backgroundColor: const Color(0xfff8faf7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('Data Recovery'),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _records.isEmpty
            ? const Center(
                child: Text(
                  'Trash is empty.',
                  style: TextStyle(
                    color: Color(0xff66736c),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                children: [
                  for (final entry in grouped.entries) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8, top: 6),
                      child: Text(
                        entry.key,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0,
                            ),
                      ),
                    ),
                    for (final record in entry.value)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          tileColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: const BorderSide(color: Color(0xffe1e7e3)),
                          ),
                          title: Text(
                            record.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          subtitle: Text(record.subtitle),
                          trailing: FilledButton(
                            onPressed: () => _restore(record),
                            child: const Text('Restore'),
                          ),
                        ),
                      ),
                  ],
                ],
              ),
      ),
    );
  }
}

class _TrashTable {
  const _TrashTable(this.name, this.label, this.titleColumn);

  final String name;
  final String label;
  final String titleColumn;
}

class _TrashRecord {
  const _TrashRecord({required this.table, required this.row});

  final _TrashTable table;
  final Map<String, Object?> row;

  String get id => row['id']?.toString() ?? '';

  String get title {
    final value = row[table.titleColumn]?.toString().trim() ?? '';
    if (value.isNotEmpty) {
      return value;
    }
    return id.isEmpty ? table.label : id;
  }

  String get subtitle {
    final deletedAt = row['deleted_at']?.toString() ?? '';
    return deletedAt.isEmpty ? table.name : '${table.name} | $deletedAt';
  }
}
