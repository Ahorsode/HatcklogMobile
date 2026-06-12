import 'package:flutter/material.dart';

import '../../core/models/app_user.dart';

class OwnerDashboard extends StatelessWidget {
  const OwnerDashboard({
    super.key,
    required this.currentUser,
    required this.onSignOut,
  });

  final AppUser currentUser;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Owner Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: onSignOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Welcome, ${currentUser.displayName}',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          _MetricPanel(
            title: 'Net Income',
            value: 'Cloud sync required',
            icon: Icons.account_balance_wallet_outlined,
            color: colorScheme.primary,
          ),
          const SizedBox(height: 12),
          _MetricPanel(
            title: 'Sales Performance',
            value: 'Review farm revenue trends',
            icon: Icons.trending_up_outlined,
            color: colorScheme.secondary,
          ),
          const SizedBox(height: 12),
          _MetricPanel(
            title: 'Team Configuration',
            value: 'Roles, permissions, and device access',
            icon: Icons.admin_panel_settings_outlined,
            color: const Color(0xff46516a),
          ),
        ],
      ),
    );
  }
}

class _MetricPanel extends StatelessWidget {
  const _MetricPanel({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: ListTile(
        minVerticalPadding: 18,
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.14),
          foregroundColor: color,
          child: Icon(icon),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(value),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}
