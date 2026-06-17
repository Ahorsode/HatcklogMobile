import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/app_user.dart';
import '../../core/storage/local_database.dart';

class ClimateControlScreen extends StatefulWidget {
  const ClimateControlScreen({
    super.key,
    required this.currentUser,
    required this.localDatabase,
  });

  final AppUser currentUser;
  final LocalDatabase localDatabase;

  @override
  State<ClimateControlScreen> createState() => _ClimateControlScreenState();
}

class _ClimateControlScreenState extends State<ClimateControlScreen> {
  StreamSubscription<void>? _subscription;
  List<_HouseClimateVm> _houses = const [];

  @override
  void initState() {
    super.initState();
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
               h.environmental_state,
               coalesce(sum(case when b.is_deleted = 0 then b.current_count else 0 end), 0) as occupied
        from houses h
        left join batches b on b.house_id = h.id
        where h.farm_id = ?
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
              (row) => _HouseClimateVm(
                name: _text(row['name'], 'House'),
                capacity: _asInt(row['capacity']),
                occupied: _asInt(row['occupied']),
                temperature: _asDouble(row['current_temperature']),
                humidity: _asDouble(row['current_humidity']),
                state: _text(row['environmental_state']),
              ),
            )
            .toList(growable: false);
      });
    } on StateError {
      if (mounted) {
        setState(() => _houses = const []);
      }
    }
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
                  'No houses cached.',
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
                  return _HouseClimateCard(house: _houses[index]);
                },
              ),
      ),
    );
  }
}

class _HouseClimateCard extends StatelessWidget {
  const _HouseClimateCard({required this.house});

  final _HouseClimateVm house;

  @override
  Widget build(BuildContext context) {
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
              if (house.state.isNotEmpty)
                Chip(
                  label: Text(house.state),
                  visualDensity: VisualDensity.compact,
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
                  value: '${house.temperature.toStringAsFixed(1)} C',
                  color: const Color(0xffd99025),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _ClimateTile(
                  icon: Icons.water_drop_outlined,
                  label: 'Humidity',
                  value: '${house.humidity.toStringAsFixed(1)}%',
                  color: const Color(0xff2f5f8f),
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
    required this.name,
    required this.capacity,
    required this.occupied,
    required this.temperature,
    required this.humidity,
    required this.state,
  });

  final String name;
  final int capacity;
  final int occupied;
  final double temperature;
  final double humidity;
  final String state;
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _asDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

String _text(Object? value, [String fallback = '']) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}
