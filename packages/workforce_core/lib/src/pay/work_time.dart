/// Turns one person's punches into paid time attributed to shifts, split at local
/// midnight, with overtime minutes marked. Shared by payroll, agency billing, NPO
/// payouts, tip pools, and labor cost so they all count time the same way.
///
/// Attribution: each punch belongs to
///   1. the shift named by its shift_id, when that shift is one of the person's shifts;
///   2. else the person's shift at the punch's event (assigned or released shifts
///      first, then earliest call time, then shift id);
///   3. else the event with the person's default role (reported as noShiftForEvent);
///   4. punches with no event go to the default role with no event.
/// Each group is run through [WorkTimeline] separately and its paid intervals
/// ([WorkTimeline.paidIntervals]: work plus paid short breaks; unpaid meals excluded)
/// are the hours worked. The shift's final storefront and job role are used for all of
/// its time (mid-event moves are not split).
///
/// Overtime minutes are the LAST minutes worked, chronologically: for daily overtime,
/// the last minutes of each local day past the daily threshold; for weekly overtime,
/// the last remaining minutes of the workweek past the weekly threshold. The minute
/// counts come from [overtimeForWeek].
library;

import '../model/entities.dart';
import '../model/enums.dart';
import '../rules/local_time.dart';
import '../rules/overtime.dart';
import '../rules/timeline.dart';
import '../rules/venue_rules.dart';
import '../rules/work_interval.dart';
import 'pay_problem.dart';

/// What a stretch of work is paid as.
class WorkContext {
  const WorkContext({this.eventId, this.storefrontId, this.jobRoleCode, this.eventTypeCode, this.shiftId});

  final String? eventId;
  final String? storefrontId;
  final String? jobRoleCode;
  final String? eventTypeCode;
  final String? shiftId;

  /// Identifies the attribution group (one per shift, or per event, or no event).
  String get key => shiftId != null ? 's:$shiftId' : (eventId != null ? 'e:$eventId' : 'none');

  @override
  bool operator ==(Object other) =>
      other is WorkContext &&
      other.eventId == eventId &&
      other.storefrontId == storefrontId &&
      other.jobRoleCode == jobRoleCode &&
      other.eventTypeCode == eventTypeCode &&
      other.shiftId == shiftId;

  @override
  int get hashCode => Object.hash(eventId, storefrontId, jobRoleCode, eventTypeCode, shiftId);
}

/// A stretch of paid time on one local calendar day, all in one context.
class WorkPiece {
  const WorkPiece({
    required this.workerId,
    required this.start,
    required this.end,
    required this.date,
    required this.context,
    this.overtime = false,
  });

  final String workerId;

  /// UTC instants, whole minutes.
  final DateTime start;
  final DateTime end;

  /// Venue-local calendar date (the piece never crosses local midnight).
  final DateTime date;
  final WorkContext context;
  final bool overtime;

  int get minutes => end.difference(start).inMinutes;

  WorkPiece _copy({DateTime? start, DateTime? end, bool? overtime}) => WorkPiece(
        workerId: workerId,
        start: start ?? this.start,
        end: end ?? this.end,
        date: date,
        context: context,
        overtime: overtime ?? this.overtime,
      );

  @override
  String toString() => 'WorkPiece(${formatDate(date)} ${start.toIso8601String()}..${end.toIso8601String()} '
      '${context.jobRoleCode}${overtime ? ' OT' : ''})';
}

/// One attribution group: the punches of one shift (or event, or no event).
class WorkGroup {
  const WorkGroup({required this.context, required this.timeline, required this.paidMinutes, required this.punches});

  final WorkContext context;
  final WorkTimeline timeline;

  /// Paid minutes of this group before any overlap with other groups is removed.
  final int paidMinutes;
  final List<Punch> punches;

  /// True when at least one non-voided clock-in exists.
  bool get clockedIn => timeline.firstClockIn != null;
}

class WorkerWork {
  const WorkerWork({required this.workerId, required this.pieces, required this.groups, required this.problems});

  final String workerId;

  /// Chronological, non-overlapping, each within one local day.
  final List<WorkPiece> pieces;
  final List<WorkGroup> groups;
  final List<PayProblem> problems;

  int get totalMinutes => pieces.fold(0, (s, p) => s + p.minutes);

  /// Minutes per context key.
  int minutesFor(bool Function(WorkContext c) test) =>
      pieces.where((p) => test(p.context)).fold(0, (s, p) => s + p.minutes);
}

int _shiftPreference(Shift s) =>
    (s.status == ShiftStatus.assigned || s.status == ShiftStatus.released) ? 0 : 1;

/// Attributes one person's punches to their shifts and returns paid pieces.
///
/// [punches] may include every status; voided punches are ignored by the timeline.
/// [shifts] are this person's shifts (others are ignored). [events] gives each event's
/// type. Open clock-ins are not paid (no `now` is used): the stretch after the last
/// closing punch is reported as [PayProblemKind.openClockIn].
WorkerWork attributeWork({
  required String workerId,
  required List<Punch> punches,
  required List<Shift> shifts,
  required Map<String, Event> events,
  required String timeZone,
  required BreakRules breakRules,
  String? defaultJobRoleCode,
}) {
  final problems = <PayProblem>[];
  final mine = [
    for (final s in shifts)
      if (s.workerId == workerId) s,
  ];
  final byId = {for (final s in mine) s.id: s};
  final byEvent = <String, List<Shift>>{};
  for (final s in mine) {
    byEvent.putIfAbsent(s.eventId, () => []).add(s);
  }
  for (final list in byEvent.values) {
    list.sort((a, b) {
      var c = _shiftPreference(a).compareTo(_shiftPreference(b));
      if (c != 0) return c;
      c = a.callTime.compareTo(b.callTime);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
  }

  final reportedUnknownEvents = <String>{};
  WorkContext contextFor(String? eventId, Shift? shift) {
    final evId = shift?.eventId ?? eventId;
    final ev = evId == null ? null : events[evId];
    if (evId != null && ev == null && reportedUnknownEvents.add(evId)) {
      problems.add(PayProblem(
        kind: PayProblemKind.unknownEvent,
        severity: PayProblemSeverity.blocking,
        message: 'Event $evId was not loaded, so its event type (and any event-type rate) is unknown.',
        workerId: workerId,
        eventId: evId,
      ));
    }
    return WorkContext(
      eventId: evId,
      storefrontId: shift?.storefrontId,
      jobRoleCode: shift?.jobRoleCode ?? defaultJobRoleCode,
      eventTypeCode: ev?.eventTypeCode,
      shiftId: shift?.id,
    );
  }

  final groupPunches = <String, List<Punch>>{};
  final groupContext = <String, WorkContext>{};
  for (final p in punches) {
    if (p.workerId != workerId) continue;
    Shift? shift;
    if (p.shiftId != null && byId.containsKey(p.shiftId)) {
      shift = byId[p.shiftId];
    } else if (p.eventId != null && (byEvent[p.eventId]?.isNotEmpty ?? false)) {
      shift = byEvent[p.eventId]!.first;
    }
    final ctx = contextFor(p.eventId, shift);
    groupContext.putIfAbsent(ctx.key, () => ctx);
    groupPunches.putIfAbsent(ctx.key, () => []).add(p);
  }

  final groups = <WorkGroup>[];
  final tagged = <(WorkInterval, int)>[];
  for (final key in groupPunches.keys) {
    final ps = groupPunches[key]!;
    final ctx = groupContext[key]!;
    final tl = WorkTimeline.fromPunches(ps);
    final intervals = tl.paidIntervals(breakRules);
    final paid = intervals.fold(0, (s, i) => s + i.minutes);
    final hasAccepted = ps.any((p) => p.status != PunchStatus.voided);
    if (ctx.shiftId == null && ctx.eventId != null && hasAccepted) {
      problems.add(PayProblem(
        kind: PayProblemKind.noShiftForEvent,
        severity: PayProblemSeverity.warning,
        message: 'Punches at event ${ctx.eventId} with no shift; paid as ${ctx.jobRoleCode ?? 'no role'}.',
        workerId: workerId,
        eventId: ctx.eventId,
      ));
    }
    if (ctx.jobRoleCode == null && hasAccepted) {
      problems.add(PayProblem(
        kind: PayProblemKind.noJobRole,
        severity: PayProblemSeverity.warning,
        message: 'Punches with no shift and no default job role.',
        workerId: workerId,
        eventId: ctx.eventId,
      ));
    }
    for (final issue in tl.issues) {
      switch (issue.kind) {
        case TimelineIssueKind.duplicatePunch:
          break; // The same punch sent twice (offline sync); counted once, nothing to fix.
        case TimelineIssueKind.missingClockOut:
          problems.add(PayProblem(
            kind: PayProblemKind.openClockIn,
            severity: PayProblemSeverity.blocking,
            message: 'Clocked in with no clock-out. Time after the last closing punch is not paid until corrected.',
            workerId: workerId,
            eventId: ctx.eventId,
            shiftId: ctx.shiftId,
          ));
        default:
          problems.add(PayProblem(
            kind: PayProblemKind.punchIgnored,
            severity: PayProblemSeverity.warning,
            message: 'Punch ignored: ${issue.kind.name}.',
            workerId: workerId,
            eventId: ctx.eventId,
            shiftId: ctx.shiftId,
            punchId: issue.punchId,
          ));
      }
    }
    final voided = {
      for (final p in ps)
        if (p.status == PunchStatus.voided) p.id,
    };
    final reviewed = <String>{};
    for (final p in ps) {
      if (p.status == PunchStatus.needsReview && !voided.contains(p.id) && reviewed.add(p.id)) {
        problems.add(PayProblem(
          kind: PayProblemKind.punchNeedsReview,
          severity: PayProblemSeverity.blocking,
          message: 'Punch needs review; counted as recorded.',
          workerId: workerId,
          eventId: ctx.eventId,
          shiftId: ctx.shiftId,
          punchId: p.id,
        ));
      }
    }
    final index = groups.length;
    groups.add(WorkGroup(context: ctx, timeline: tl, paidMinutes: paid, punches: ps));
    for (final i in intervals) {
      tagged.add((i, index));
    }
  }

  // Remove time clocked under two groups at once: the earlier-starting interval keeps it.
  tagged.sort((a, b) {
    final c = a.$1.start.compareTo(b.$1.start);
    return c != 0 ? c : a.$2.compareTo(b.$2);
  });
  final kept = <(WorkInterval, int)>[];
  DateTime? coveredUntil;
  var overlap = 0;
  for (final (iv, g) in tagged) {
    var s = iv.start;
    if (coveredUntil != null && coveredUntil.isAfter(s)) {
      s = coveredUntil.isBefore(iv.end) ? coveredUntil : iv.end;
      overlap += s.difference(iv.start).inMinutes;
    }
    if (iv.end.isAfter(s)) kept.add((WorkInterval(s, iv.end), g));
    if (coveredUntil == null || iv.end.isAfter(coveredUntil)) coveredUntil = iv.end;
  }
  if (overlap > 0) {
    problems.add(PayProblem(
      kind: PayProblemKind.overlappingTime,
      severity: PayProblemSeverity.blocking,
      message: '$overlap minutes were clocked under two shifts at once; paid once, under the earlier shift.',
      workerId: workerId,
    ));
  }

  final pieces = <WorkPiece>[];
  for (final (iv, g) in kept) {
    var s = iv.start;
    while (s.isBefore(iv.end)) {
      final date = localDateOf(s, timeZone);
      final midnight = startOfLocalDay(addCalendarDays(date, 1), timeZone);
      final e = midnight.isBefore(iv.end) ? midnight : iv.end;
      pieces.add(WorkPiece(workerId: workerId, start: s, end: e, date: date, context: groups[g].context));
      s = e;
    }
  }
  pieces.sort((a, b) => a.start.compareTo(b.start));
  return WorkerWork(
    workerId: workerId,
    pieces: List.unmodifiable(pieces),
    groups: List.unmodifiable(groups),
    problems: problems,
  );
}

/// One workweek of pieces with overtime marked.
class WorkweekPieces {
  const WorkweekPieces({required this.weekStart, required this.firstDate, required this.overtime, required this.pieces});

  /// UTC instant of local midnight starting the week.
  final DateTime weekStart;

  /// Local date of the first day of the week.
  final DateTime firstDate;
  final WorkweekOvertime overtime;

  /// Chronological. Pieces that straddle the overtime point are split in two.
  final List<WorkPiece> pieces;

  DateTime get lastDate => addCalendarDays(firstDate, 6);
  int get totalMinutes => overtime.totalMinutes;
  int get overtimeMinutes => overtime.overtimeMinutes;
}

/// Groups [pieces] (from [attributeWork]) into workweeks and marks the last minutes
/// as overtime per [rules]. Weeks are in date order.
List<WorkweekPieces> markOvertime(List<WorkPiece> pieces, {required String timeZone, required OvertimeRules rules}) {
  final byWeek = <DateTime, List<WorkPiece>>{};
  for (final p in pieces) {
    byWeek.putIfAbsent(workweekStart(p.start, timeZone, rules.workweekStartDay), () => []).add(p);
  }
  final starts = byWeek.keys.toList()..sort();
  final out = <WorkweekPieces>[];
  for (final ws in starts) {
    final ps = [...byWeek[ws]!]..sort((a, b) => a.start.compareTo(b.start));
    final ot = overtimeForWeek([for (final p in ps) WorkInterval(p.start, p.end)],
        weekContaining: ws, timeZone: timeZone, rules: rules);
    final sum = ps.fold(0, (s, p) => s + p.minutes);
    if (sum != ot.totalMinutes) {
      throw StateError('Workweek minutes do not reconcile: pieces $sum, overtime ${ot.totalMinutes}');
    }

    void markLast(bool Function(WorkPiece) eligible, int minutes) {
      var left = minutes;
      for (var i = ps.length - 1; i >= 0 && left > 0; i--) {
        final p = ps[i];
        if (p.overtime || !eligible(p)) continue;
        if (p.minutes <= left) {
          ps[i] = p._copy(overtime: true);
          left -= p.minutes;
        } else {
          final cut = p.end.subtract(Duration(minutes: left));
          ps.replaceRange(i, i + 1, [p._copy(end: cut), p._copy(start: cut, overtime: true)]);
          left = 0;
        }
      }
      if (left != 0) throw StateError('Could not place $minutes overtime minutes');
    }

    for (final day in ot.days) {
      if (day.dailyOvertimeMinutes > 0) markLast((p) => p.date == day.date, day.dailyOvertimeMinutes);
    }
    if (ot.weeklyOvertimeMinutes > 0) markLast((_) => true, ot.weeklyOvertimeMinutes);

    out.add(WorkweekPieces(
      weekStart: ws,
      firstDate: localDateOf(ws, timeZone),
      overtime: ot,
      pieces: List.unmodifiable(ps),
    ));
  }
  return out;
}
