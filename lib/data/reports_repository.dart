import 'package:workforce_core/workforce_core.dart';

import 'models.dart';

/// Phase 4: KPIs and reports (workforce only), targets with green / yellow / red, and
/// exports. Implemented by the demo and Supabase repositories (reports part files).
///
/// Reading needs view_reports. Money (labor cost, budgets, tips, NPO amounts) is loaded
/// only for people with view_pay for the whole venue; everyone else gets
/// [ReportData.money] null and sees no amounts.
abstract interface class ReportsRepository {
  /// The venue's targets, or the defaults when none are saved.
  Future<ReportTargets> loadReportTargets(AppSession session);

  /// Saves the targets. Needs manage_settings.
  Future<void> saveReportTargets(AppSession session, ReportTargets targets);

  /// Records behind the KPIs for events whose venue-local start date is [from] to [to]
  /// (inclusive), plus a week before (for workweek overtime).
  Future<ReportData> loadReportData(AppSession session, DateTime from, DateTime to);

  /// How many events each person clocked in at, per season (start year), for turnover
  /// and retention. Venue-wide view_reports.
  Future<List<WorkerSeason>> loadWorkerSeasons(AppSession session, {int startMonth = Season.defaultStartMonth});
}
