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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _reload();
  }

  void _reload() {
    final farmId = widget.currentUser.activeFarmId;
    _activeFuture = widget.inventoryRepository.getAllInventory(
      farmId: farmId,
      filter: InventoryFilter.active,
    );
    _usedUpFuture = widget.inventoryRepository.getAllInventory(
      farmId: farmId,
      filter: InventoryFilter.usedUp,
    );
    _usedUpCountFuture = widget.inventoryRepository.getUsedUpInventoryCount(farmId);
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
          _InventoryList(
            future: _activeFuture,
            emptyMessage: 'No in-stock inventory items.',
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
