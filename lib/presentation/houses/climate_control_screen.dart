import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/app_user.dart';
import '../../core/storage/local_database.dart';
import '../../services/local_house_service.dart';
import '../../utils/house_climate_utils.dart';

class ClimateControlScreen extends StatefulWidget {
  const ClimateControlScreen({
    super.key,
    required this.currentUser,
    required this.localDatabase,
    this.canEdit = true,
  });

  final AppUser currentUser;
  final LocalDatabase localDatabase;
  final bool canEdit;

  @override
  State<ClimateControlScreen> createState() => _ClimateControlScreenState();
}

class _ClimateControlScreenState extends State<ClimateControlScreen> {
  StreamSubscription<void>? _subscription;
  List<_HouseClimateVm> _houses = const [];
  late final LocalHouseService _houseService;

  @override
  void initState() {
    super.initState();
    _houseService = LocalHouseService(widget.localDatabase);
    _subscription = widget.localDatabase
        .watchTables(const ['houses', 'batches'])
        .listen((_) => _loadHouses());
    _loadHouses();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _loadHouses() async {
    try {
      final rows = await widget.localDatabase.rawLocalQuery(
        '''
        select h.id,
               h.name,
               h.capacity,
               h.current_temperature,
               h.current_humidity,
               h.is_isolation,
               h.environmental_state,
               coalesce(sum(case when b.is_deleted = 0 then b.current_count else 0 end), 0) as occupied
        from houses h
        left join batches b on b.house_id = h.id
        where h.farm_id = ?
          and coalesce(h.is_deleted, 0) = 0
        group by h.id
        order by h.name asc
        ''',
        [widget.currentUser.activeFarmId],
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _houses = rows
            .map(
              (row) {
                final temperature = _nullableDouble(row['current_temperature']);
                final humidity = _nullableDouble(row['current_humidity']);
                final status = resolveClimateStatus(
                  temperature: temperature,
                  humidity: humidity,
                );
                return _HouseClimateVm(
                  id: _text(row['id']),
                  name: _text(row['name'], 'House'),
                  capacity: _asInt(row['capacity']),
                  occupied: _asInt(row['occupied']),
                  temperature: temperature,
                  humidity: humidity,
                  isIsolation: _asBool(row['is_isolation']),
                  status: status,
                );
              },
            )
            .toList(growable: false);
      });
    } on StateError {
      if (mounted) {
        setState(() => _houses = const []);
      }
    }
  }

  Future<void> _showEditDialog(_HouseClimateVm house) async {
    if (!widget.canEdit) {
      return;
    }

    final tempController = TextEditingController(
      text: house.temperature?.toStringAsFixed(1) ?? '',
    );
    final humidityController = TextEditingController(
      text: house.humidity?.toStringAsFixed(0) ?? '',
    );

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Update ${house.name}'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: tempController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Temperature (C)',
                  prefixIcon: Icon(Icons.thermostat_outlined),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: humidityController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Humidity (%)',
                  prefixIcon: Icon(Icons.water_drop_outlined),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final tempValue = double.tryParse(tempController.text.trim());
              final humidityValue = double.tryParse(
                humidityController.text.trim(),
              );
              await _houseService.updateClimate(
                houseId: house.id,
                currentTemperature: tempValue,
                currentHumidity: humidityValue,
              );
              if (dialogContext.mounted) {
                Navigator.pop(dialogContext);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfff8faf7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('Climate Control'),
      ),
      body: SafeArea(
        child: _houses.isEmpty
            ? const Center(
                child: Text(
                  'No houses cached. Add houses from the Houses module first.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xff66736c),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _houses.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  return _HouseClimateCard(
                    house: _houses[index],
                    canEdit: widget.canEdit,
                    onEdit: () => _showEditDialog(_houses[index]),
                  );
                },
              ),
      ),
    );
  }
}

class _HouseClimateCard extends StatelessWidget {
  const _HouseClimateCard({
    required this.house,
    required this.canEdit,
    required this.onEdit,
  });

  final _HouseClimateVm house;
  final bool canEdit;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final statusColor = climateStatusColor(house.status.status);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffe1e7e3)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x105c6b62),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  house.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0,
                  ),
                ),
              ),
              if (house.isIsolation)
                Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.25),
                    ),
                  ),
                  child: const Text(
                    'Isolation',
                    style: TextStyle(
                      color: Color(0xFFF59E0B),
                      fontWeight: FontWeight.w900,
                      fontSize: 10,
                    ),
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: statusColor.withValues(alpha: 0.25),
                  ),
                ),
                child: Text(
                  house.status.label,
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.w900,
                    fontSize: 10,
                  ),
                ),
              ),
              if (canEdit)
                IconButton(
                  tooltip: 'Edit readings',
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _ClimateTile(
                  icon: Icons.thermostat_outlined,
                  label: 'Temperature',
                  value: house.temperature == null
                      ? 'Not set'
                      : '${house.temperature!.toStringAsFixed(1)} C',
                  color: temperatureColor(house.temperature),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ClimateTile(
                  icon: Icons.water_drop_outlined,
                  label: 'Humidity',
                  value: house.humidity == null
                      ? 'Not set'
                      : '${house.humidity!.toStringAsFixed(0)}%',
                  color: humidityColor(house.humidity),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '${house.occupied} / ${house.capacity} birds',
            style: const TextStyle(
              color: Color(0xff66736c),
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _ClimateTile extends StatelessWidget {
  const _ClimateTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(height: 10),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xff66736c),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _HouseClimateVm {
  const _HouseClimateVm({
    required this.id,
    required this.name,
    required this.capacity,
    required this.occupied,
    required this.temperature,
    required this.humidity,
    required this.isIsolation,
    required this.status,
  });

  final String id;
  final String name;
  final int capacity;
  final int occupied;
  final double? temperature;
  final double? humidity;
  final bool isIsolation;
  final ClimateStatusResult status;
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value?.toString().trim().toLowerCase() ?? '';
  return text == 'true' || text == '1' || text == 'yes';
}

double? _nullableDouble(Object? value) {
  if (value == null) return null;
  if (value is double) return value;
  if (value is num) return value.toDouble();
  final parsed = double.tryParse(value.toString());
  return parsed;
}

String _text(Object? value, [String fallback = '']) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}
