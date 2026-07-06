import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/models/app_user.dart';
import '../../services/local_partner_service.dart';

class PartnerStatementScreen extends StatefulWidget {
  const PartnerStatementScreen({
    super.key,
    required this.currentUser,
    required this.partnerService,
    required this.partnerId,
    required this.kind,
    required this.partnerName,
  });

  final AppUser currentUser;
  final LocalPartnerService partnerService;
  final String partnerId;
  final PartnerKind kind;
  final String partnerName;

  @override
  State<PartnerStatementScreen> createState() => _PartnerStatementScreenState();
}

class _PartnerStatementScreenState extends State<PartnerStatementScreen> {
  late Future<PartnerStatement> _statementFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _statementFuture = widget.kind == PartnerKind.supplier
        ? widget.partnerService.loadSupplierStatement(
            farmId: widget.currentUser.activeFarmId,
            supplierId: widget.partnerId,
          )
        : widget.partnerService.loadCustomerStatement(
            farmId: widget.currentUser.activeFarmId,
            customerId: widget.partnerId,
          );
  }

  Future<void> _showSettleDialog(PartnerStatement statement) async {
    if (statement.outstanding <= 0) {
      return;
    }

    final controller = TextEditingController();
    final currency = NumberFormat.currency(symbol: 'GHS ', decimalDigits: 2);
    final isSupplier = widget.kind == PartnerKind.supplier;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isSupplier ? 'Settle Payable' : 'Collect Receivable'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.partnerName, style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(
              'Outstanding: ${currency.format(statement.outstanding)}',
              style: const TextStyle(color: Color(0xffc2413d), fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
              ],
              decoration: InputDecoration(
                labelText: isSupplier ? 'Payment amount' : 'Collection amount',
                prefixText: 'GHS ',
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () =>
                    controller.text = statement.outstanding.toStringAsFixed(2),
                child: Text(isSupplier ? 'Pay full amount' : 'Collect full amount'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(isSupplier ? 'Record payment' : 'Record collection'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    final amount = double.tryParse(controller.text.trim()) ?? 0;
    try {
      if (isSupplier) {
        await widget.partnerService.recordSupplierPayment(
          farmId: widget.currentUser.activeFarmId,
          userId: widget.currentUser.id,
          supplierId: widget.partnerId,
          amount: amount,
        );
      } else {
        await widget.partnerService.recordCustomerCollection(
          farmId: widget.currentUser.activeFarmId,
          userId: widget.currentUser.id,
          customerId: widget.partnerId,
          amount: amount,
        );
      }
      if (!mounted) {
        return;
      }
      setState(_reload);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isSupplier
                ? 'Payment of ${currency.format(amount)} recorded.'
                : 'Collection of ${currency.format(amount)} recorded.',
          ),
        ),
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: 'GHS ', decimalDigits: 2);
    final accent = widget.kind == PartnerKind.supplier
        ? const Color(0xff5c6f2f)
        : const Color(0xff4d6475);

    return Scaffold(
      backgroundColor: const Color(0xfff7f9fb),
      appBar: AppBar(
        title: Text('${widget.partnerName} Statement'),
        backgroundColor: accent,
        foregroundColor: Colors.white,
      ),
      floatingActionButton: FutureBuilder<PartnerStatement>(
        future: _statementFuture,
        builder: (context, snapshot) {
          final outstanding = snapshot.data?.outstanding ?? 0;
          if (outstanding <= 0) {
            return const SizedBox.shrink();
          }
          return FloatingActionButton.extended(
            backgroundColor: const Color(0xffc2413d),
            foregroundColor: Colors.white,
            onPressed: snapshot.hasData
                ? () => _showSettleDialog(snapshot.data!)
                : null,
            icon: const Icon(Icons.payments_outlined),
            label: Text(
              widget.kind == PartnerKind.supplier
                  ? 'Settle payable'
                  : 'Collect receivable',
            ),
          );
        },
      ),
      body: FutureBuilder<PartnerStatement>(
        future: _statementFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return Center(
              child: Text(
                snapshot.error?.toString() ?? 'Unable to load statement.',
              ),
            );
          }

          final data = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _SummaryTile(
                    label: widget.kind == PartnerKind.supplier
                        ? 'Total purchased'
                        : 'Total billed',
                    value: currency.format(data.totalActivity),
                  ),
                  _SummaryTile(
                    label: widget.kind == PartnerKind.supplier
                        ? 'Total paid'
                        : 'Total collected',
                    value: currency.format(data.totalSettled),
                  ),
                  _SummaryTile(
                    label: 'Outstanding',
                    value: currency.format(data.outstanding),
                    accent: data.outstanding > 0
                        ? const Color(0xffc2413d)
                        : const Color(0xff16845c),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                'Transaction history',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 12),
              if (data.lines.isEmpty)
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xffe4e9ed)),
                  ),
                  child: const Text('No transactions recorded yet.'),
                )
              else
                ...data.lines.map(
                  (line) => Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      title: Text(
                        line.title,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      subtitle: Text(
                        '${line.kind} · ${DateFormat.yMMMd().format(line.date)}\n${line.subtitle}',
                      ),
                      trailing: Text(
                        currency.format(line.amount),
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
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

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({
    required this.label,
    required this.value,
    this.accent,
  });

  final String label;
  final String value;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xffe4e9ed)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: Color(0xff667085),
              fontSize: 11,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: accent ?? const Color(0xff172130),
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}
