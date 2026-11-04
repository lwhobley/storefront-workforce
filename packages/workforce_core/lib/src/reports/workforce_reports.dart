/// How people and seasons did over time: reliability per person, and season totals.
///
/// Shift outcomes come from [attendanceOutcomes] in rules/attendance_outcomes.dart, so
/// the reports and the reliability score always agree on what counts as on time.
library;

import '../rules/attendance_outcomes.dart';
import 'event_kpis.dart';

class Reliability {
  const Reliability({required this.workerId, required this.expected, required this.onTime, required this.late, required this.noShows, required this.callOffs});

  final String workerId;

  /// Shifts with a known result the person was expected at (released and pending are out).
  final int expected;
  final int onTime;
  final int late;
  final int noShows;
  final int callOffs;

  /// On time out of expected; null when there is nothing to measure.
  double? get score => expected == 0 ? null : onTime / expected;
}

/// Reliability per person. Sorted by worker id.
List<Reliability> reliabilityOf(Iterable<ShiftOutcome> outcomes) {
  final byWorker = <String, List<ShiftOutcome>>{};
  for (final o in outcomes) {
    byWorker.putIfAbsent(o.workerId, () => []).add(o);
  }
  final ids = byWorker.keys.toList()..sort();
  return [
    for (final id in ids)
      () {
        final s = AttendanceSummary(byWorker[id]!);
        return Reliability(workerId: id, expected: s.expected, onTime: s.onTime, late: s.late, noShows: s.noShows, callOffs: s.callOffs);
      }(),
  ];
}

/// Season label for a local date. Seasons run August 1 to July 31: "2026–27".
String seasonLabel(DateTime localDate) {
  final start = localDate.month >= 8 ? localDate.year : localDate.year - 1;
  return '$start–${((start + 1) % 100).toString().padLeft(2, '0')}';
}

class SeasonSummary {
  const SeasonSummary({
    required this.label,
    required this.events,
    required this.needed,
    required this.assigned,
    required this.attended,
    required this.late,
    required this.noShows,
    required this.laborCostCents,
    required this.budgetCents,
  });

  final String label;
  final int events;
  final int needed;
  final int assigned;
  final int attended;
  final int late;
  final int noShows;

  /// Sum over events that have a labor report; null when none do.
  final int? laborCostCents;

  /// Sum over events that have a budget; null when none do.
  final int? budgetCents;

  double? get fillRate => needed == 0 ? null : assigned / needed;
  double? get attendanceRate => assigned == 0 ? null : attended / assigned;
}

/// Totals per season from event KPIs, newest season first. Each row pairs an event's
/// local start date with its numbers.
List<SeasonSummary> seasonSummaries(Iterable<(DateTime localStart, EventKpis kpis)> rows) {
  final byLabel = <String, List<(DateTime, EventKpis)>>{};
  for (final r in rows) {
    byLabel.putIfAbsent(seasonLabel(r.$1), () => []).add(r);
  }
  final labels = byLabel.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final label in labels)
      () {
        final list = byLabel[label]!;
        int sum(int Function(EventKpis) f) => list.fold(0, (s, r) => s + f(r.$2));
        int? sumOrNull(int? Function(EventKpis) f) {
          final values = <int>[];
          for (final r in list) {
            final v = f(r.$2);
            if (v != null) values.add(v);
          }
          return values.isEmpty ? null : values.fold<int>(0, (s, v) => s + v);
        }

        return SeasonSummary(
          label: label,
          events: list.length,
          needed: sum((k) => k.needed),
          assigned: sum((k) => k.assigned),
          attended: sum((k) => k.attended),
          late: sum((k) => k.late),
          noShows: sum((k) => k.noShows),
          laborCostCents: sumOrNull((k) => k.laborCostCents),
          budgetCents: sumOrNull((k) => k.budgetCents),
        );
      }(),
  ];
}
