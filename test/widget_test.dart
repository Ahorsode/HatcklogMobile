import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/core/models/app_user.dart';
import 'package:hatchlog_m/core/models/worker_input_type.dart';
import 'package:hatchlog_m/features/auth/data/auth_repository.dart';
import 'package:hatchlog_m/features/auth/data/supabase_remote_api.dart';
import 'package:hatchlog_m/features/management/data/management_models.dart';
import 'package:hatchlog_m/features/management/data/management_repository.dart';
import 'package:hatchlog_m/features/role_gateway/presentation/role_gateway.dart';
import 'package:hatchlog_m/features/sync/data/worker_input_sink.dart';
import 'package:hatchlog_m/presentation/analytics/analytics_models.dart';
import 'package:hatchlog_m/core/storage/local_database.dart';
import 'package:hatchlog_m/services/encryption_service.dart';
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
            connectionChanges: Stream<bool>.value(true),
            isOnline: () async => true,
            inputSink: _NoopInputSink(),
            managementRepository: _FakeManagementDataSource(),
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

      if (find.text('Quarantine').evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          find.text('Quarantine'),
          160,
          scrollable: find.byType(Scrollable).last,
        );
      }
      expect(find.text('Quarantine'), findsWidgets);
      expect(find.text('Sales'), findsWidgets);

      if (find.text('Finance Control').evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          find.text('Finance Control'),
          160,
          scrollable: find.byType(Scrollable).last,
        );
      }
      expect(find.text('Inventory'), findsWidgets);
      expect(find.text('Customers'), findsWidgets);
      expect(find.text('Finance Control'), findsWidgets);
    });
  }

  testWidgets('worker receives operations dashboard without finance figures', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RoleGateway(
          currentUser: _user(role: UserRole.worker),
          connectionChanges: Stream<bool>.value(true),
          isOnline: () async => true,
          inputSink: _NoopInputSink(),
          managementRepository: _FakeManagementDataSource(),
          onSignOut: () async {},
        ),
      ),
    );

    await tester.pump();

    expect(find.text('Daily Operations'), findsOneWidget);
    expect(find.text('Financial Overview'), findsNothing);
    expect(find.text('Add Livestock'), findsNothing);
    expect(find.text('Access Denied'), findsNothing);
  });

  testWidgets('accountant receives finance dashboard without default tabs', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RoleGateway(
          currentUser: _user(role: UserRole.accountant),
          connectionChanges: Stream<bool>.value(true),
          isOnline: () async => true,
          inputSink: _NoopInputSink(),
          managementRepository: _FakeManagementDataSource(),
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
