import 'package:workforce_core/workforce_core.dart';

import 'models.dart';

/// Phase 4: reliability (call-offs, no-shows, lateness, a score per person), ratings and
/// notes, do-not-rehire flags, rankings, and staffing suggestions.
///
/// Everything here is about people, so it needs view_workers (venue-wide) to read and
/// manage_workers to change. Employees never see any of it, not even about themselves.
abstract interface class PerformanceRepository {
  /// Attendance outcomes over the reliability window, plus every rating and flag, for
  /// the whole venue. Needs view_workers.
  Future<PerformanceData> loadPerformance(AppSession session);

  /// Ratings, notes and the flag for one person, newest first. Needs view_workers.
  Future<WorkerPerformanceDetail> workerPerformance(AppSession session, String workerId);

  /// Adds a rating (1 to 5 stars, a note of up to 500 characters, optionally about one
  /// event). Ratings are a history: they are never edited or removed.
  Future<void> addRating(AppSession session, String workerId, {required int stars, String note = '', String? eventId});

  /// Adds a note about a person (up to 1,000 characters). Notes are never edited or removed.
  Future<void> addNote(AppSession session, String workerId, String body, {String? eventId});

  /// Flags a person do not rehire, or changes the reason when already flagged. A flagged
  /// person cannot be put in a position.
  Future<void> setDoNotRehire(AppSession session, String workerId, String reason);

  /// Clears the flag.
  Future<void> clearDoNotRehire(AppSession session, String workerId);

  /// Completed events of one type with how each storefront was staffed, for staffing
  /// suggestions. Needs manage_schedule venue-wide.
  Future<List<PastEventStaffing>> staffingHistory(AppSession session, String eventTypeCode);
}

class WorkerRating {
  const WorkerRating({
    required this.id,
    required this.workerId,
    required this.stars,
    required this.ratedAt,
    this.eventId,
    this.note = '',
    this.ratedByName = '',
  });

  final String id;
  final String workerId;
  final String? eventId;
  final int stars;
  final String note;
  final DateTime ratedAt;
  final String ratedByName;

  factory WorkerRating.fromJson(Map<String, dynamic> j, {String ratedByName = ''}) => WorkerRating(
        id: j['id'] as String,
        workerId: j['worker_id'] as String,
        eventId: j['event_id'] as String?,
        stars: (j['stars'] as num).toInt(),
        note: (j['note'] as String?) ?? '',
        ratedAt: DateTime.parse(j['rated_at'] as String).toUtc(),
        ratedByName: ratedByName,
      );
}

class WorkerNote {
  const WorkerNote({required this.id, required this.workerId, required this.body, required this.writtenAt, this.eventId, this.writtenByName = ''});

  final String id;
  final String workerId;
  final String? eventId;
  final String body;
  final DateTime writtenAt;
  final String writtenByName;

  factory WorkerNote.fromJson(Map<String, dynamic> j, {String writtenByName = ''}) => WorkerNote(
        id: j['id'] as String,
        workerId: j['worker_id'] as String,
        eventId: j['event_id'] as String?,
        body: (j['body'] as String?) ?? '',
        writtenAt: DateTime.parse(j['written_at'] as String).toUtc(),
        writtenByName: writtenByName,
      );
}

class RehireFlag {
  const RehireFlag({required this.workerId, required this.reason, required this.flaggedAt, this.flaggedByName = ''});

  final String workerId;
  final String reason;
  final DateTime flaggedAt;
  final String flaggedByName;

  factory RehireFlag.fromJson(Map<String, dynamic> j, {String flaggedByName = ''}) => RehireFlag(
        workerId: j['worker_id'] as String,
        reason: (j['reason'] as String?) ?? '',
        flaggedAt: DateTime.parse(j['flagged_at'] as String).toUtc(),
        flaggedByName: flaggedByName,
      );
}

/// The venue's performance picture: who showed up, ratings and flags.
class PerformanceData {
  const PerformanceData({
    required this.now,
    required this.rules,
    required this.outcomes,
    required this.events,
    required this.ratings,
    required this.flags,
    this.workedMinutes = const {},
  });

  final DateTime now;
  final ReliabilityRules rules;

  /// Outcomes for every person over [ReliabilityRules.windowDays].
  final List<ShiftOutcome> outcomes;

  /// The events those outcomes are from.
  final Map<String, Event> events;
  final List<WorkerRating> ratings;

  /// By worker id.
  final Map<String, RehireFlag> flags;

  /// Minutes worked per person in the window.
  final Map<String, int> workedMinutes;

  Map<String, ReliabilityScore> scores() => reliabilityScores(outcomes, rules: rules, now: now);

  ReliabilityScore scoreOf(String workerId) => reliabilityOf(workerId, outcomes, rules: rules, now: now);
}

class WorkerPerformanceDetail {
  const WorkerPerformanceDetail({required this.ratings, required this.notes, this.flag});

  final List<WorkerRating> ratings;
  final List<WorkerNote> notes;
  final RehireFlag? flag;

  double? get averageStars => ratings.isEmpty ? null : ratings.fold(0, (s, r) => s + r.stars) / ratings.length;
}
