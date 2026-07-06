import '../../core/models/app_user.dart';
import '../../core/storage/local_database.dart';

/// Mirrors web `DashboardContent` routing in poultry-pms.
enum MobileDashboardType {
  executive,
  farmOverview,
  worker,
  accountant,
}

MobileDashboardType resolveMobileDashboardType({
  required UserRole role,
  required String? subscriptionTier,
}) {
  if (role == UserRole.accountant || role == UserRole.financeOfficer) {
    return MobileDashboardType.accountant;
  }
  if (role == UserRole.worker || role == UserRole.cashier) {
    return MobileDashboardType.worker;
  }
  if (role == UserRole.owner && isPremiumSubscriptionTier(subscriptionTier)) {
    return MobileDashboardType.executive;
  }
  return MobileDashboardType.farmOverview;
}

bool isPremiumSubscriptionTier(String? subscriptionTier) {
  final tier = subscriptionTier?.trim().toUpperCase() ?? '';
  return tier == 'PREMIUM' || tier == 'PAID_PREMIUM';
}

Future<String?> loadFarmSubscriptionTier(
  LocalDatabase db,
  String farmId,
) async {
  if (farmId.trim().isEmpty) {
    return null;
  }
  final rows = await db.queryLocalRecords(
    'farms',
    columns: const ['subscription_tier'],
    where: 'id = ?',
    whereArgs: [farmId],
    limit: 1,
  );
  if (rows.isEmpty) {
    return null;
  }
  return rows.first['subscription_tier']?.toString();
}
