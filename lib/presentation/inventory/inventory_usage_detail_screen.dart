import 'package:flutter/material.dart';

import '../../core/models/app_user.dart';
import '../../features/inventory/data/inventory_repository.dart';

class InventoryUsageDetailScreen extends StatefulWidget {
  const InventoryUsageDetailScreen({
    super.key,
    required this.currentUser,
    required this.inventoryRepository,
    required this.itemId,
  });

  final AppUser currentUser;
  final InventoryRepository inventoryRepository;
  final String itemId;

  @override
  State<InventoryUsageDetailScreen> createState() =>
      _InventoryUsageDetailScreenState();
}

class _InventoryUsageDetailScreenState extends State<InventoryUsageDetailScreen> {
  late Future<InventoryItemDetail?> _detailFuture;

  @override
  void initState() {
    super.initState();
    _detailFuture = widget.inventoryRepository.getInventoryItemWithUsage(
      widget.currentUser.activeFarmId,
      widget.itemId,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Inventory Usage')),
      body: FutureBuilder<InventoryItemDetail?>(
        future: _detailFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final detail = snapshot.data;
          if (detail == null) {
            return const Center(child: Text('Inventory item not found.'));
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                detail.name,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${detail.stockLevel.toStringAsFixed(1)} ${detail.unit} remaining',
              ),
              if (detail.usageType != null && detail.usageType!.isNotEmpty)
                Text('Usage type: ${detail.usageType}'),
              const SizedBox(height: 20),
              Text(
                'Usage History',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              if (detail.usageEvents.isEmpty)
                const Text('No usage events recorded for this item.')
              else
                ...detail.usageEvents.map(
                  (event) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      title: Text(event.batchName),
                      subtitle: Text(
                        '${event.date.toLocal().toString().split(' ').first} • ${event.source}',
                      ),
                      trailing: Text(event.amount.toStringAsFixed(1)),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
