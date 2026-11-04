/// What happened with each assigned shift, for reports and reliability: on time, late,
/// no-show, call-off, sent home before arriving, or not decided yet.
///
/// One definition shared by the KPI reports and the reliability score, so the two
/// always agree.
///
/// - **On time / late**: from the first clock-in at the event, with the venue's grace
///   minutes ([evaluateAttendance]).
/// - **No-show**: still assigned, never clocked in, and more than the venue's no-show
///   minutes past call time.
/// - **Call-off**: a manager removed the person from a position at the event within
///   [callOffWindow] before call time (default 48 hours), and they did not work that
///   event in another position. Approved self-service changes (drops, swaps, pickups)
///   are not call-offs: the employee asked ahead and a manager agreed.
/// - **Released**: sent home before clocking in. Not counted for or against anyone.
/// - **Pending**: call time plus the no-show minutes has not passed yet.
library;

import '../model/entities.dart';
import '../model/enums.dart';
import 'attendance.dart';
import 'timeline.dart';
import 'venue_rules.dart';

enum AttendanceOutcome {
  onTime,
  late,
  noShow,
  callOff,
  released,
  pending;

  /// Counts toward attendance rates (the person was expected and the result is known).
  bool get counts => this == onTime || this == late || this == noShow || this == callOff;
}

class ShiftOutcome {
  const ShiftOutcome({
    required this.workerId,
    required this.eventId,
    required this.storefrontId,
    required this.jobRoleCode,
    required this.callTime,
    required this.outcome,
    this.shiftId,
    this.minutesLate = 0,
  });

  final String workerId;
  final String eventId;
  final String storefrontId;
  final String jobRoleCode;
  final DateTime callTime;
  final AttendanceOutcome outcome;

  /// The shift, or for a call-off the position they were removed from.
  final String? shiftId;

  /// For [AttendanceOutcome.late]: minutes after call time.
  final int minutesLate;
}

/// Reasons written by approved self-service requests (0012 decide_shift_request).
const selfServiceReasonPrefixes = ['Drop approved', 'Swap approved', 'Pickup approved', 'Picked up by employee'];

bool isSelfServiceChange(String reason) => selfServiceReasonPrefixes.any(reason.startsWith);

/// One outcome per person and event they were scheduled for.
///
/// [shifts] should hold every shift of the events in question (any status), [punches]
/// the punches at those events, and [changes] their assignment changes. Voided punches
/// are ignored.
List<ShiftOutcome> attendanceOutcomes({
  required List<Shift> shifts,
  required List<Punch> punches,
  required List<AssignmentChange> changes,
  required AttendanceRules rules,
  required DateTime now,
  Duration callOffWindow = const Duration(hours: 48),
}) {
  final byWorkerEvent = <String, List<Punch>>{};
  for (final p in punches) {
    if (p.status == PunchStatus.voided || p.eventId == null) continue;
    byWorkerEvent.putIfAbsent('${p.workerId}|${p.eventId}', () => []).add(p);
  }
  final shiftById = {for (final s in shifts) s.id: s};
  final out = <ShiftOutcome>[];
  final worked = <String>{};

  for (final s in shifts) {
    final w = s.workerId;
    if (w == null) continue;
    if (s.status != ShiftStatus.assigned && s.status != ShiftStatus.released) continue;
    final key = '$w|${s.eventId}';
    // One outcome per person and event, even with two positions on file.
    if (!worked.add(key)) continue;
    final ps = byWorkerEvent[key] ?? const <Punch>[];
    final timeline = WorkTimeline.fromPunches(ps, now: now);
    final a = evaluateAttendance(callTime: s.callTime, timeline: timeline, rules: rules, now: now);
    final AttendanceOutcome outcome;
    if (a.clockedInAt != null) {
      outcome = a.status == AttendanceStatus.late ? AttendanceOutcome.late : AttendanceOutcome.onTime;
    } else if (s.status == ShiftStatus.released) {
      outcome = AttendanceOutcome.released;
    } else if (a.status == AttendanceStatus.noShow) {
      outcome = AttendanceOutcome.noShow;
    } else {
      outcome = AttendanceOutcome.pending;
    }
    out.add(ShiftOutcome(
      workerId: w,
      eventId: s.eventId,
      storefrontId: s.storefrontId,
      jobRoleCode: s.jobRoleCode,
      callTime: s.callTime,
      outcome: outcome,
      shiftId: s.id,
      minutesLate: outcome == AttendanceOutcome.late ? a.minutesLate : 0,
    ));
  }

  // Call-offs: removed by a manager close to call time, and not working the event anyway.
  final calledOff = <String>{};
  final sorted = [...changes]..sort((a, b) => a.changedAt.compareTo(b.changedAt));
  for (final c in sorted) {
    final w = c.workerId;
    if (c.action != 'unassigned' || w == null) continue;
    if (isSelfServiceChange(c.reason)) continue;
    final s = shiftById[c.shiftId];
    if (s == null) continue;
    final key = '$w|${c.eventId}';
    if (worked.contains(key) || !calledOff.add(key)) continue;
    if (c.changedAt.isBefore(s.callTime.subtract(callOffWindow))) {
      calledOff.remove(key);
      continue;
    }
    out.add(ShiftOutcome(
      workerId: w,
      eventId: c.eventId,
      storefrontId: c.fromStorefrontId ?? s.storefrontId,
      jobRoleCode: c.fromJobRoleCode ?? s.jobRoleCode,
      callTime: s.callTime,
      outcome: AttendanceOutcome.callOff,
      shiftId: s.id,
    ));
  }
  return out;
}

/// Counts of each outcome, and the on-time rate among outcomes that count.
class AttendanceSummary {
  AttendanceSummary(Iterable<ShiftOutcome> outcomes) {
    for (final o in outcomes) {
      counts[o.outcome] = (counts[o.outcome] ?? 0) + 1;
      if (o.outcome == AttendanceOutcome.late) totalMinutesLate += o.minutesLate;
    }
  }

  final Map<AttendanceOutcome, int> counts = {};
  int totalMinutesLate = 0;

  int of(AttendanceOutcome o) => counts[o] ?? 0;
  int get onTime => of(AttendanceOutcome.onTime);
  int get late => of(AttendanceOutcome.late);
  int get noShows => of(AttendanceOutcome.noShow);
  int get callOffs => of(AttendanceOutcome.callOff);

  /// Shifts with a known result that the person was expected at.
  int get expected => onTime + late + noShows + callOffs;

  /// Showed up on time, out of everyone expected. Null with nothing to measure.
  double? get onTimeRate => expected == 0 ? null : onTime / expected;

  /// Showed up at all (on time or late), out of everyone expected.
  double? get attendanceRate => expected == 0 ? null : (onTime + late) / expected;
}
