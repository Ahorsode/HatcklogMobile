import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/app_user.dart';
import '../../core/settings/settings_profile_contract.dart';
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
  String _activeTab = SettingsProfileContract.trashTabs.first.key;
  String _search = '';
  List<_TrashRecord> _records = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final tables = SettingsProfileContract.trashTabs
        .map((tab) => tab.localTable)
        .toSet();
    _subscription = widget.localDatabase.watchTables(tables).listen((_) {
      _loadTrash();
    });
    _loadTrash();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _loadTrash() async {
    final records = <_TrashRecord>[];
    final farmId = widget.currentUser.activeFarmId;
    try {
      for (final tab in SettingsProfileContract.trashTabs) {
        final rows = await widget.localDatabase.queryLocalRecords(
          tab.localTable,
          where: 'farm_id = ? and is_deleted = 1',
          whereArgs: [farmId],
          orderBy: 'deleted_at desc',
        );
        for (final row in rows) {
          records.add(_TrashRecord(tab: tab, row: row));
        }
      }
    } on StateError {
      records.clear();
    }
    if (!mounted) return;
    setState(() {
      _records = records;
      _loading = false;
    });
  }

  Future<void> _restore(_TrashRecord record) async {
    if (!record.tab.restoreAllowed) return;
    final id = record.id;
    if (id.isEmpty) return;

    await widget.localDatabase.updateLocalRecord(
      record.tab.localTable,
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
          'table': record.tab.localTable,
          'record_id': id,
        },
        createdAt: DateTime.now(),
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${record.tab.label} restored.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    _loadTrash();
  }

  List<_TrashRecord> get _filteredRecords {
    final query = _search.trim().toLowerCase();
    return _records.where((record) {
      if (record.tab.key != _activeTab) return false;
      if (query.isEmpty) return true;
      return record.title.toLowerCase().contains(query) ||
          record.subtitle.toLowerCase().contains(query);
    }).toList();
  }

  int _countForTab(String key) =>
      _records.where((record) => record.tab.key == key).length;

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredRecords;
    final activeTab = SettingsProfileContract.tabByKey(_activeTab)!;

    return Scaffold(
      backgroundColor: const Color(0xfff8faf7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('Data Recovery Center'),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Search records…',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) => setState(() => _search = value),
                    ),
                  ),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: SettingsProfileContract.trashTabs.map((tab) {
                        final count = _countForTab(tab.key);
                        final selected = tab.key == _activeTab;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8, bottom: 8),
                          child: FilterChip(
                            label: Text('${tab.label}${count > 0 ? ' ($count)' : ''}'),
                            selected: selected,
                            onSelected: (_) => setState(() => _activeTab = tab.key),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Text(
                              'No deleted ${activeTab.label.toLowerCase()} found.',
                              style: const TextStyle(
                                color: Color(0xff66736c),
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final record = filtered[index];
                              return Padding(
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
                                  trailing: record.tab.restoreAllowed
                                      ? FilledButton(
                                          onPressed: () => _restore(record),
                                          child: const Text('Restore'),
                                        )
                                      : const Text(
                                          'Audit only',
                                          style: TextStyle(
                                            color: Color(0xff66736c),
                                            fontStyle: FontStyle.italic,
                                            fontSize: 12,
                                          ),
                                        ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _TrashRecord {
  const _TrashRecord({required this.tab, required this.row});

  final TrashTabDefinition tab;
  final Map<String, Object?> row;

  String get id => row['id']?.toString() ?? '';

  String get title {
    final value = row[tab.titleColumn]?.toString().trim() ?? '';
    if (value.isNotEmpty) return value;
    return id.isEmpty ? tab.label : id;
  }

  String get subtitle {
    final deletedAt = row['deleted_at']?.toString() ?? '';
    return deletedAt.isEmpty ? tab.localTable : '${tab.localTable} | $deletedAt';
  }
}
