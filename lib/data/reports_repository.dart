import 'package:workforce_core/workforce_core.dart';

import 'models.dart';

/// Phase 4: KPIs and reports (workforce only), targets with green / yellow / red, and
/// exports. Implemented by the demo and Supabase repositories (reports part files).
abstract interface class ReportsRepository {
  /// Everything the KPI reports are calculated from, for local dates [from] to [to]
  /// inclusive, plus the week on each side so workweek overtime is complete.
  ///
  /// Pay information ([ReportData.money]) is only loaded for people who may see pay, so
  /// a manager without `view_pay` gets headcount and attendance but no money.
  Future<ReportData> loadReportData(AppSession session, DateTime from, DateTime to);
}
