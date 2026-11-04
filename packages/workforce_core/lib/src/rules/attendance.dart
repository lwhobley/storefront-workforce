/// Lateness and no-show rules.
///
/// All comparisons use whole minutes (seconds truncated), so with a 5-minute grace a
/// clock-in at 18:05:59 for an 18:00 call is on time and 18:06:00 is 6 minutes late.
library;

import 'local_time.dart';
import 'timeline.dart';
import 'venue_rules.dart';

enum AttendanceStatus {
  /// Not clocked in, and call time plus grace has not passed yet.
  upcoming,

  /// Clocked in no later than call time plus grace.
  onTime,

  /// Clocked in more than the grace minutes after call time.
  late,

  /// Not clocked in, more than grace minutes past call, not yet a no-show.
  notArrived,

  /// Not clocked in, more than the no-show minutes past call.
  noShow,

  /// The shift was released (sent home or let go before arriving).
  released,
}

class AttendanceResult {
  const AttendanceResult({required this.status, this.minutesLate = 0, this.clockedInAt, this.minutesPastCall = 0});

  final AttendanceStatus status;

  /// Clock-in minus call time, when that is more than the grace. Otherwise 0.
  /// Also filled for a released shift if the person had clocked in late.
  final int minutesLate;
  final DateTime? clockedInAt;

  /// Minutes from call time to now, 0 before call.
  final int minutesPastCall;
}

/// Attendance for one shift as of [now].
///
/// Boundaries: late only when clock-in minus call is more than
/// [AttendanceRules.lateGraceMinutes]; no-show only when now minus call is more than
/// [AttendanceRules.noShowAfterMinutes]. A clock-in before call time is on time.
AttendanceResult evaluateAttendance({
  required DateTime callTime,
  required WorkTimeline timeline,
  required AttendanceRules rules,
  required DateTime now,
  bool released = false,
}) {
  final call = truncateToMinute(callTime);
  final n = truncateToMinute(now);
  final pastCall = n.isAfter(call) ? n.difference(call).inMinutes : 0;
  final inAt = timeline.firstClockIn;

  var minutesLate = 0;
  if (inAt != null) {
    final diff = inAt.difference(call).inMinutes;
    if (diff > rules.lateGraceMinutes) minutesLate = diff;
  }

  AttendanceStatus status;
  if (released) {
    status = AttendanceStatus.released;
  } else if (inAt != null) {
    status = minutesLate > 0 ? AttendanceStatus.late : AttendanceStatus.onTime;
  } else if (pastCall > rules.noShowAfterMinutes) {
    status = AttendanceStatus.noShow;
  } else if (pastCall > rules.lateGraceMinutes) {
    status = AttendanceStatus.notArrived;
  } else {
    status = AttendanceStatus.upcoming;
  }
  return AttendanceResult(status: status, minutesLate: minutesLate, clockedInAt: inAt, minutesPastCall: pastCall);
}

/// Earliest instant someone may clock in for [callTime].
DateTime earliestClockIn(DateTime callTime, AttendanceRules rules) =>
    truncateToMinute(callTime).subtract(Duration(minutes: rules.earlyClockInMinutes));

/// Whether a clock-in at [now] is allowed: no earlier than
/// [AttendanceRules.earlyClockInMinutes] before call. There is no latest time.
bool canClockIn(DateTime callTime, DateTime now, AttendanceRules rules) =>
    !truncateToMinute(now).isBefore(earliestClockIn(callTime, rules));
