import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/time/venue_time.dart';
import '../../data/models.dart';
import '../../data/people_repository.dart';
import '../../data/reports_repository.dart';

ReportsRepository reportsRepo(Ref ref) => ref.read(repositoryProvider) as ReportsRepository;

/// The venue's targets; the defaults when none are saved or they cannot be read (a lead
/// on the live view has no view_reports).
final reportTargetsProvider = FutureProvider<ReportTargets>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return ReportTargets.defaults;
  try {
    return await reportsRepo(ref).loadReportTargets(session);
  } catch (_) {
    return ReportTargets.fromRow(null, settings: session.venue.settings);
  }
});

/// The season start month from venue settings (default August).
final seasonStartMonthProvider = Provider<int>((ref) {
  final session = ref.watch(sessionProvider);
  return session == null ? Season.defaultStartMonth : Season.startMonthFrom(session.venue.settings);
});

/// The season containing today, in venue time.
final currentSeasonProvider = Provider<Season>((ref) {
  final session = ref.watch(sessionProvider);
  final month = ref.watch(seasonStartMonthProvider);
  final today = venueDate(DateTime.now().toUtc(), session?.venue.timeZone ?? 'America/Chicago');
  return Season.of(today, startMonth: month);
});

/// One season's report, with the people for names.
class SeasonReport {
  const SeasonReport({required this.season, required this.result, required this.workers, required this.through});

  final Season season;
  final ReportResult result;
  final Map<String, Worker> workers;

  /// Last day with data (today for the current season).
  final DateTime through;

  String name(String? workerId) => workers[workerId]?.displayName ?? 'Unknown';
}

/// Report for the season starting in the given year.
final seasonReportProvider = FutureProvider.autoDispose.family<SeasonReport, int>((ref, startYear) async {
  final session = ref.watch(sessionProvider);
  if (session == null) throw const AppFailure('Not signed in');
  final venue = await ref.watch(venueProvider.future);
  final season = Season(startYear, startMonth: ref.watch(seasonStartMonthProvider));
  final now = DateTime.now().toUtc();
  final data = await reportsRepo(ref).loadReportData(session, season.firstDay, season.lastDay);
  final result = buildReport(
    data: data,
    rules: venue.rules,
    timeZone: venue.venue.timeZone,
    from: season.firstDay,
    to: season.lastDay,
    now: now,
    jobRoles: venue.jobRoles,
  );
  final today = venueDate(now, venue.venue.timeZone);
  return SeasonReport(season: season, result: result, workers: data.workers, through: today.isBefore(season.lastDay) ? today : season.lastDay);
});

/// Turnover and retention, regular staff only.
final retentionProvider = FutureProvider.autoDispose<List<RetentionRow>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  final month = ref.watch(seasonStartMonthProvider);
  final rows = await reportsRepo(ref).loadWorkerSeasons(session, startMonth: month);
  final current = ref.watch(currentSeasonProvider);
  final report = await ref.watch(seasonReportProvider(current.startYear).future);
  final regular = {for (final w in report.workers.values) if (w.type == WorkerType.regular) w.id};
  return retentionBySeason(rows, onlyWorkers: regular);
});

/// Onboarding totals; null when this person cannot see onboarding.
final reportOnboardingProvider = FutureProvider.autoDispose<OnboardingSummary?>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null || !(session.canVenueWide(Perm.viewWorkers) || session.canVenueWide(Perm.manageWorkers))) return null;
  try {
    final list = await (ref.read(repositoryProvider) as PeopleRepository).onboardingOverview(session);
    return OnboardingSummary.of(list);
  } catch (_) {
    return null;
  }
});
