import 'package:flutter/material.dart';

import '../../services/dashboard_stats_service.dart';
import 'dashboard_formatters.dart';
import 'dashboard_shared_widgets.dart';

class AccountantDashboardView extends StatelessWidget {
  const AccountantDashboardView({
    super.key,
    required this.displayName,
    required this.activeFarmLabel,
    required this.permissionsLoading,
    required this.stats,
    this.permissionError,
    this.currency = 'GHS',
  });

  final String displayName;
  final String activeFarmLabel;
  final bool permissionsLoading;
  final Object? permissionError;
  final DashboardStatsSnapshot stats;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final summary = stats.monthlySummary;
    final revenue = summary?.revenue ?? 0;
    final expenses = summary?.expenses ?? 0;
    final net = revenue - expenses;
    final receivables = stats.customerReceivables;
    final weeklyBurn = stats.weeklyOperationalBurn;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashboardWelcomeBanner(
            displayName: displayName,
            activeFarmLabel: activeFarmLabel,
          ),
          DashboardPermissionBanner(
            isLoading: permissionsLoading,
            error: permissionError,
          ),
          const SizedBox(height: 18),
          const DashboardSectionHeader(
            title: 'Financial Terminal',
            subtitle: 'Real-time fiscal monitoring',
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Cash Flow Analysis',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Net Position',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  Text(
                    formatDashboardMoney(net, currency: currency),
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _FinanceRow(
                    label: 'Revenue (30d)',
                    value: formatDashboardMoney(revenue, currency: currency),
                    color: const Color(0xff1f7a4d),
                  ),
                  const SizedBox(height: 8),
                  _FinanceRow(
                    label: 'Expenses (30d)',
                    value: formatDashboardMoney(expenses, currency: currency),
                    color: const Color(0xffb83b3b),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.08,
            children: [
              DashboardKpiCard(
                icon: Icons.credit_card_outlined,
                color: const Color(0xff2563eb),
                metric: formatDashboardMoney(receivables, currency: currency),
                label: 'Account Receivables',
              ),
              DashboardKpiCard(
                icon: Icons.local_fire_department_outlined,
                color: const Color(0xff6a4c93),
                metric: formatDashboardMoney(weeklyBurn, currency: currency),
                label: 'Operations Burn / week',
              ),
              DashboardKpiCard(
                icon: Icons.point_of_sale_outlined,
                color: const Color(0xff16845c),
                metric: formatDashboardMoney(revenue, currency: currency),
                label: '30d Revenue',
              ),
              DashboardKpiCard(
                icon: Icons.egg_alt_outlined,
                color: const Color(0xffc7851f),
                metric: '${summary?.eggs ?? 0}',
                label: '30d Eggs Produced',
              ),
            ],
          ),
          const SizedBox(height: 18),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Audit Trail - Financials',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (stats.recentFinancialEvents.isEmpty)
                    const Text('No recent financial events.')
                  else
                    for (final event in stats.recentFinancialEvents)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          event.type == 'ORDER'
                              ? Icons.receipt_long_outlined
                              : Icons.payments_outlined,
                          color: const Color(0xff1f7a4d),
                        ),
                        title: Text(
                          '${event.type == 'ORDER' ? 'Order' : 'Sale'} - ${event.customerName}',
                        ),
                        subtitle: Text(
                          '${event.date.toLocal().toString().split(' ').first} • ${event.status ?? 'Verified'}',
                        ),
                        trailing: Text(
                          '+ ${formatDashboardMoney(event.totalAmount, currency: currency)}',
                          style: const TextStyle(
                            color: Color(0xff1f7a4d),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FinanceRow extends StatelessWidget {
  const _FinanceRow({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }
}
