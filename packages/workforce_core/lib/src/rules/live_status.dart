/// Per-shift card for the live event board.
library;

import '../model/entities.dart';
import '../model/enums.dart';
import 'attendance.dart';
import 'breaks.dart';
import 'local_time.dart';
import 'overtime.dart';
import 'timeline.dart';
import 'venue_rules.dart';
import 'work_interval.dart';

/// One state per card, for the map color. When several apply, the first in this
/// list wins:
///
/// 1. [cancelled]: the shift is cancelled.
/// 2. [openPosition]: no worker assigned.
/// 3. [released]: the shift was released, whatever the punches say.
/// 4. [noShow]: never clocked in, more than the no-show minutes past call.
/// 5. [notArrived]: not clocked in, past call plus grace.
/// 6. [late]: clocked in after the grace period and working now.
///    (A late arrival on break or clocked out shows [onBreak] or [clockedOut];
///    lateness is still in [LiveShiftStatus.attendance].)
/// 7. [onBreak]
/// 8. [working]
/// 9. [clockedOut]
/// 10. [upcoming]: not clocked in, call plus grace not yet passed.
enum LiveHeadline {
  cancelled,
  openPosition,
  released,
  noShow,
  notArrived,
  late,
  onBreak,
  working,
  clockedOut,
  upcoming,
}

class LiveShiftStatus {
  const LiveShiftStatus({
    required this.shift,
    required this.worker,
    required this.headline,
    required this.attendance,
    required this.timeline,
    required this.breaks,
    required this.overtime,
    required this.age,
    required this.isMinor,
    required this.paidMinutes,
  });

  final Shift shift;
  final Worker? worker;
  final LiveHeadline headline;
  final AttendanceResult attendance;
  final WorkTimeline timeline;
  final BreakEvaluation breaks;
  final OvertimeOutlook overtime;

  /// `ageOnEvent` if given, else age from the birth date on the call time's local
  /// date. Null when unknown.
  final int? age;
  final bool isMinor;

  /// Worked minutes plus paid breaks at this event.
  final int paidMinutes;

  TimelineState get state => timeline.state;

  /// Worked minutes at this event, breaks excluded.
  int get workedMinutes => timeline.workedMinutes;

  bool get needsBreakAttention => breaks.needsAttention;
}

/// Builds the live card for [shift] as of [now].
///
/// [punches] should be this worker's punches for this event; punches for other
/// workers are ignored. [workedMinutesThisWeekBeforeEvent] is time already worked in
/// the workweek containing [now], before this event. Hours toward overtime include
/// paid breaks.
///
/// [ageOnEvent], when given, is used as the age and wins over the worker's birth
/// date (the live board gets ages, not birth dates). Otherwise the age comes from
/// [Worker.dateOfBirth] on the local date of the call time.
LiveShiftStatus evaluateLiveShift({
  required Shift shift,
  Worker? worker,
  required List<Punch> punches,
  required VenueRules rules,
  required String timeZone,
  required DateTime now,
  int workedMinutesThisWeekBeforeEvent = 0,
  int? ageOnEvent,
}) {
  final mine = shift.workerId == null ? const <Punch>[] : [for (final p in punches) if (p.workerId == shift.workerId) p];
  final timeline = WorkTimeline.fromPunches(mine, now: now);
  final released = shift.status == ShiftStatus.released;
  final attendance = evaluateAttendance(
    callTime: shift.callTime,
    timeline: timeline,
    rules: rules.attendance,
    now: now,
    released: released,
  );

  final age = ageOnEvent ?? worker?.ageOn(localDateOf(shift.callTime, timeZone));
  final isMinor = age != null && age < rules.minors.adultAge;
  final breaks = evaluateBreaks(
    timeline: timeline,
    rules: rules.breaks,
    age: age,
    adultAge: rules.minors.adultAge,
    now: now,
  );

  // Overtime: this event's paid time inside the current workweek (and day).
  final paid = timeline.paidIntervals(rules.breaks);
  final ws = workweekStart(now, timeZone, rules.overtime.workweekStartDay);
  final we = startOfLocalDay(addCalendarDays(localDateOf(ws, timeZone), 7), timeZone);
  final today = localDateOf(now, timeZone);
  final todayMinutes = rules.overtime.dailyThresholdHours == null
      ? null
      : minutesWithin(paid, startOfLocalDay(today, timeZone), startOfLocalDay(addCalendarDays(today, 1), timeZone));
  final done = released || timeline.state == TimelineState.clockedOut;
  // Projection runs from call time if the person has not started yet.
  final projectFrom = timeline.state == TimelineState.notStarted && shift.callTime.isAfter(now) ? shift.callTime : now;
  final overtime = overtimeOutlook(
    workedMinutesThisWeekBeforeNow: workedMinutesThisWeekBeforeEvent + minutesWithin(paid, ws, we),
    workedMinutesTodayBeforeNow: todayMinutes,
    now: projectFrom,
    scheduledEnd: done ? projectFrom : shift.scheduledEnd,
    rules: rules.overtime,
  );

  return LiveShiftStatus(
    shift: shift,
    worker: worker,
    headline: _headline(shift, attendance, timeline),
    attendance: attendance,
    timeline: timeline,
    breaks: breaks,
    overtime: overtime,
    age: age,
    isMinor: isMinor,
    paidMinutes: timeline.paidMinutes(rules.breaks),
  );
}

LiveHeadline _headline(Shift shift, AttendanceResult attendance, WorkTimeline timeline) {
  if (shift.status == ShiftStatus.cancelled) return LiveHeadline.cancelled;
  if (shift.workerId == null) return LiveHeadline.openPosition;
  if (attendance.status == AttendanceStatus.released) return LiveHeadline.released;
  if (attendance.status == AttendanceStatus.noShow) return LiveHeadline.noShow;
  if (attendance.status == AttendanceStatus.notArrived) return LiveHeadline.notArrived;
  switch (timeline.state) {
    case TimelineState.working:
      return attendance.status == AttendanceStatus.late ? LiveHeadline.late : LiveHeadline.working;
    case TimelineState.onBreak:
      return LiveHeadline.onBreak;
    case TimelineState.clockedOut:
      return LiveHeadline.clockedOut;
    case TimelineState.notStarted:
      return LiveHeadline.upcoming;
  }
}
