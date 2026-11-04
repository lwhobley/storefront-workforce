/// Reliability: one score per person from 0 to 100, built on the shared attendance
/// outcomes ([attendanceOutcomes]), so it always agrees with the reports.
///
/// The whole rule in one sentence (see [ReliabilityRules.explain]): start at 100 and take
/// off points for each no-show, call-off and late arrival in the person's last 10 events
/// in the past year. Every event counts the same, however recent; the window keeps old
/// mistakes from following someone forever.
///
/// Weights live in the venue's settings under `reliability`, with these defaults:
///
/// ```json
/// {"window_events": 10, "window_days": 365, "no_show_points": 25,
///  "call_off_points": 10, "late_points": 5, "min_events": 3}
/// ```
library;

import '../rules/attendance_outcomes.dart';

class ReliabilityRules {
  const ReliabilityRules({
    this.windowEvents = 10,
    this.windowDays = 365,
    this.noShowPoints = 25,
    this.callOffPoints = 10,
    this.latePoints = 5,
    this.minEvents = 3,
  });

  /// How many of the person's most recent events count.
  final int windowEvents;

  /// Events older than this many days do not count.
  final int windowDays;
  final int noShowPoints;
  final int callOffPoints;
  final int latePoints;

  /// With fewer events than this the score is shown as "new" (too little to judge).
  final int minEvents;

  factory ReliabilityRules.fromJson(Map<String, dynamic>? j) {
    const d = ReliabilityRules();
    if (j == null) return d;
    int read(String key, int fallback, {int min = 0}) {
      final v = (j[key] as num?)?.toInt();
      return v == null || v < min ? fallback : v;
    }

    return ReliabilityRules(
      windowEvents: read('window_events', d.windowEvents, min: 1),
      windowDays: read('window_days', d.windowDays, min: 1),
      noShowPoints: read('no_show_points', d.noShowPoints),
      callOffPoints: read('call_off_points', d.callOffPoints),
      latePoints: read('late_points', d.latePoints),
      minEvents: read('min_events', d.minEvents),
    );
  }

  /// From the venue's settings JSON (the `reliability` section).
  factory ReliabilityRules.fromVenueSettings(Map<String, dynamic>? settings) =>
      ReliabilityRules.fromJson((settings?['reliability'] as Map?)?.cast<String, dynamic>());

  Map<String, dynamic> toJson() => {
        'window_events': windowEvents,
        'window_days': windowDays,
        'no_show_points': noShowPoints,
        'call_off_points': callOffPoints,
        'late_points': latePoints,
        'min_events': minEvents,
      };

  /// How the score works, in one sentence.
  String get explain => 'Starts at 100, minus $noShowPoints for each no-show, $callOffPoints for each call-off '
      'and $latePoints for each late arrival, over the last $windowEvents events in the past '
      '${windowDays == 365 ? 'year' : '$windowDays days'}.';

  int pointsFor(AttendanceOutcome o) => switch (o) {
        AttendanceOutcome.noShow => noShowPoints,
        AttendanceOutcome.callOff => callOffPoints,
        AttendanceOutcome.late => latePoints,
        _ => 0,
      };
}

/// One person's score and why.
class ReliabilityScore {
  const ReliabilityScore({
    required this.workerId,
    required this.score,
    required this.counted,
    required this.rules,
  });

  final String workerId;

  /// 0 to 100. Null when the person has no counted events in the window.
  final int? score;

  /// The events that count, most recent first (at most [ReliabilityRules.windowEvents]).
  final List<ShiftOutcome> counted;
  final ReliabilityRules rules;

  AttendanceSummary get summary => AttendanceSummary(counted);

  int get events => counted.length;
  int get noShows => counted.where((o) => o.outcome == AttendanceOutcome.noShow).length;
  int get callOffs => counted.where((o) => o.outcome == AttendanceOutcome.callOff).length;
  int get lates => counted.where((o) => o.outcome == AttendanceOutcome.late).length;
  int get onTime => counted.where((o) => o.outcome == AttendanceOutcome.onTime).length;

  int get noShowPoints => noShows * rules.noShowPoints;
  int get callOffPoints => callOffs * rules.callOffPoints;
  int get latePoints => lates * rules.latePoints;

  /// Too few events to judge fairly; shown as "new".
  bool get isNew => events < rules.minEvents;

  /// The arithmetic behind the number, e.g.
  /// "100 − 25 (1 no-show) − 10 (2 late) = 65 over 6 events".
  String get breakdown {
    if (score == null) return 'No events in the past ${rules.windowDays == 365 ? 'year' : '${rules.windowDays} days'}.';
    final parts = <String>['100'];
    if (noShows > 0) parts.add('− $noShowPoints (${_n(noShows, 'no-show')})');
    if (callOffs > 0) parts.add('− $callOffPoints (${_n(callOffs, 'call-off')})');
    if (lates > 0) parts.add('− $latePoints (${lates == 1 ? '1 late' : '$lates late'})');
    final total = noShowPoints + callOffPoints + latePoints;
    final floored = total > 100 ? ' (lowest is 0)' : '';
    return '${parts.join(' ')} = $score$floored over ${_n(events, 'event')}';
  }
}

String _n(int n, String noun) => n == 1 ? '1 $noun' : '$n ${noun}s';

/// Score for one person from their outcomes (other people's outcomes are ignored).
///
/// Only outcomes that count (on time, late, no-show, call-off) with a call time inside
/// the window and not after [now] are used; released and pending ones never count.
ReliabilityScore reliabilityOf(String workerId, Iterable<ShiftOutcome> outcomes, {required ReliabilityRules rules, required DateTime now}) {
  final since = now.subtract(Duration(days: rules.windowDays));
  final mine = [
    for (final o in outcomes)
      if (o.workerId == workerId && o.outcome.counts && !o.callTime.isBefore(since) && !o.callTime.isAfter(now)) o,
  ]..sort((a, b) {
      final c = b.callTime.compareTo(a.callTime);
      return c != 0 ? c : a.eventId.compareTo(b.eventId);
    });
  final counted = mine.take(rules.windowEvents).toList();
  if (counted.isEmpty) return ReliabilityScore(workerId: workerId, score: null, counted: const [], rules: rules);
  final points = counted.fold(0, (s, o) => s + rules.pointsFor(o.outcome));
  final score = (100 - points).clamp(0, 100);
  return ReliabilityScore(workerId: workerId, score: score, counted: List.unmodifiable(counted), rules: rules);
}

/// Scores for everyone who appears in [outcomes] (plus [workerIds], who get a null score
/// when they have no events).
Map<String, ReliabilityScore> reliabilityScores(
  Iterable<ShiftOutcome> outcomes, {
  required ReliabilityRules rules,
  required DateTime now,
  Iterable<String> workerIds = const [],
}) {
  final byWorker = <String, List<ShiftOutcome>>{};
  for (final o in outcomes) {
    byWorker.putIfAbsent(o.workerId, () => []).add(o);
  }
  final ids = {...byWorker.keys, ...workerIds};
  return {for (final id in ids) id: reliabilityOf(id, byWorker[id] ?? const [], rules: rules, now: now)};
}

/// A plain word for a score, for tags: Strong (90+), OK (75+), Watch (50+), Poor.
String reliabilityBand(int score) => score >= 90
    ? 'Strong'
    : score >= 75
        ? 'OK'
        : score >= 50
            ? 'Watch'
            : 'Poor';
