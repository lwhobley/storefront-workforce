import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../data/models.dart';
import '../../data/performance_repository.dart';

PerformanceRepository perfRepo(Ref ref) => ref.read(repositoryProvider) as PerformanceRepository;

extension PerformanceRepoOnWidgetRef on WidgetRef {
  PerformanceRepository get performance => read(repositoryProvider) as PerformanceRepository;
}

/// The venue's outcomes, ratings and flags. Kept for a few minutes after the last screen
/// stops using it, since it reads a year of shifts and punches.
final performanceDataProvider = FutureProvider.autoDispose<PerformanceData>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null || !session.canVenueWide(Perm.viewWorkers)) throw const AppFailure('Not authorized');
  final link = ref.keepAlive();
  Timer? timer;
  ref.onCancel(() => timer = Timer(const Duration(minutes: 5), link.close));
  ref.onResume(() => timer?.cancel());
  ref.onDispose(() => timer?.cancel());
  return perfRepo(ref).loadPerformance(session);
});

/// Ratings, notes and the flag for one person.
final workerPerformanceProvider = FutureProvider.autoDispose.family<WorkerPerformanceDetail, String>((ref, workerId) async {
  final session = ref.watch(sessionProvider);
  if (session == null) throw const AppFailure('Not signed in');
  return perfRepo(ref).workerPerformance(session, workerId);
});

/// Past completed events of one type, for staffing suggestions.
final staffingHistoryProvider = FutureProvider.autoDispose.family<List<PastEventStaffing>, String>((ref, eventType) async {
  final session = ref.watch(sessionProvider);
  if (session == null) throw const AppFailure('Not signed in');
  return perfRepo(ref).staffingHistory(session, eventType);
});

/// What the assign sheet shows about a candidate.
class CandidateInsight {
  const CandidateInsight({required this.score, required this.flagged});

  final ReliabilityScore score;
  final bool flagged;
}

/// Scores and flags by worker for the assign sheet, or null when the signed-in person
/// may not see them (for example a storefront lead).
final candidateInsightsProvider = FutureProvider.autoDispose<Map<String, CandidateInsight>?>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null || !session.canVenueWide(Perm.viewWorkers)) return null;
  final data = await ref.watch(performanceDataProvider.future);
  final scores = data.scores();
  final ids = {...scores.keys, ...data.flags.keys};
  return {
    for (final id in ids)
      id: CandidateInsight(
        score: scores[id] ?? reliabilityOf(id, const [], rules: data.rules, now: data.now),
        flagged: data.flags.containsKey(id),
      ),
  };
});

/// After a rating, note or flag change.
void refreshPerformance(WidgetRef ref, String workerId) {
  ref.invalidate(workerPerformanceProvider(workerId));
  ref.invalidate(performanceDataProvider);
}
