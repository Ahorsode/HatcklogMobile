import 'package:flutter/material.dart';

import '../../core/models/app_user.dart';
import '../../features/inventory/data/inventory_repository.dart';
import 'inventory_usage_detail_screen.dart';

class InventoryListScreen extends StatefulWidget {
  const InventoryListScreen({
    super.key,
    required this.currentUser,
    required this.inventoryRepository,
  });

  final AppUser currentUser;
  final InventoryRepository inventoryRepository;

  @override
  State<InventoryListScreen> createState() => _InventoryListScreenState();
}

class _InventoryListScreenState extends State<InventoryListScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late Future<List<Map<String, Object?>>> _activeFuture;
  late Future<List<Map<String, Object?>>> _usedUpFuture;
  late Future<int> _usedUpCountFuture;
  late Future<ActiveBatchEggStock> _eggStockFuture;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _reload();
  }

  void _reload() {
    final farmId = widget.currentUser.activeFarmId;
    _activeFuture = widget.inventoryRepository
        .getAllInventory(farmId: farmId, filter: InventoryFilter.active)
        .then(_withoutEggSkus);
    _usedUpFuture = widget.inventoryRepository
        .getAllInventory(farmId: farmId, filter: InventoryFilter.usedUp)
        .then(_withoutEggSkus);
    _usedUpCountFuture = widget.inventoryRepository.getUsedUpInventoryCount(farmId);
    _eggStockFuture = widget.inventoryRepository.getActiveBatchEggStock(farmId);
  }

  List<Map<String, Object?>> _withoutEggSkus(List<Map<String, Object?>> rows) {
    return rows
        .where(
          (row) =>
              (row['category']?.toString().trim().toUpperCase() ?? '') != 'EGGS',
        )
        .toList(growable: false);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventory'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            const Tab(text: 'In stock'),
            FutureBuilder<int>(
              future: _usedUpCountFuture,
              builder: (context, snapshot) {
                final count = snapshot.data ?? 0;
                return Tab(text: count > 0 ? 'Used up ($count)' : 'Used up');
              },
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _ActiveInventoryTab(
            itemsFuture: _activeFuture,
            eggStockFuture: _eggStockFuture,
            onTap: _openDetail,
          ),
          _InventoryList(
            future: _usedUpFuture,
            emptyMessage: 'No used-up inventory items.',
            onTap: _openDetail,
          ),
        ],
      ),
    );
  }

  Future<void> _openDetail(Map<String, Object?> item) async {
    final itemId = item['id']?.toString() ?? '';
    if (itemId.isEmpty) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => InventoryUsageDetailScreen(
          currentUser: widget.currentUser,
          inventoryRepository: widget.inventoryRepository,
          itemId: itemId,
        ),
      ),
    );
  }
}

class _ActiveInventoryTab extends StatelessWidget {
  const _ActiveInventoryTab({
    required this.itemsFuture,
    required this.eggStockFuture,
    required this.onTap,
  });

  final Future<List<Map<String, Object?>>> itemsFuture;
  final Future<ActiveBatchEggStock> eggStockFuture;
  final Future<void> Function(Map<String, Object?>) onTap;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(ActiveBatchEggStock, List<Map<String, Object?>>)>(
      future: Future.wait([eggStockFuture, itemsFuture]).then(
        (results) => (results[0] as ActiveBatchEggStock, results[1] as List<Map<String, Object?>>),
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final eggStock = snapshot.data?.$1 ?? const ActiveBatchEggStock(totalEggs: 0, batches: []);
        final items = snapshot.data?.$2 ?? const [];
        if (eggStock.totalEggs == 0 && items.isEmpty) {
          return const Center(child: Text('No in-stock inventory items.'));
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (eggStock.totalEggs > 0) ...[
              Card(
                color: const Color(0xfffff8e8),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Egg Inventory (Active Batches)',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${eggStock.totalEggs} eggs',
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 12),
                      for (final batch in eggStock.batches)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            children: [
                              Expanded(child: Text(batch.batchName, style: const TextStyle(fontWeight: FontWeight.w700))),
                              Text('${batch.eggsRemaining} eggs'),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            for (var index = 0; index < items.length; index += 1) ...[
              if (index > 0) const SizedBox(height: 8),
              _InventoryCard(item: items[index], onTap: onTap),
            ],
          ],
        );
      },
    );
  }
}

class _InventoryCard extends StatelessWidget {
  const _InventoryCard({required this.item, required this.onTap});

  final Map<String, Object?> item;
  final Future<void> Function(Map<String, Object?>) onTap;

  @override
  Widget build(BuildContext context) {
    final stock = _double(item['stock_level']);
    final unit = item['unit']?.toString() ?? '';
    return Card(
      child: ListTile(
        title: Text(item['item_name']?.toString() ?? 'Item'),
        subtitle: Text(item['category']?.toString() ?? ''),
        trailing: Text('${stock.toStringAsFixed(1)} $unit'),
        onTap: () => onTap(item),
      ),
    );
  }

  double _double(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }
}

class _InventoryList extends StatelessWidget {
  const _InventoryList({
    required this.future,
    required this.emptyMessage,
    required this.onTap,
  });

  final Future<List<Map<String, Object?>>> future;
  final String emptyMessage;
  final Future<void> Function(Map<String, Object?>) onTap;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, Object?>>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final items = snapshot.data ?? const [];
        if (items.isEmpty) {
          return Center(child: Text(emptyMessage));
        }
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: items.length,
          separatorBuilder: (_, index) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final item = items[index];
            final stock = _double(item['stock_level']);
            final unit = item['unit']?.toString() ?? '';
            return Card(
              child: ListTile(
                title: Text(item['item_name']?.toString() ?? 'Item'),
                subtitle: Text(item['category']?.toString() ?? ''),
                trailing: Text('${stock.toStringAsFixed(1)} $unit'),
                onTap: () => onTap(item),
              ),
            );
          },
        );
      },
    );
  }

  double _double(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }
}
