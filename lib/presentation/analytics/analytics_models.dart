class DailyDataPoint {
  const DailyDataPoint({required this.date, required this.value});

  final DateTime date;
  final double value;
}

class FarmAnalyticsSnapshot {
  const FarmAnalyticsSnapshot({
    required this.eggProduction7d,
    required this.mortality7d,
    required this.feedUsage7d,
    required this.revenue14d,
    required this.expenses14d,
    required this.peakEggDay,
    required this.avgDailyMortality,
    required this.totalFeedUsed7d,
    required this.netProfit14d,
  });

  final List<DailyDataPoint> eggProduction7d;
  final List<DailyDataPoint> mortality7d;
  final List<DailyDataPoint> feedUsage7d;
  final List<DailyDataPoint> revenue14d;
  final List<DailyDataPoint> expenses14d;
  final int peakEggDay;
  final double avgDailyMortality;
  final double totalFeedUsed7d;
  final double netProfit14d;
}
