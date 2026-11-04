/// One worker's punches turned into work and break segments.
///
/// Rounding: every punch time (and `now`) is truncated to the whole minute
/// (seconds dropped) before any math, so all durations are exact whole minutes
/// and add up across windows. No payroll rounding is applied here.
library;

import '../model/entities.dart';
import '../model/enums.dart';
import 'local_time.dart';
import 'venue_rules.dart';
import 'work_interval.dart';

enum TimelineState { notStarted, working, onBreak, clockedOut }

/// A stretch on the clock and not on break.
class WorkSegment {
  const WorkSegment({required this.start, required this.end, this.isOpen = false});

  final DateTime start;

  /// For an open segment, `now` (or [start] when no `now` was given).
  final DateTime end;

  /// True when there was no punch closing it yet.
  final bool isOpen;

  int get minutes => end.isAfter(start) ? end.difference(start).inMinutes : 0;

  /// End of the segment as of [now]: open segments run to [now].
  DateTime endAt(DateTime now) {
    if (!isOpen) return end;
    final n = truncateToMinute(now);
    return n.isAfter(end) ? n : end;
  }
}

/// A break between a break_start and its break_end (or clock_out).
class BreakSegment {
  const BreakSegment({required this.kind, required this.start, required this.end, this.isOpen = false});

  final BreakKind kind;
  final DateTime start;
  final DateTime end;
  final bool isOpen;

  int get minutes => end.isAfter(start) ? end.difference(start).inMinutes : 0;

  DateTime endAt(DateTime now) {
    if (!isOpen) return end;
    final n = truncateToMinute(now);
    return n.isAfter(end) ? n : end;
  }

  int minutesAt(DateTime now) {
    final e = endAt(now);
    return e.isAfter(start) ? e.difference(start).inMinutes : 0;
  }
}

/// Something in the punch list that was ignored or repaired.
enum TimelineIssueKind {
  duplicatePunch,
  clockInWhileClockedIn,
  breakStartWhileNotWorking,
  breakEndWithoutBreakStart,
  clockOutWhileNotClockedIn,
  clockOutDuringBreak,
  missingClockOut,
}

class TimelineIssue {
  const TimelineIssue(this.kind, this.punchId);

  final TimelineIssueKind kind;

  /// The punch involved, or null for [TimelineIssueKind.missingClockOut].
  final String? punchId;

  @override
  String toString() => 'TimelineIssue(${kind.name}, $punchId)';
}

/// Work and break segments for one worker, built from punches.
class WorkTimeline {
  WorkTimeline._({
    required this.workSegments,
    required this.breakSegments,
    required this.state,
    required this.firstClockIn,
    required this.lastClockOut,
    required this.issues,
  });

  /// Builds the timeline for one worker.
  ///
  /// - Voided punches are ignored. A punch id seen more than once is used once;
  ///   if any copy of it is voided, the punch is ignored.
  /// - Punches are sorted by occurredAt (ties keep list order).
  /// - A clock_in while already clocked in (or on break) is ignored: the first wins.
  /// - break_start when not working, and break_end when not on break, are ignored.
  ///   A break_start with no break kind is treated as a rest break.
  /// - clock_out while on break ends the break at the clock_out.
  /// - No clock_out yet: the last segment stays open until [now] (truncated to the
  ///   minute), or has zero length when [now] is null.
  /// - [shiftId], when given, keeps only punches for that shift.
  ///
  /// Throws [ArgumentError] if the punches belong to more than one worker.
  factory WorkTimeline.fromPunches(List<Punch> punches, {DateTime? now, String? shiftId}) {
    final workerIds = {for (final p in punches) p.workerId};
    if (workerIds.length > 1) {
      throw ArgumentError.value(workerIds.join(', '), 'punches', 'must belong to one worker');
    }

    final issues = <TimelineIssue>[];
    final voidedIds = {
      for (final p in punches)
        if (p.status == PunchStatus.voided) p.id,
    };
    final seen = <String>{};
    final kept = <(int, Punch)>[];
    for (var i = 0; i < punches.length; i++) {
      final p = punches[i];
      if (voidedIds.contains(p.id)) continue;
      if (shiftId != null && p.shiftId != shiftId) continue;
      if (!seen.add(p.id)) {
        issues.add(TimelineIssue(TimelineIssueKind.duplicatePunch, p.id));
        continue;
      }
      kept.add((i, p));
    }
    kept.sort((a, b) {
      final c = a.$2.occurredAt.compareTo(b.$2.occurredAt);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });

    final work = <WorkSegment>[];
    final breaks = <BreakSegment>[];
    var state = TimelineState.notStarted;
    DateTime? segStart;
    BreakKind? breakKind;
    DateTime? firstIn;
    DateTime? lastOut;

    for (final (_, p) in kept) {
      final t = truncateToMinute(p.occurredAt);
      switch (p.kind) {
        case PunchKind.clockIn:
          if (state == TimelineState.working || state == TimelineState.onBreak) {
            issues.add(TimelineIssue(TimelineIssueKind.clockInWhileClockedIn, p.id));
          } else {
            firstIn ??= t;
            segStart = t;
            state = TimelineState.working;
          }
        case PunchKind.breakStart:
          if (state == TimelineState.working) {
            work.add(WorkSegment(start: segStart!, end: t));
            segStart = t;
            breakKind = p.breakKind ?? BreakKind.rest;
            state = TimelineState.onBreak;
          } else {
            issues.add(TimelineIssue(TimelineIssueKind.breakStartWhileNotWorking, p.id));
          }
        case PunchKind.breakEnd:
          if (state == TimelineState.onBreak) {
            breaks.add(BreakSegment(kind: breakKind!, start: segStart!, end: t));
            segStart = t;
            state = TimelineState.working;
          } else {
            issues.add(TimelineIssue(TimelineIssueKind.breakEndWithoutBreakStart, p.id));
          }
        case PunchKind.clockOut:
          if (state == TimelineState.working) {
            work.add(WorkSegment(start: segStart!, end: t));
            lastOut = t;
            state = TimelineState.clockedOut;
          } else if (state == TimelineState.onBreak) {
            issues.add(TimelineIssue(TimelineIssueKind.clockOutDuringBreak, p.id));
            breaks.add(BreakSegment(kind: breakKind!, start: segStart!, end: t));
            lastOut = t;
            state = TimelineState.clockedOut;
          } else {
            issues.add(TimelineIssue(TimelineIssueKind.clockOutWhileNotClockedIn, p.id));
          }
      }
    }

    if (state == TimelineState.working || state == TimelineState.onBreak) {
      issues.add(const TimelineIssue(TimelineIssueKind.missingClockOut, null));
      final start = segStart!;
      final n = now == null ? null : truncateToMinute(now);
      final end = (n != null && n.isAfter(start)) ? n : start;
      if (state == TimelineState.working) {
        work.add(WorkSegment(start: start, end: end, isOpen: true));
      } else {
        breaks.add(BreakSegment(kind: breakKind!, start: start, end: end, isOpen: true));
      }
    }

    return WorkTimeline._(
      workSegments: List.unmodifiable(work),
      breakSegments: List.unmodifiable(breaks),
      state: state,
      firstClockIn: firstIn,
      lastClockOut: lastOut,
      issues: List.unmodifiable(issues),
    );
  }

  final List<WorkSegment> workSegments;
  final List<BreakSegment> breakSegments;
  final TimelineState state;
  final DateTime? firstClockIn;

  /// Time of the last accepted clock_out. If the person clocked back in after it,
  /// [state] is not [TimelineState.clockedOut].
  final DateTime? lastClockOut;

  /// Punches that were ignored or repaired, for manager review.
  final List<TimelineIssue> issues;

  /// True while a segment has no closing punch.
  bool get isOpen => workSegments.any((s) => s.isOpen) || breakSegments.any((s) => s.isOpen);

  /// The break in progress, if any.
  BreakSegment? get currentBreak {
    for (final b in breakSegments) {
      if (b.isOpen) return b;
    }
    return null;
  }

  /// Minutes on the clock, not counting breaks.
  int get workedMinutes => workSegments.fold(0, (sum, s) => sum + s.minutes);

  int get breakMinutes => breakSegments.fold(0, (sum, s) => sum + s.minutes);

  /// Worked minutes (breaks excluded) inside [from, to).
  int workedMinutesBetween(DateTime from, DateTime to) =>
      workSegments.fold(0, (sum, s) => sum + overlapMinutes(s.start, s.end, from, to));

  List<WorkInterval> get workIntervals => [for (final s in workSegments) WorkInterval(s.start, s.end)];

  /// Whether [b] is paid time.
  ///
  /// A break of up to [BreakRules.paidBreakMaxMinutes] is always paid (federal rule).
  /// A longer break is paid only if a rule of its kind is marked paid; with no rule
  /// of its kind, a long rest break is paid and a long meal break is not.
  bool isBreakPaid(BreakSegment b, BreakRules rules) {
    if (b.minutes <= rules.paidBreakMaxMinutes) return true;
    final ofKind = rules.rules.where((r) => BreakKind.fromCode(r.kind) == b.kind);
    if (ofKind.isEmpty) return b.kind == BreakKind.rest;
    return ofKind.any((r) => r.paid);
  }

  /// Break minutes that are paid time under [isBreakPaid].
  int paidBreakMinutes(BreakRules rules) =>
      breakSegments.where((b) => isBreakPaid(b, rules)).fold(0, (sum, b) => sum + b.minutes);

  /// Worked minutes plus paid break minutes.
  int paidMinutes(BreakRules rules) => workedMinutes + paidBreakMinutes(rules);

  /// Work segments plus paid breaks, merged. These are hours worked for overtime,
  /// since paid short breaks count as hours worked under the FLSA.
  List<WorkInterval> paidIntervals(BreakRules rules) => mergeIntervals([
        ...workIntervals,
        for (final b in breakSegments)
          if (isBreakPaid(b, rules)) WorkInterval(b.start, b.end),
      ]);
}
