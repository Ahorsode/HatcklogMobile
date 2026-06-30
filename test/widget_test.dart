import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/core/license/license_service.dart';
import 'package:hatchlog_m/core/license/license_status.dart';
import 'package:hatchlog_m/core/models/app_user.dart';
import 'package:hatchlog_m/core/models/worker_input_type.dart';
import 'package:hatchlog_m/core/permissions/farm_permissions.dart';
import 'package:hatchlog_m/features/auth/data/auth_repository.dart';
import 'package:hatchlog_m/features/auth/data/supabase_remote_api.dart';
import 'package:hatchlog_m/features/management/data/management_models.dart';
import 'package:hatchlog_m/features/management/data/management_repository.dart';
import 'package:hatchlog_m/features/role_gateway/presentation/role_gateway.dart';
import 'package:hatchlog_m/features/sync/data/worker_input_sink.dart';
import 'package:hatchlog_m/presentation/analytics/analytics_models.dart';
import 'package:hatchlog_m/core/storage/local_database.dart';
import 'package:hatchlog_m/services/encryption_service.dart';
import 'package:hatchlog_m/features/sales/sale_line_draft.dart';
import 'package:hatchlog_m/services/local_sales_queue.dart';

void main() {
  test('phone identifiers are masked as internal email auth identities', () {
    expect(
      SupabaseRemoteApi.internalEmailForPhoneIdentifier('+233 55-410.1675 '),
      '233554101675@hatchlog.internal',
    );
    expect(
      SupabaseRemoteApi.internalEmailForPhoneIdentifier('(055) 410-1675'),
      '0554101675@hatchlog.internal',
    );
  });

  test('login phone normalization strips punctuation-only input', () {
    expect(AuthRepository.normalizePhoneNumber(' +++ '), isEmpty);
    expect(
      AuthRepository.normalizePhoneNumber('055 410 1675'),
      '+233554101675',
    );
  });

  test(
    'hard locked license mode blocks even after a fresh cloud check',
    () async {
      final now = DateTime.now();
      final licenseService = LicenseService(
        _FakeLicenseDatabase({
          'id': 'singleton',
          'mode': 'HARD_LOCKED',
          'farm_id': 'farm-1',
          'user_id': 'user-1',
          'hardware_id': 'device-1',
          'installed_at': now
              .subtract(const Duration(days: 40))
              .toIso8601String(),
          'expires_at': now
              .subtract(const Duration(days: 36))
              .toIso8601String(),
          'last_used': now.toIso8601String(),
          'last_cloud_check_at': now.toIso8601String(),
        }),
      );

      expect(await licenseService.checkLicense(), LicenseStatus.hardLocked);
    },
  );

  test(
    'local sales queue rejects invalid quantities before storage writes',
    () {
      final queue = LocalSalesQueue(
        localDatabase: LocalDatabase(),
        encryptionService: EncryptionService(),
        deviceId: 'device-test',
      );

      expect(
        () => queue.enqueueSale(
          userId: 'user-1',
          farmId: 'farm-1',
          quantityCrates: 0,
          amountReceived: 20,
          unit: 'CRATE',
        ),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test(
    'multi-line sales queue rejects mismatched locked totals',
    () {
      final queue = LocalSalesQueue(
        localDatabase: LocalDatabase(),
        encryptionService: EncryptionService(),
        deviceId: 'device-test',
      );

      expect(
        () => queue.enqueueMultiLineSale(
          userId: 'user-1',
          farmId: 'farm-1',
          orderDate: DateTime.utc(2026, 6, 27),
          totalCashReceived: 50,
          requireExactCashTotal: true,
          items: const [
            SaleLineDraft(
              productType: SaleProductType.inventory,
              description: 'Layer Mash',
              quantity: 2,
              unitPrice: 30,
              inventoryId: 'inv-1',
            ),
          ],
        ),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test('owner and admin role aliases retain universal access', () {
    expect(UserRole.fromString('OWNER'), UserRole.owner);
    expect(UserRole.fromString('farm_owner'), UserRole.owner);
    expect(UserRole.fromString('owners'), UserRole.owner);
    expect(UserRole.fromString('Farm Owner'), UserRole.owner);
    expect(UserRole.fromString('administrator'), UserRole.admin);
    expect(UserRole.fromString('super_admin'), UserRole.admin);
    expect(UserRole.fromString('system_admin'), UserRole.admin);
    expect(UserRole.fromString('farm admins'), UserRole.admin);
    expect(UserRole.owner.hasUniversalAccess, isTrue);
    expect(UserRole.admin.hasUniversalAccess, isTrue);
    expect(UserRole.owner.hasMobileDashboardAccess, isTrue);
    expect(UserRole.admin.hasMobileDashboardAccess, isTrue);
  });

  for (final role in const [UserRole.owner, UserRole.manager, UserRole.admin]) {
    testWidgets('$role receives privileged RBAC module access', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: RoleGateway(
            currentUser: _user(role: role),
            permissions: FarmPermissions.fullAccess(),
            connectionChanges: Stream<bool>.value(true),
            isOnline: () async => true,
            inputSink: _NoopInputSink(),
            managementRepository: _FakeManagementDataSource(),
            localDatabase: LocalDatabase(),
            onSignOut: () async {},
          ),
        ),
      );

      await tester.pump();

      expect(find.text('Livestock'), findsWidgets);
      expect(find.text('Operational Pulse'), findsOneWidget);
      expect(find.text('Access Denied'), findsNothing);

      await tester.tap(find.text('Livestock').last);
      await tester.pumpAndSettle();

      expect(find.text('Total Birds'), findsOneWidget);
      expect(find.text('Add Livestock'), findsOneWidget);

      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();

      for (final label in const [
        'Livestock',
        'Houses',
        'Eggs',
        'Feeding',
        'Mortality',
      ]) {
        if (find.text(label).evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            find.text(label),
            160,
            scrollable: find.byType(Scrollable).last,
          );
        }
        expect(find.text(label), findsWidgets);
      }

      for (final label in const [
        'Quarantine',
        'Sales',
        'Inventory',
        'Customers',
        'Finance Control',
      ]) {
        if (find.text(label).evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            find.text(label),
            160,
            scrollable: find.byType(Scrollable).last,
          );
        }
        expect(find.text(label), findsWidgets);
      }
    });
  }

  testWidgets('worker receives operations dashboard without finance figures', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RoleGateway(
          currentUser: _user(role: UserRole.worker),
          permissions: const FarmPermissions(
            canViewEggs: true,
            canEditEggs: true,
            canViewFeeding: true,
            canEditFeeding: true,
            canViewMortality: true,
            canEditMortality: true,
          ),
          connectionChanges: Stream<bool>.value(true),
          isOnline: () async => true,
          inputSink: _NoopInputSink(),
          managementRepository: _FakeManagementDataSource(),
          localDatabase: LocalDatabase(),
          onSignOut: () async {},
        ),
      ),
    );

    await tester.pump();

    expect(find.text('Eggs'), findsOneWidget);
    expect(find.text('Feeding'), findsOneWidget);
    expect(find.text('Mortality'), findsOneWidget);
    expect(find.text('Quick Log'), findsOneWidget);
    expect(find.text('Finance'), findsNothing);
  });

  testWidgets('accountant receives finance dashboard without default tabs', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RoleGateway(
          currentUser: _user(role: UserRole.accountant),
          permissions: const FarmPermissions(
            canViewFinance: true,
            canEditFinance: true,
            canViewSales: true,
            canEditSales: true,
            canViewCustomers: true,
            canEditCustomers: true,
          ),
          connectionChanges: Stream<bool>.value(true),
          isOnline: () async => true,
          inputSink: _NoopInputSink(),
          managementRepository: _FakeManagementDataSource(),
          localDatabase: LocalDatabase(),
          onSignOut: () async {},
        ),
      ),
    );

    await tester.pump();

    expect(find.text('Financial Overview'), findsOneWidget);
    expect(find.text('Daily Operations'), findsNothing);
    expect(find.text('Add Livestock'), findsNothing);
    expect(find.text('Access Denied'), findsNothing);
  });
}

AppUser _user({required UserRole role}) {
  return AppUser(
    id: 'user-1',
    phoneNumber: '+233555000111',
    role: role,
    firstName: 'Ama',
    lastName: 'Mensah',
  );
}

class _NoopInputSink implements WorkerInputSink {
  @override
  Future<void> enqueueWorkerInput({
    required AppUser user,
    required WorkerInputType type,
    required Map<String, dynamic> payload,
  }) async {}

  @override
  Future<int> pendingCount() async => 0;

  @override
  Future<List<RecentWorkerLog>> recentLogs({
    required AppUser user,
    int limit = 3,
  }) async {
    return const [];
  }

  @override
  Stream<WorkerDashboardSnapshot> watchDashboardState({required AppUser user}) {
    return const Stream.empty();
  }
}

class _FakeLicenseDatabase extends LocalDatabase {
  _FakeLicenseDatabase(this.row);

  final Map<String, Object?> row;

  @override
  Future<List<Map<String, Object?>>> rawLocalQuery(
    String sql, [
    List<Object?>? arguments,
  ]) async {
    return [row];
  }
}

class _FakeManagementDataSource implements ManagementDataSource {
  @override
  Future<ManagementSnapshot> loadSnapshot(AppUser user) async {
    return _snapshot();
  }

  @override
  Future<FarmAnalyticsSnapshot> loadAnalytics(AppUser user) async {
    return const FarmAnalyticsSnapshot(
      eggProduction7d: [],
      mortality7d: [],
      feedUsage7d: [],
      revenue14d: [],
      expenses14d: [],
      peakEggDay: 0,
      avgDailyMortality: 0,
      totalFeedUsed7d: 0,
      netProfit14d: 0,
    );
  }

  @override
  Stream<ManagementSnapshot> watchSnapshot(AppUser user) {
    return Stream.value(_snapshot());
  }

  ManagementSnapshot _snapshot() {
    return const ManagementSnapshot(
      totalRevenue: 0,
      totalExpenses: 0,
      pendingSyncCount: 0,
      farms: [],
      batches: [],
      analytics: [],
      profitability: [],
      teamMembers: [],
      houseRecords: [],
      eggRecords: [],
      feedingRecords: [],
      mortalityRecords: [],
      quarantineRecords: [],
      salesRecords: [],
      inventoryRecords: [],
      customerRecords: [],
      supplierRecords: [],
      financeRecords: [],
    );
  }

  @override
  Future<void> logExpense({
    required AppUser user,
    required ExpenseDraft draft,
  }) async {}

  @override
  Future<InvoiceRecord> createInvoice({
    required AppUser user,
    required InvoiceDraft draft,
  }) async {
    return InvoiceRecord(
      invoiceNumber: 'TEST-1',
      createdAt: DateTime(2026),
      draft: draft,
    );
  }

  @override
  Future<void> promoteTeamMember({
    required AppUser owner,
    required TeamMemberRecord member,
    required UserRole targetRole,
  }) async {}
}
