import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shimmer/shimmer.dart';

import '../../core/models/app_user.dart';
import '../../features/management/data/invoice_pdf_service.dart';
import '../../features/management/data/management_models.dart';
import '../../features/management/data/management_repository.dart';
import '../../features/partners/partner_statement_screen.dart';
import '../../services/local_partner_service.dart';
import '../../services/missing_finance_setup_service.dart';
import '../profile/profile_screen.dart';
import '../settings/settings_hub_screen.dart';
import '../shared/session_mode_badge.dart';

class ManagementDashboard extends StatefulWidget {
  const ManagementDashboard({
    super.key,
    required this.currentUser,
    required this.connectionChanges,
    required this.isOnline,
    required this.repository,
    required this.onSignOut,
  });

  final AppUser currentUser;
  final Stream<bool> connectionChanges;
  final Future<bool> Function() isOnline;
  final ManagementDataSource repository;
  final Future<void> Function() onSignOut;

  @override
  State<ManagementDashboard> createState() => _ManagementDashboardState();
}

class _ManagementDashboardState extends State<ManagementDashboard> {
  late final ManagementPermissions _permissions;
  late Stream<ManagementSnapshot> _snapshotStream;
  late List<ManagementSection> _sections;
  late AppUser _activeUser;
  StreamSubscription<bool>? _connectionSubscription;
  bool _isOnline = true;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _activeUser = widget.currentUser;
    _permissions = ManagementPermissions.forRole(widget.currentUser.role);
    _sections = ManagementSection.values
        .where((section) => _permissions.canOpen(section))
        .toList(growable: false);
    _snapshotStream = widget.repository.watchSnapshot(_activeUser);
    widget.isOnline().then((online) {
      if (mounted) {
        setState(() => _isOnline = online);
      }
    });
    _connectionSubscription = widget.connectionChanges.listen((online) {
      if (mounted) {
        setState(() => _isOnline = online);
      }
    });
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _snapshotStream = widget.repository.watchSnapshot(_activeUser);
    });
  }

  void _switchFarm(FarmOption farm) {
    HapticFeedback.lightImpact();
    setState(() {
      _activeUser = _activeUser.copyWith(
        activeFarmId: farm.id,
        activeFarmName: farm.name,
      );
      _snapshotStream = widget.repository.watchSnapshot(_activeUser);
      _selectedIndex = 0;
    });
    Navigator.of(context).maybePop();
  }

  void _selectSection(ManagementSection section) {
    final index = _sections.indexOf(section);
    if (index < 0) {
      return;
    }
    HapticFeedback.lightImpact();
    setState(() => _selectedIndex = index);
    Navigator.of(context).maybePop();
  }

  Future<void> _signOut() async {
    HapticFeedback.lightImpact();
    await widget.onSignOut();
  }

  @override
  Widget build(BuildContext context) {
    final section = _sections[_selectedIndex];

    return StreamBuilder<ManagementSnapshot>(
      stream: _snapshotStream,
      builder: (context, snapshot) {
        final isLoading = snapshot.connectionState == ConnectionState.waiting;
        final data = snapshot.data;

        return Scaffold(
          backgroundColor: _MgmtColors.background,
          drawer: _ManagementDrawer(
            currentUser: _activeUser,
            permissions: _permissions,
            selected: section,
            farms: data?.farms ?? const [],
            onFarmSelected: _switchFarm,
            onSelected: _selectSection,
            onSignOut: _signOut,
          ),
          appBar: AppBar(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.white,
            title: Text('${widget.currentUser.role.label} Console'),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(52),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SessionModeBadge(
                    isOnline: _isOnline,
                    authenticatedOffline:
                        widget.currentUser.authenticatedOffline,
                  ),
                ),
              ),
            ),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: () {
                  HapticFeedback.lightImpact();
                  _refresh();
                },
                icon: const Icon(Icons.sync),
              ),
              IconButton(
                tooltip: 'Sign out',
                onPressed: _signOut,
                icon: const Icon(Icons.logout),
              ),
            ],
          ),
          body: SafeArea(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: isLoading || data == null
                  ? const _ManagementSkeleton()
                  : _sectionFor(section, data),
            ),
          ),
        );
      },
    );
  }

  Widget _sectionFor(ManagementSection section, ManagementSnapshot snapshot) {
    switch (section) {
      case ManagementSection.dashboard:
        return _OverviewSection(
          currentUser: widget.currentUser,
          permissions: _permissions,
          snapshot: snapshot,
          onOpen: _selectSection,
        );
      case ManagementSection.livestock:
        return _LivestockSection(snapshot: snapshot);
      case ManagementSection.houses:
        return _HubModuleSection(
          title: 'Houses Manager',
          subtitle:
              'Structural housing units, capacity, and environment state.',
          icon: Icons.home_work_outlined,
          records: snapshot.houseRecords,
          emptyLabel: 'No houses are cached locally yet.',
        );
      case ManagementSection.eggs:
        return _HubModuleSection(
          title: 'Egg Production Ledger',
          subtitle:
              'Daily collection, cracks, and grade state from local cache.',
          icon: Icons.egg_alt_outlined,
          records: snapshot.eggRecords,
          emptyLabel: 'No egg production rows are cached locally yet.',
        );
      case ManagementSection.feeding:
        return _HubModuleSection(
          title: 'Feeding Matrix',
          subtitle: 'Feed consumption and remaining sack counts.',
          icon: Icons.inventory_2_outlined,
          records: snapshot.feedingRecords,
          emptyLabel: 'No feeding rows are cached locally yet.',
        );
      case ManagementSection.health:
        return _HubModuleSection(
          title: 'Vaccination & Medication',
          subtitle: 'Scheduled vaccines, medications, and completion state.',
          icon: Icons.vaccines_outlined,
          records: snapshot.healthRecords,
          emptyLabel: 'No health schedules are cached locally yet.',
        );
      case ManagementSection.mortality:
        return _HubModuleSection(
          title: 'Mortality Register',
          subtitle: 'Bird deaths and loss trends only.',
          icon: Icons.warning_amber_rounded,
          records: snapshot.mortalityRecords,
          emptyLabel: 'No mortality rows are cached locally yet.',
          alert: true,
        );
      case ManagementSection.quarantine:
        return _HubModuleSection(
          title: 'Quarantine Register',
          subtitle: 'Sick bird isolation, diagnosis, treatments, and recovery.',
          icon: Icons.health_and_safety_outlined,
          records: snapshot.quarantineRecords,
          emptyLabel: 'No quarantine rows are cached locally yet.',
        );
      case ManagementSection.sales:
        return _InvoiceSection(
          currentUser: _activeUser,
          permissions: _permissions,
          repository: widget.repository,
          snapshot: snapshot,
          onSaved: _refresh,
        );
      case ManagementSection.inventory:
        return _HubModuleSection(
          title: 'Inventory Core',
          subtitle: 'Medication, vaccine, gear, feed, and raw supply stocks.',
          icon: Icons.warehouse_outlined,
          records: snapshot.inventoryRecords,
          emptyLabel: 'No inventory rows are cached locally yet.',
        );
      case ManagementSection.customers:
        return _StakeholderSection(
          snapshot: snapshot,
          currentUser: _activeUser,
          partnerService: widget.repository.partnerService,
        );
      case ManagementSection.financeControl:
        return _ExpenseLedgerSection(
          currentUser: _activeUser,
          permissions: _permissions,
          repository: widget.repository,
          snapshot: snapshot,
          onSaved: _refresh,
        );
      case ManagementSection.profile:
        return ProfileScreen(
          currentUser: _activeUser,
          localDatabase: widget.repository.localDatabase,
          onProfileUpdated: (user) => setState(() => _activeUser = user),
        );
      case ManagementSection.settings:
        return SettingsHubScreen(
          currentUser: _activeUser,
          localDatabase: widget.repository.localDatabase,
          onOpenProfile: () => _selectSection(ManagementSection.profile),
        );
    }
  }
}

class _ManagementDrawer extends StatelessWidget {
  const _ManagementDrawer({
    required this.currentUser,
    required this.permissions,
    required this.selected,
    required this.farms,
    required this.onFarmSelected,
    required this.onSelected,
    required this.onSignOut,
  });

  final AppUser currentUser;
  final ManagementPermissions permissions;
  final ManagementSection selected;
  final List<FarmOption> farms;
  final ValueChanged<FarmOption> onFarmSelected;
  final ValueChanged<ManagementSection> onSelected;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    const operations = [
      ManagementSection.dashboard,
      ManagementSection.livestock,
      ManagementSection.houses,
      ManagementSection.eggs,
      ManagementSection.feeding,
      ManagementSection.health,
      ManagementSection.mortality,
      ManagementSection.quarantine,
    ];
    const commercial = [
      ManagementSection.sales,
      ManagementSection.inventory,
      ManagementSection.customers,
      ManagementSection.financeControl,
    ];
    const governance = [ManagementSection.profile, ManagementSection.settings];

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              color: _MgmtColors.slate,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.business_center_outlined,
                    color: Colors.white,
                    size: 34,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    currentUser.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    currentUser.activeFarmId.isEmpty
                        ? 'No farm selected'
                        : currentUser.activeFarmName.trim().isNotEmpty
                        ? currentUser.activeFarmName
                        : 'Farm',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 10, bottom: 12),
                children: [
                  if (farms.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Farms',
                          style: TextStyle(
                            color: _MgmtColors.muted,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                    for (final farm in farms.take(5))
                      ListTile(
                        selected: farm.id == currentUser.activeFarmId,
                        leading: const Icon(Icons.agriculture_outlined),
                        title: Text(
                          farm.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: farm.location.isEmpty
                            ? null
                            : Text(farm.location),
                        onTap: () => onFarmSelected(farm),
                      ),
                    const Divider(),
                  ],
                  _DrawerTier(
                    label: 'Operations',
                    sections: operations,
                    permissions: permissions,
                    selected: selected,
                    onSelected: onSelected,
                  ),
                  _DrawerTier(
                    label: 'Commercial',
                    sections: commercial,
                    permissions: permissions,
                    selected: selected,
                    onSelected: onSelected,
                  ),
                  _DrawerTier(
                    label: 'Governance',
                    sections: governance,
                    permissions: permissions,
                    selected: selected,
                    onSelected: onSelected,
                  ),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.logout),
                    title: const Text('Sign out'),
                    onTap: onSignOut,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerTier extends StatelessWidget {
  const _DrawerTier({
    required this.label,
    required this.sections,
    required this.permissions,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final List<ManagementSection> sections;
  final ManagementPermissions permissions;
  final ManagementSection selected;
  final ValueChanged<ManagementSection> onSelected;

  @override
  Widget build(BuildContext context) {
    final visible = sections
        .where((section) => permissions.canOpen(section))
        .toList(growable: false);
    if (visible.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            label,
            style: const TextStyle(
              color: _MgmtColors.muted,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        for (final section in visible)
          ListTile(
            selected: section == selected,
            leading: Icon(_iconFor(section)),
            title: Text(_labelFor(section)),
            onTap: () => onSelected(section),
          ),
      ],
    );
  }
}

class _OverviewSection extends StatelessWidget {
  const _OverviewSection({
    required this.currentUser,
    required this.permissions,
    required this.snapshot,
    required this.onOpen,
  });

  final AppUser currentUser;
  final ManagementPermissions permissions;
  final ManagementSnapshot snapshot;
  final ValueChanged<ManagementSection> onOpen;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Enterprise Overview',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: _MgmtColors.ink,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          currentUser.role.hasUniversalAccess
              ? 'Global control center with finance, operations, and team access.'
              : 'Role-filtered workspace for fast daily management.',
          style: const TextStyle(
            color: _MgmtColors.muted,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 16),
        _KpiGrid(snapshot: snapshot),
        const SizedBox(height: 18),
        _SectionLauncherGrid(permissions: permissions, onOpen: onOpen),
      ],
    );
  }
}

class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.snapshot});

  final ManagementSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 650;
        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: compact ? 2 : 4,
          childAspectRatio: compact ? 1.35 : 1.65,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          children: [
            _KpiCard(
              label: 'Revenue',
              value: _money(snapshot.totalRevenue),
              icon: Icons.trending_up,
              color: _MgmtColors.emerald,
            ),
            _KpiCard(
              label: 'Expenses',
              value: _money(snapshot.totalExpenses),
              icon: Icons.trending_down,
              color: _MgmtColors.amber,
            ),
            _KpiCard(
              label: 'Net Profit',
              value: _money(snapshot.netProfit),
              icon: Icons.account_balance_wallet_outlined,
              color: snapshot.netProfit >= 0
                  ? _MgmtColors.emerald
                  : _MgmtColors.red,
            ),
            _KpiCard(
              label: 'Pending Sync',
              value: '${snapshot.pendingSyncCount}',
              icon: Icons.cloud_sync_outlined,
              color: _MgmtColors.slate,
            ),
          ],
        );
      },
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icon, color: color, size: 28),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: _MgmtColors.ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _MgmtColors.muted,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionLauncherGrid extends StatelessWidget {
  const _SectionLauncherGrid({required this.permissions, required this.onOpen});

  final ManagementPermissions permissions;
  final ValueChanged<ManagementSection> onOpen;

  @override
  Widget build(BuildContext context) {
    final sections = ManagementSection.values
        .where(
          (section) =>
              section != ManagementSection.dashboard &&
              section != ManagementSection.profile &&
              section != ManagementSection.settings,
        )
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Modules',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 10),
        for (final section in sections)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ModuleTile(
              section: section,
              enabled: permissions.canOpen(section),
              onTap: () => onOpen(section),
            ),
          ),
      ],
    );
  }
}

class _ModuleTile extends StatelessWidget {
  const _ModuleTile({
    required this.section,
    required this.enabled,
    required this.onTap,
  });

  final ManagementSection section;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.48,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: enabled
            ? () {
                HapticFeedback.lightImpact();
                onTap();
              }
            : null,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: _panelDecoration(),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: _MgmtColors.slate.withValues(alpha: 0.1),
                foregroundColor: _MgmtColors.slate,
                child: Icon(_iconFor(section)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _labelFor(section),
                      style: const TextStyle(
                        color: _MgmtColors.ink,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      enabled ? _descriptionFor(section) : 'Restricted by role',
                      style: const TextStyle(
                        color: _MgmtColors.muted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _LivestockSection extends StatelessWidget {
  const _LivestockSection({required this.snapshot});

  final ManagementSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final records = snapshot.batches.map((batch) {
      final analytics = snapshot.analytics
          .where((item) => item.batchId == batch.id)
          .firstOrNull;
      return HubModuleRecord(
        id: batch.id,
        title: batch.label,
        subtitle: analytics == null
            ? 'Current count ${batch.currentCount}'
            : '${analytics.initialCount} placed | ${analytics.mortalityCount} losses',
        metric: '${batch.currentCount} birds',
        status: 'ACTIVE',
      );
    }).toList();

    return _HubModuleSection(
      title: 'Livestock Engine',
      subtitle: 'Bird strains, ages, counts, and active batch state.',
      icon: Icons.groups_3_outlined,
      records: records,
      emptyLabel: 'No livestock batches are cached locally yet.',
    );
  }
}

class _HubModuleSection extends StatelessWidget {
  const _HubModuleSection({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.records,
    required this.emptyLabel,
    this.alert = false,
    this.onRecordTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final List<HubModuleRecord> records;
  final String emptyLabel;
  final bool alert;
  final ValueChanged<HubModuleRecord>? onRecordTap;

  @override
  Widget build(BuildContext context) {
    final color = alert ? _MgmtColors.red : _MgmtColors.emerald;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionHeader(title: title, subtitle: subtitle),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: _panelDecoration(),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: color.withValues(alpha: 0.12),
                foregroundColor: color,
                child: Icon(icon),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${records.length} cached records',
                  style: const TextStyle(
                    color: _MgmtColors.ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Icon(Icons.storage_outlined, color: color),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (records.isEmpty)
          Container(
            padding: const EdgeInsets.all(18),
            decoration: _panelDecoration(),
            child: Text(
              emptyLabel,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          )
        else
          for (final record in records)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _HubRecordTile(
                record: record,
                accentColor: color,
                onTap: onRecordTap == null ? null : () => onRecordTap!(record),
              ),
            ),
      ],
    );
  }
}

class _StakeholderSection extends StatelessWidget {
  const _StakeholderSection({
    required this.snapshot,
    required this.currentUser,
    required this.partnerService,
  });

  final ManagementSnapshot snapshot;
  final AppUser currentUser;
  final LocalPartnerService partnerService;

  void _openStatement(BuildContext context, HubModuleRecord record) {
    final kind = record.status == 'SUPPLIER'
        ? PartnerKind.supplier
        : PartnerKind.customer;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PartnerStatementScreen(
          currentUser: currentUser,
          partnerService: partnerService,
          partnerId: record.id,
          kind: kind,
          partnerName: record.title,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final records = [...snapshot.customerRecords, ...snapshot.supplierRecords];
    return _HubModuleSection(
      title: 'Stakeholder Directories',
      subtitle: 'Active customer and supplier profiles.',
      icon: Icons.contacts_outlined,
      records: records,
      emptyLabel: 'No customer or supplier profiles are cached locally yet.',
      onRecordTap: (record) {
        if (record.status == 'CUSTOMER' || record.status == 'SUPPLIER') {
          _openStatement(context, record);
        }
      },
    );
  }
}

class _HubRecordTile extends StatelessWidget {
  const _HubRecordTile({
    required this.record,
    required this.accentColor,
    this.onTap,
  });

  final HubModuleRecord record;
  final Color accentColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: _panelDecoration(),
          child: Row(
            children: [
          Container(
            width: 8,
            height: 52,
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  record.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _MgmtColors.ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  record.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _MgmtColors.muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          if (record.metric.isNotEmpty || record.status.isNotEmpty) ...[
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (record.metric.isNotEmpty)
                  Text(
                    record.metric,
                    style: const TextStyle(
                      color: _MgmtColors.ink,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                if (record.status.isNotEmpty)
                  Text(
                    record.status,
                    style: TextStyle(
                      color: accentColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
              ],
            ),
          ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ExpenseLedgerSection extends StatefulWidget {
  const _ExpenseLedgerSection({
    required this.currentUser,
    required this.permissions,
    required this.repository,
    required this.snapshot,
    required this.onSaved,
  });

  final AppUser currentUser;
  final ManagementPermissions permissions;
  final ManagementDataSource repository;
  final ManagementSnapshot snapshot;
  final VoidCallback onSaved;

  @override
  State<_ExpenseLedgerSection> createState() => _ExpenseLedgerSectionState();
}

class _ExpenseLedgerSectionState extends State<_ExpenseLedgerSection> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _descriptionController = TextEditingController();
  String _category = 'FEED';
  bool _splitAcrossBatches = false;
  bool _saving = false;
  late Map<String, double> _allocationPercents;

  @override
  void initState() {
    super.initState();
    _allocationPercents = _initialAllocations();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Map<String, double> _initialAllocations() {
    if (widget.snapshot.batches.isEmpty) {
      return {};
    }
    final share = 1 / widget.snapshot.batches.length;
    return {for (final batch in widget.snapshot.batches) batch.id: share};
  }

  Future<void> _saveExpense() async {
    if (!_formKey.currentState!.validate() || _saving) {
      return;
    }

    final allocations = _splitAcrossBatches
        ? widget.snapshot.batches
              .map(
                (batch) => ExpenseAllocation(
                  batchId: batch.id,
                  batchLabel: batch.label,
                  percent: _allocationPercents[batch.id] ?? 0,
                ),
              )
              .where((allocation) => allocation.percent > 0)
              .toList()
        : <ExpenseAllocation>[];
    final totalPercent = allocations.fold<double>(
      0,
      (sum, allocation) => sum + allocation.percent,
    );

    if (_splitAcrossBatches && (totalPercent - 1).abs() > 0.01) {
      _showSnack(context, 'Allocated percentages must add up to 100%.');
      return;
    }

    HapticFeedback.lightImpact();
    setState(() => _saving = true);
    await widget.repository.logExpense(
      user: widget.currentUser,
      draft: ExpenseDraft(
        amount: double.parse(_amountController.text),
        category: _category,
        description: _descriptionController.text.trim(),
        expenseDate: DateTime.now(),
        allocations: allocations,
      ),
    );

    if (!mounted) {
      return;
    }
    _amountController.clear();
    _descriptionController.clear();
    setState(() => _saving = false);
    widget.onSaved();
    _showSnack(context, 'Expense saved locally and queued for sync.');
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (widget.permissions.canEditFinance)
          FutureBuilder<List<MissingCostBatch>>(
            future: widget.repository.loadBatchesMissingCost(widget.currentUser),
            builder: (context, batchSnap) {
              if (!batchSnap.hasData || batchSnap.data!.isEmpty) {
                return FutureBuilder<List<MissingCostHealthItem>>(
                  future: widget.repository.loadHealthItemsMissingCost(
                    widget.currentUser,
                  ),
                  builder: (context, healthSnap) {
                    if (!healthSnap.hasData || healthSnap.data!.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    final item = healthSnap.data!.first;
                    return _MissingFinanceBanner(
                      title: 'Health stock missing cost',
                      detail:
                          '${item.itemName} needs a unit cost for accurate P&L.',
                    );
                  },
                );
              }
              final batch = batchSnap.data!.first;
              return _MissingFinanceBanner(
                title: 'Batch missing initial cost',
                detail:
                    '${batch.batchName} (${batch.initialCount} birds) needs purchase cost data.',
              );
            },
          ),
        _SectionHeader(
          title: 'Batch Costing Ledger',
          subtitle: widget.permissions.canEditFinance
              ? 'Log direct expenses and allocate bulk costs across batches.'
              : 'Finance editing is restricted for this role.',
        ),
        const SizedBox(height: 14),
        AbsorbPointer(
          absorbing: !widget.permissions.canEditFinance,
          child: Opacity(
            opacity: widget.permissions.canEditFinance ? 1 : 0.55,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: _panelDecoration(),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: _category,
                      decoration: const InputDecoration(
                        labelText: 'Expense Category',
                        prefixIcon: Icon(Icons.category_outlined),
                      ),
                      items:
                          const [
                                'FEED',
                                'MEDICATION',
                                'LIVESTOCK_PURCHASE',
                                'SALARY',
                                'UTILITIES',
                                'TRANSPORT',
                                'EQUIPMENT',
                                'MAINTENANCE',
                                'OTHER',
                              ]
                              .map(
                                (value) => DropdownMenuItem(
                                  value: value,
                                  child: Text(value),
                                ),
                              )
                              .toList(),
                      onChanged: (value) {
                        HapticFeedback.lightImpact();
                        setState(() => _category = value ?? _category);
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _amountController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Amount',
                        prefixText: 'GHS ',
                        prefixIcon: Icon(Icons.payments_outlined),
                      ),
                      validator: (value) {
                        final amount = double.tryParse(value ?? '');
                        if (amount == null || amount <= 0) {
                          return 'Enter a valid amount.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _descriptionController,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                        prefixIcon: Icon(Icons.description_outlined),
                      ),
                    ),
                    const SizedBox(height: 14),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Split across active batches',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                      subtitle: const Text(
                        'Allocate one bulk invoice into true batch costs.',
                      ),
                      value: _splitAcrossBatches,
                      onChanged: widget.snapshot.batches.isEmpty
                          ? null
                          : (value) {
                              HapticFeedback.lightImpact();
                              setState(() => _splitAcrossBatches = value);
                            },
                    ),
                    if (_splitAcrossBatches) ...[
                      const SizedBox(height: 8),
                      for (final batch in widget.snapshot.batches)
                        _AllocationSlider(
                          batch: batch,
                          value: _allocationPercents[batch.id] ?? 0,
                          onChanged: (value) {
                            HapticFeedback.lightImpact();
                            setState(() {
                              _allocationPercents[batch.id] = value;
                            });
                          },
                        ),
                      _AllocationTotal(
                        total: _allocationPercents.values.fold(
                          0,
                          (a, b) => a + b,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _saving ? null : _saveExpense,
                      icon: _saving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.save_outlined),
                      label: const Text('Save Ledger Entry'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AllocationSlider extends StatelessWidget {
  const _AllocationSlider({
    required this.batch,
    required this.value,
    required this.onChanged,
  });

  final BatchOption batch;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                batch.label,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            Text('${(value * 100).round()}%'),
          ],
        ),
        Slider(
          value: value,
          onChanged: onChanged,
          min: 0,
          max: 1,
          divisions: 20,
        ),
      ],
    );
  }
}

class _AllocationTotal extends StatelessWidget {
  const _AllocationTotal({required this.total});

  final double total;

  @override
  Widget build(BuildContext context) {
    final ok = (total - 1).abs() <= 0.01;
    return Text(
      'Allocated ${(total * 100).round()}%',
      style: TextStyle(
        color: ok ? _MgmtColors.emerald : _MgmtColors.red,
        fontWeight: FontWeight.w900,
      ),
    );
  }
}

class _InvoiceSection extends StatefulWidget {
  const _InvoiceSection({
    required this.currentUser,
    required this.permissions,
    required this.repository,
    required this.snapshot,
    required this.onSaved,
  });

  final AppUser currentUser;
  final ManagementPermissions permissions;
  final ManagementDataSource repository;
  final ManagementSnapshot snapshot;
  final VoidCallback onSaved;

  @override
  State<_InvoiceSection> createState() => _InvoiceSectionState();
}

class _InvoiceSectionState extends State<_InvoiceSection> {
  final _formKey = GlobalKey<FormState>();
  final _customerController = TextEditingController();
  final _quantityController = TextEditingController(text: '1');
  final _priceController = TextEditingController();
  final _receivedController = TextEditingController();
  final _discountController = TextEditingController(text: '0');
  final _pdfService = InvoicePdfService();

  String _customerType = 'Wholesale';
  String _item = 'Crates of Large Eggs';
  String _paymentMethod = 'Cash';
  bool _saving = false;

  @override
  void dispose() {
    _customerController.dispose();
    _quantityController.dispose();
    _priceController.dispose();
    _receivedController.dispose();
    _discountController.dispose();
    super.dispose();
  }

  Future<void> _createInvoice() async {
    if (!_formKey.currentState!.validate() || _saving) {
      return;
    }

    HapticFeedback.lightImpact();
    setState(() => _saving = true);

    final draft = InvoiceDraft(
      customerName: _customerController.text.trim(),
      customerType: _customerType,
      item: _item,
      quantity: int.parse(_quantityController.text),
      unitPrice: double.parse(_priceController.text),
      amountReceived: double.parse(_receivedController.text),
      discount: widget.permissions.canDiscount
          ? double.tryParse(_discountController.text) ?? 0
          : 0,
      taxRate: 0,
      paymentMethod: _paymentMethod,
    );
    final invoice = await widget.repository.createInvoice(
      user: widget.currentUser,
      draft: draft,
    );
    await _pdfService.shareInvoice(invoice);

    if (!mounted) {
      return;
    }
    setState(() => _saving = false);
    widget.onSaved();
    _showSnack(context, 'Invoice generated and queued for sync.');
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _SectionHeader(
          title: 'Sales Invoicing',
          subtitle: 'Issue paid receipts and share PDF invoices instantly.',
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: _panelDecoration(),
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                TextFormField(
                  controller: _customerController,
                  decoration: const InputDecoration(
                    labelText: 'Customer Name',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: _required,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _customerType,
                        decoration: const InputDecoration(
                          labelText: 'Customer Type',
                        ),
                        items: const ['Wholesale', 'Retail', 'Distributor']
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          HapticFeedback.lightImpact();
                          setState(
                            () => _customerType = value ?? _customerType,
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _paymentMethod,
                        decoration: const InputDecoration(labelText: 'Payment'),
                        items: const ['Cash', 'Mobile Money', 'Bank Transfer']
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          HapticFeedback.lightImpact();
                          setState(
                            () => _paymentMethod = value ?? _paymentMethod,
                          );
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _item,
                  decoration: const InputDecoration(
                    labelText: 'Item',
                    prefixIcon: Icon(Icons.inventory_2_outlined),
                  ),
                  items:
                      const [
                            'Crates of Large Eggs',
                            'Crates of Mixed Eggs',
                            'Broiler Live Weight',
                            'Spent Layers',
                          ]
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(value),
                            ),
                          )
                          .toList(),
                  onChanged: (value) {
                    HapticFeedback.lightImpact();
                    setState(() => _item = value ?? _item);
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _quantityController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Qty'),
                        validator: _positiveInt,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _priceController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Unit Price',
                          prefixText: 'GHS ',
                        ),
                        validator: _positiveMoney,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _receivedController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Received',
                          prefixText: 'GHS ',
                        ),
                        validator: _positiveMoney,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _discountController,
                        enabled: widget.permissions.canDiscount,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: widget.permissions.canDiscount
                              ? 'Discount'
                              : 'Discount locked',
                          prefixText: 'GHS ',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: widget.permissions.canIssueInvoices && !_saving
                      ? _createInvoice
                      : null,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Generate & Share Invoice'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TeamSection extends StatefulWidget {
  const _TeamSection({
    required this.currentUser,
    required this.permissions,
    required this.repository,
    required this.snapshot,
    required this.onSaved,
  });

  final AppUser currentUser;
  final ManagementPermissions permissions;
  final ManagementDataSource repository;
  final ManagementSnapshot snapshot;
  final VoidCallback onSaved;

  @override
  State<_TeamSection> createState() => _TeamSectionState();
}

class _TeamSectionState extends State<_TeamSection> {
  bool _saving = false;

  Future<void> _promote(TeamMemberRecord member, UserRole targetRole) async {
    if (!widget.permissions.canPromoteUsers || _saving) {
      return;
    }
    HapticFeedback.lightImpact();
    setState(() => _saving = true);
    try {
      await widget.repository.promoteTeamMember(
        owner: widget.currentUser,
        member: member,
        targetRole: targetRole,
      );

      if (!mounted) {
        return;
      }
      widget.onSaved();
      _showSnack(
        context,
        'Role update queued. Target sessions will be refreshed by Supabase RPC.',
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      _showSnack(context, 'Role update failed: $error');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.permissions.canManageTeam) {
      return const _RestrictedSection(
        title: 'Team Management',
        message:
            'Only owners and admins can promote users and change security roles.',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const _SectionHeader(
          title: 'Team Management',
          subtitle: 'Owner and admin role promotions with access refresh.',
        ),
        const SizedBox(height: 14),
        if (widget.snapshot.teamMembers.isEmpty)
          Container(
            padding: const EdgeInsets.all(18),
            decoration: _panelDecoration(),
            child: const Text(
              'No team members are cached locally yet.',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          )
        else
          for (final member in widget.snapshot.teamMembers)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: _panelDecoration(),
                child: Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: _MgmtColors.slate.withValues(
                        alpha: 0.12,
                      ),
                      foregroundColor: _MgmtColors.slate,
                      child: const Icon(Icons.person_outline),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            member.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _MgmtColors.ink,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            member.phone.isEmpty
                                ? member.role.label
                                : member.phone,
                            style: const TextStyle(
                              color: _MgmtColors.muted,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    DropdownButton<UserRole>(
                      value: member.role == UserRole.unknown
                          ? UserRole.worker
                          : member.role,
                      items:
                          const [
                                UserRole.worker,
                                UserRole.cashier,
                                UserRole.manager,
                                UserRole.accountant,
                                UserRole.financeOfficer,
                              ]
                              .map(
                                (role) => DropdownMenuItem(
                                  value: role,
                                  child: Text(role.label),
                                ),
                              )
                              .toList(),
                      onChanged: widget.permissions.canPromoteUsers
                          ? (role) {
                              if (role != null) {
                                _promote(member, role);
                              }
                            }
                          : null,
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

class _RestrictedSection extends StatelessWidget {
  const _RestrictedSection({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _MgmtColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
            color: _MgmtColors.ink,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(
            color: _MgmtColors.muted,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _ManagementSkeleton extends StatelessWidget {
  const _ManagementSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: const Color(0xffe9edf0),
      highlightColor: Colors.white,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(height: 28, width: 220, color: Colors.white),
          const SizedBox(height: 16),
          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            childAspectRatio: 1.35,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            children: [
              for (var i = 0; i < 4; i++)
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Container(height: 180, color: Colors.white),
        ],
      ),
    );
  }
}

String? _required(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Required.';
  }
  return null;
}

String? _positiveMoney(String? value) {
  final parsed = double.tryParse(value ?? '');
  if (parsed == null || parsed <= 0) {
    return 'Enter amount.';
  }
  return null;
}

String? _positiveInt(String? value) {
  final parsed = int.tryParse(value ?? '');
  if (parsed == null || parsed <= 0) {
    return 'Enter quantity.';
  }
  return null;
}

void _showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
  );
}

BoxDecoration _panelDecoration() {
  return BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(8),
    border: Border.all(color: const Color(0xffe4e9ed)),
    boxShadow: const [
      BoxShadow(
        color: Color(0x14546570),
        blurRadius: 22,
        offset: Offset(0, 12),
      ),
    ],
  );
}

IconData _iconFor(ManagementSection section) {
  switch (section) {
    case ManagementSection.dashboard:
      return Icons.dashboard_outlined;
    case ManagementSection.livestock:
      return Icons.groups_3_outlined;
    case ManagementSection.houses:
      return Icons.home_work_outlined;
    case ManagementSection.eggs:
      return Icons.egg_alt_outlined;
    case ManagementSection.feeding:
      return Icons.inventory_2_outlined;
    case ManagementSection.health:
      return Icons.vaccines_outlined;
    case ManagementSection.mortality:
      return Icons.warning_amber_rounded;
    case ManagementSection.quarantine:
      return Icons.health_and_safety_outlined;
    case ManagementSection.sales:
      return Icons.receipt_long_outlined;
    case ManagementSection.inventory:
      return Icons.warehouse_outlined;
    case ManagementSection.customers:
      return Icons.contacts_outlined;
    case ManagementSection.financeControl:
      return Icons.account_balance_wallet_outlined;
    case ManagementSection.profile:
      return Icons.person_outline;
    case ManagementSection.settings:
      return Icons.settings_outlined;
  }
}

String _labelFor(ManagementSection section) {
  switch (section) {
    case ManagementSection.dashboard:
      return 'Dashboard';
    case ManagementSection.livestock:
      return 'Livestock';
    case ManagementSection.houses:
      return 'Houses';
    case ManagementSection.eggs:
      return 'Eggs';
    case ManagementSection.feeding:
      return 'Feeding';
    case ManagementSection.health:
      return 'Health';
    case ManagementSection.mortality:
      return 'Mortality';
    case ManagementSection.quarantine:
      return 'Quarantine';
    case ManagementSection.sales:
      return 'Sales';
    case ManagementSection.inventory:
      return 'Inventory';
    case ManagementSection.customers:
      return 'Customers';
    case ManagementSection.financeControl:
      return 'Finance Control';
    case ManagementSection.profile:
      return 'Profile';
    case ManagementSection.settings:
      return 'Settings';
  }
}

String _descriptionFor(ManagementSection section) {
  switch (section) {
    case ManagementSection.dashboard:
      return 'Executive summary';
    case ManagementSection.livestock:
      return 'Bird strains and batch counts';
    case ManagementSection.houses:
      return 'House capacity and environment';
    case ManagementSection.eggs:
      return 'Collection and grading ledger';
    case ManagementSection.feeding:
      return 'Feed usage and sack counts';
    case ManagementSection.health:
      return 'Vaccination and medication schedules';
    case ManagementSection.mortality:
      return 'Bird deaths only';
    case ManagementSection.quarantine:
      return 'Sick isolation and recovery';
    case ManagementSection.sales:
      return 'Receipts and farm-gate sales';
    case ManagementSection.inventory:
      return 'Stock, supplies, and gear';
    case ManagementSection.customers:
      return 'Customers and suppliers';
    case ManagementSection.financeControl:
      return 'Deposits, credits, and expenses';
    case ManagementSection.profile:
      return 'User and farm context';
    case ManagementSection.settings:
      return 'Governance controls';
  }
}

String _money(double value) => 'GHS ${value.toStringAsFixed(2)}';

class _MissingFinanceBanner extends StatelessWidget {
  const _MissingFinanceBanner({
    required this.title,
    required this.detail,
  });

  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xfffff7ed),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xfff59e0b)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xfff59e0b)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: const TextStyle(
                    color: Color(0xff667085),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MgmtColors {
  static const background = Color(0xfff7f9fb);
  static const slate = Color(0xff27364a);
  static const ink = Color(0xff172130);
  static const muted = Color(0xff667085);
  static const emerald = Color(0xff16845c);
  static const amber = Color(0xffd99025);
  static const red = Color(0xffc2413d);
}
