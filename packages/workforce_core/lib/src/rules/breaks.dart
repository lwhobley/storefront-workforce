/// Break compliance for one shift.
///
/// A break rule is due once cumulative worked minutes since the first clock-in
/// (breaks excluded, all work segments counted) reach `afterWorkedMinutes`. It is
/// not reset by an earlier break and does not require continuous work.
///
/// Only breaks of the rule's kind count (a meal does not satisfy a rest rule).
/// Each break satisfies at most one rule; rules of the same kind are matched to
/// breaks in order (earliest rule to earliest qualifying break).
library;

import '../model/enums.dart';
import 'timeline.dart';
import 'venue_rules.dart';

enum BreakStatus {
  /// Not due yet, and not within the reminder window.
  notYetDue,

  /// Due within `reminderMinutesBefore` worked minutes.
  dueSoon,

  /// Due point reached with no break of this kind yet, still on the clock.
  due,

  /// A break of this kind is under way but not yet the minimum length.
  inProgress,

  /// A long-enough break started at or before the due point.
  taken,

  /// A long-enough break, started after the due point.
  takenLate,

  /// Due point reached and the only break of this kind was shorter than the minimum.
  short,

  /// Clocked out after the due point with no break of this kind.
  missed,

  /// Clocked out before the due point, so the rule never applied.
  notRequired,
}

class BreakRuleStatus {
  const BreakRuleStatus({
    required this.rule,
    required this.status,
    this.dueAt,
    this.minutesUntilDue,
    this.minutesPastDue,
    this.breakTaken,
  });

  final BreakRule rule;
  final BreakStatus status;

  /// When cumulative work reached the rule's threshold. Null if not reached.
  final DateTime? dueAt;

  /// Worked minutes left before due. Null once due.
  final int? minutesUntilDue;

  /// Worked minutes past the due point while status is [BreakStatus.due].
  final int? minutesPastDue;

  /// The break matched to this rule, if any.
  final BreakSegment? breakTaken;
}

class BreakEvaluation {
  const BreakEvaluation({required this.statuses});

  final List<BreakRuleStatus> statuses;

  /// Something to act on now: a break is due, was short, or was missed.
  bool get needsAttention => statuses.any(
      (s) => s.status == BreakStatus.due || s.status == BreakStatus.short || s.status == BreakStatus.missed);

  /// Something for payroll or compliance review: short, missed, or taken late.
  bool get hasExceptions => statuses.any(
      (s) => s.status == BreakStatus.short || s.status == BreakStatus.missed || s.status == BreakStatus.takenLate);

  /// Worked minutes until the next break is due: 0 if one is due now, null if none pending.
  int? get minutesUntilNextDue {
    if (statuses.any((s) => s.status == BreakStatus.due)) return 0;
    int? best;
    for (final s in statuses) {
      final m = s.minutesUntilDue;
      if ((s.status == BreakStatus.notYetDue || s.status == BreakStatus.dueSoon) && m != null) {
        if (best == null || m < best) best = m;
      }
    }
    return best;
  }
}

/// Whether [rule] applies to a worker of [age]. Unknown age is treated as an adult.
bool breakRuleApplies(BreakRule rule, int? age, int adultAge) {
  final minor = age != null && age < adultAge;
  return switch (rule.audience) {
    BreakAudience.all => true,
    BreakAudience.adults => !minor,
    BreakAudience.minors => minor,
  };
}

/// Status of each applicable break rule as of [now].
///
/// Open segments in [timeline] are treated as running until [now]. [age] null means
/// adult; pass `MinorRules.adultAge` as [adultAge].
BreakEvaluation evaluateBreaks({
  required WorkTimeline timeline,
  required BreakRules rules,
  int? age,
  int adultAge = 18,
  required DateTime now,
}) {
  final applicable = [
    for (final r in rules.rules)
      if (breakRuleApplies(r, age, adultAge)) r,
  ];

  // Worked time as of now.
  final segs = [for (final s in timeline.workSegments) (s.start, s.endAt(now))];
  final worked = segs.fold(0, (sum, s) => sum + _mins(s.$1, s.$2));

  DateTime? dueInstant(int after) {
    var acc = 0;
    for (final (start, end) in segs) {
      final m = _mins(start, end);
      if (acc + m >= after) return start.add(Duration(minutes: after - acc));
      acc += m;
    }
    return null;
  }

  final clockedOut = timeline.state == TimelineState.clockedOut;
  final results = List<BreakRuleStatus?>.filled(applicable.length, null);

  for (final kind in BreakKind.values) {
    // Indexes into [applicable] for this kind, earliest due first.
    final order = [
      for (var i = 0; i < applicable.length; i++)
        if (BreakKind.fromCode(applicable[i].kind) == kind) i,
    ]..sort((a, b) {
        final c = applicable[a].afterWorkedMinutes.compareTo(applicable[b].afterWorkedMinutes);
        return c != 0 ? c : a.compareTo(b);
      });
    if (order.isEmpty) continue;
    final kindBreaks = timeline.breakSegments.where((b) => b.kind == kind).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final used = <int>{};

    int? pick(bool Function(BreakSegment) test) {
      for (var i = 0; i < kindBreaks.length; i++) {
        if (!used.contains(i) && test(kindBreaks[i])) {
          used.add(i);
          return i;
        }
      }
      return null;
    }

    for (final idx in order) {
      final rule = applicable[idx];
      final dueAt = dueInstant(rule.afterWorkedMinutes);
      final until = dueAt == null ? rule.afterWorkedMinutes - worked : null;

      BreakRuleStatus result(BreakStatus status, {BreakSegment? taken, int? pastDue}) => BreakRuleStatus(
            rule: rule,
            status: status,
            dueAt: dueAt,
            minutesUntilDue: until,
            minutesPastDue: pastDue,
            breakTaken: taken,
          );

      final q = pick((b) => b.minutesAt(now) >= rule.minimumMinutes);
      if (q != null) {
        final b = kindBreaks[q];
        final onTime = dueAt == null || !b.start.isAfter(dueAt);
        results[idx] = result(onTime ? BreakStatus.taken : BreakStatus.takenLate, taken: b);
        continue;
      }
      final open = pick((b) => b.isOpen);
      if (open != null) {
        results[idx] = result(BreakStatus.inProgress, taken: kindBreaks[open]);
        continue;
      }
      if (dueAt == null) {
        if (clockedOut) {
          results[idx] = result(BreakStatus.notRequired);
        } else {
          results[idx] = result(until! <= rules.reminderMinutesBefore ? BreakStatus.dueSoon : BreakStatus.notYetDue);
        }
        continue;
      }
      final s = pick((_) => true);
      if (s != null) {
        results[idx] = result(BreakStatus.short, taken: kindBreaks[s]);
      } else if (clockedOut) {
        results[idx] = result(BreakStatus.missed);
      } else {
        results[idx] = result(BreakStatus.due, pastDue: worked - rule.afterWorkedMinutes);
      }
    }
  }

  return BreakEvaluation(statuses: [for (final r in results) r!]);
}

int _mins(DateTime a, DateTime b) => b.isAfter(a) ? b.difference(a).inMinutes : 0;
