/// Rankings: staff sorted by reliability, average rating or events worked, for deciding
/// who to schedule and rehire. Also the same numbers rolled up per NPO group.
library;

import '../model/entities.dart';
import '../model/enums.dart';
import '../rules/attendance_outcomes.dart';
import '../rules/timeline.dart';
import 'reliability.dart';

/// One person's line in the rankings.
class RankingEntry {
  const RankingEntry({
    required this.workerId,
    required this.name,
    required this.reliability,
    this.averageStars,
    this.ratingCount = 0,
    this.eventsWorked = 0,
    this.flagged = false,
  });

  final String workerId;
  final String name;
  final ReliabilityScore reliability;

  /// Mean of every rating on file. Null with no ratings.
  final double? averageStars;
  final int ratingCount;

  /// Events the person showed up for (on time or late) in the loaded window.
  final int eventsWorked;

  /// Flagged do not rehire.
  final bool flagged;

  int? get score => reliability.score;
}

enum RankingSort {
  reliability('Reliability'),
  rating('Rating'),
  events('Events worked'),
  name('Name');

  const RankingSort(this.label);
  final String label;
}

/// Sorts best first. People with too few events to judge ("new") come after everyone
/// with a real score when sorting by reliability; missing ratings sort last. Ties fall
/// back to reliability, then rating, then events, then name, so the order is stable.
List<RankingEntry> sortRankings(Iterable<RankingEntry> entries, RankingSort by) {
  int byScore(RankingEntry a, RankingEntry b) {
    final na = a.score == null || a.reliability.isNew ? 1 : 0;
    final nb = b.score == null || b.reliability.isNew ? 1 : 0;
    if (na != nb) return na.compareTo(nb);
    return (b.score ?? -1).compareTo(a.score ?? -1);
  }

  int byRating(RankingEntry a, RankingEntry b) => (b.averageStars ?? -1).compareTo(a.averageStars ?? -1);
  int byEvents(RankingEntry a, RankingEntry b) => b.eventsWorked.compareTo(a.eventsWorked);
  int byName(RankingEntry a, RankingEntry b) {
    final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return c != 0 ? c : a.workerId.compareTo(b.workerId);
  }

  final order = switch (by) {
    RankingSort.reliability => [byScore, byRating, byEvents, byName],
    RankingSort.rating => [byRating, byScore, byEvents, byName],
    RankingSort.events => [byEvents, byScore, byRating, byName],
    RankingSort.name => [byName],
  };
  return [...entries]..sort((a, b) {
      for (final f in order) {
        final c = f(a, b);
        if (c != 0) return c;
      }
      return 0;
    });
}

/// Builds the rankings from outcomes, ratings (worker id and stars) and flags.
List<RankingEntry> buildRankings({
  required Iterable<Worker> workers,
  required Iterable<ShiftOutcome> outcomes,
  required Iterable<(String workerId, int stars)> ratings,
  required Set<String> flagged,
  required ReliabilityRules rules,
  required DateTime now,
}) {
  final scores = reliabilityScores(outcomes, rules: rules, now: now);
  final worked = <String, Set<String>>{};
  for (final o in outcomes) {
    if (o.outcome == AttendanceOutcome.onTime || o.outcome == AttendanceOutcome.late) {
      worked.putIfAbsent(o.workerId, () => {}).add(o.eventId);
    }
  }
  final stars = <String, List<int>>{};
  for (final (w, s) in ratings) {
    stars.putIfAbsent(w, () => []).add(s);
  }
  return [
    for (final w in workers)
      RankingEntry(
        workerId: w.id,
        name: w.displayName,
        reliability: scores[w.id] ?? reliabilityOf(w.id, const [], rules: rules, now: now),
        averageStars: stars[w.id] == null ? null : stars[w.id]!.reduce((a, b) => a + b) / stars[w.id]!.length,
        ratingCount: stars[w.id]?.length ?? 0,
        eventsWorked: worked[w.id]?.length ?? 0,
        flagged: flagged.contains(w.id),
      ),
  ];
}

/// Minutes worked per person (all events in [punches]), from their punches.
Map<String, int> workedMinutesByWorker(Iterable<Punch> punches, {required DateTime now}) {
  final byKey = <String, List<Punch>>{};
  for (final p in punches) {
    if (p.status == PunchStatus.voided) continue;
    byKey.putIfAbsent('${p.workerId}|${p.eventId}', () => []).add(p);
  }
  final out = <String, int>{};
  for (final e in byKey.entries) {
    final worker = e.key.split('|').first;
    out[worker] = (out[worker] ?? 0) + WorkTimeline.fromPunches(e.value, now: now).workedMinutes;
  }
  return out;
}

/// An NPO group's (or any group's) attendance, added up over its members.
class GroupReliability {
  GroupReliability(this.groupId);

  final String groupId;
  int members = 0;

  /// Members with a reliability score (enough events to judge).
  int scored = 0;
  int _scoreTotal = 0;
  int workedMinutes = 0;
  int shiftsWorked = 0;
  int onTime = 0;
  int late = 0;
  int noShows = 0;
  int callOffs = 0;

  /// Average of the members' scores, or null when nobody has one.
  int? get averageScore => scored == 0 ? null : (_scoreTotal / scored).round();

  int get expected => onTime + late + noShows + callOffs;

  /// Showed up (on time or late) out of everyone expected.
  double? get attendanceRate => expected == 0 ? null : (onTime + late) / expected;
}

/// Totals per group: hours, shifts worked, no-shows, call-offs, late arrivals and the
/// average reliability score of members who have one.
Map<String, GroupReliability> groupReliability({
  required Map<String, String> groupOf,
  required Iterable<ShiftOutcome> outcomes,
  required Map<String, int> workedMinutes,
  required Map<String, ReliabilityScore> scores,
}) {
  final out = <String, GroupReliability>{};
  GroupReliability g(String id) => out.putIfAbsent(id, () => GroupReliability(id));
  for (final MapEntry(key: worker, value: group) in groupOf.entries) {
    final x = g(group)..members += 1;
    x.workedMinutes += workedMinutes[worker] ?? 0;
    final s = scores[worker];
    if (s != null && s.score != null && !s.isNew) {
      x.scored++;
      x._scoreTotal += s.score!;
    }
  }
  for (final o in outcomes) {
    final group = groupOf[o.workerId];
    if (group == null) continue;
    final x = g(group);
    switch (o.outcome) {
      case AttendanceOutcome.onTime:
        x.onTime++;
        x.shiftsWorked++;
      case AttendanceOutcome.late:
        x.late++;
        x.shiftsWorked++;
      case AttendanceOutcome.noShow:
        x.noShows++;
      case AttendanceOutcome.callOff:
        x.callOffs++;
      case AttendanceOutcome.released || AttendanceOutcome.pending:
        break;
    }
  }
  return out;
}
