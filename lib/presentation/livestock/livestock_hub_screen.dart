import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_user.dart';
import '../../core/permissions/farm_permissions.dart';
import '../../core/storage/local_database.dart';
import '../../features/auth/data/supabase_remote_api.dart';
import '../../features/livestock/data/livestock_models.dart';
import '../../features/livestock/data/livestock_repository.dart';
import '../../features/livestock/services/livestock_service.dart';
import '../../services/missing_finance_setup_service.dart';
import '../../features/sync/data/worker_input_sink.dart';
import '../../services/local_sales_queue.dart';
import '../../services/pdf_invoice_service.dart';
import '../analytics/batch_compare_screen.dart';
import 'financial_setup_sheet.dart';
import 'livestock_detail_screen.dart';
import 'register_livestock_sheet.dart';
import 'widgets/livestock_batch_card.dart';
import 'widgets/livestock_filter_chips.dart';

class LivestockHubScreen extends StatefulWidget {
  const LivestockHubScreen({
    super.key,
    required this.currentUser,
    required this.permissions,
    required this.localDatabase,
    this.remoteApi,
    this.onRefreshFromCloud,
    this.inputSink,
    this.localSalesQueue,
    this.pdfInvoiceService,
  });

  final AppUser currentUser;
  final FarmPermissions permissions;
  final LocalDatabase localDatabase;
  final SupabaseRemoteApi? remoteApi;
  final Future<void> Function()? onRefreshFromCloud;
  final WorkerInputSink? inputSink;
  final LocalSalesQueue? localSalesQueue;
  final PdfInvoiceService? pdfInvoiceService;

  @override
  State<LivestockHubScreen> createState() => _LivestockHubScreenState();
}

class _LivestockHubScreenState extends State<LivestockHubScreen> {
  late final LivestockService _service;
  late final MissingFinanceSetupService _missingFinanceService;
  var _filter = LivestockSpeciesFilter.all;
  List<LivestockBatchRecord> _batches = const [];
  List<HouseOption> _houses = const [];
  var _loading = true;
  var _missingCostCount = 0;

  bool get _canEdit => widget.permissions.canEditBatches;

  @override
  void initState() {
    super.initState();
    _service = LivestockService(
      repository: LivestockRepository(widget.localDatabase),
      remoteApi: widget.remoteApi,
    );
    _missingFinanceService = MissingFinanceSetupService(widget.localDatabase);
    _reload();
    _service.watchBatches(widget.currentUser.activeFarmId).listen((_) {
      if (mounted) {
        _reload(silent: true);
      }
    });
  }

  Future<void> _reload({bool silent = false}) async {
    if (!silent) {
      setState(() => _loading = true);
    }
    try {
      final farmId = widget.currentUser.activeFarmId;
      final batches = await _service.loadBatches(farmId);
      final houses = await _service.loadHouses(farmId);
      final missing =
          await _missingFinanceService.loadBatchesMissingCost(farmId);
      if (!mounted) {
        return;
      }
      setState(() {
        _batches = batches;
        _houses = houses;
        _missingCostCount = missing.length;
      });
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load livestock: $error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  List<LivestockBatchRecord> get _filteredBatches {
    return _batches
        .where((batch) => _filter.matchesBatchType(batch.type))
        .toList(growable: false);
  }

  int get _totalBirds => _filteredBatches.fold<int>(
        0,
        (sum, batch) => sum + batch.currentCount,
      );

  Future<void> _openRegister() async {
    if (!_canEdit) {
      return;
    }
    HapticFeedback.lightImpact();
    final result = await showModalBottomSheet<LivestockOperationResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => RegisterLivestockSheet(
        service: _service,
        currentUser: widget.currentUser,
        houses: _houses,
        onSubmit: (draft) => _service.createBatch(
          user: widget.currentUser,
          draft: draft,
        ),
        onHouseCreated: () => widget.onRefreshFromCloud?.call() ?? Future.value(),
      ),
    );
    if (!mounted || result == null || !result.success) {
      return;
    }
    await widget.onRefreshFromCloud?.call();
    await _reload();
    if (result.batchId != null && widget.permissions.canEditFinance) {
      LivestockBatchRecord? created;
      for (final batch in _batches) {
        if (batch.id == result.batchId) {
          created = batch;
          break;
        }
      }
      if (created != null) {
        await _openFinancialSetup(
          batchId: created.id,
          batchName: created.batchName,
          quantity: created.initialCount,
        );
      }
    }
    if (result.error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.error!)),
      );
    }
  }

  Future<void> _openFinancialSetup({
    required String batchId,
    required String batchName,
    required int quantity,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FinancialSetupSheet(
        batchName: batchName,
        quantity: quantity,
        onSubmit: (draft) => _service.saveFinancials(
          user: widget.currentUser,
          batchId: batchId,
          draft: draft,
          quantity: quantity,
        ),
      ),
    );
    await _reload(silent: true);
  }

  Future<void> _openDetail(LivestockBatchRecord batch) async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => LivestockDetailScreen(
          currentUser: widget.currentUser,
          permissions: widget.permissions,
          localDatabase: widget.localDatabase,
          remoteApi: widget.remoteApi,
          batchId: batch.id,
          inputSink: widget.inputSink,
          localSalesQueue: widget.localSalesQueue,
          pdfInvoiceService: widget.pdfInvoiceService,
        ),
      ),
    );
    await _reload(silent: true);
  }

  Future<void> _openBatchCompare() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => BatchCompareScreen(
          currentUser: widget.currentUser,
          localDatabase: widget.localDatabase,
          permissions: widget.permissions,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfff8faf7),
      body: RefreshIndicator(
        onRefresh: () async {
          final refresh = widget.onRefreshFromCloud;
          if (refresh != null) {
            await refresh();
          }
          await _reload();
        },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Livestock',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(fontWeight: FontWeight.w900),
                              ),
                              Text(
                                '$_totalBirds active birds across ${_filteredBatches.length} units',
                                style: const TextStyle(
                                  color: Color(0xff66736c),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Compare batches',
                          onPressed: _openBatchCompare,
                          icon: const Icon(Icons.analytics_outlined),
                        ),
                      ],
                    ),
                    if (_missingCostCount > 0 && widget.permissions.canEditFinance)
                      Card(
                        color: const Color(0xff7a3f2f).withValues(alpha: 0.08),
                        child: ListTile(
                          leading: const Icon(Icons.warning_amber_outlined),
                          title: Text(
                            '$_missingCostCount unit(s) missing purchase cost',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          subtitle: const Text(
                            'Open a unit and complete financial setup for accurate profit reporting.',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: LivestockFilterChips(
                selected: _filter,
                onSelected: (value) => setState(() => _filter = value),
              ),
            ),
            if (_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_filteredBatches.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No livestock units yet. Register your first batch to begin tracking.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.grey,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => LivestockBatchCard(
                    batch: _filteredBatches[index],
                    onTap: () => _openDetail(_filteredBatches[index]),
                  ),
                  childCount: _filteredBatches.length,
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
      floatingActionButton: _canEdit
          ? FloatingActionButton.extended(
              onPressed: _openRegister,
              icon: const Icon(Icons.add),
              label: const Text('Register unit'),
            )
          : null,
    );
  }
}
