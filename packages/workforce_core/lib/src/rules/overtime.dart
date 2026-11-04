/// Workweeks and overtime.
///
/// Workweeks start at local midnight of [OvertimeRules.workweekStartDay] in the venue
/// time zone, so a workweek can be 167 or 169 hours long across a DST change.
///
/// Daily and weekly overtime together (no double counting): daily overtime is the
/// minutes over the daily threshold on each local calendar day. Those minutes are
/// left out when counting toward the weekly threshold, and weekly overtime is what
/// remains over the weekly threshold. Days are local calendar days, so a shift that
/// crosses midnight is split between two days. Double time and seventh-day rules are
/// not handled.
library;

import 'local_time.dart';
import 'venue_rules.dart';
import 'work_interval.dart';

/// UTC instant of local midnight on the first day of the workweek containing [instant].
DateTime workweekStart(DateTime instant, String timeZone, int workweekStartDay) {
  if (workweekStartDay < DateTime.monday || workweekStartDay > DateTime.sunday) {
    throw ArgumentError.value(workweekStartDay, 'workweekStartDay', 'must be 1 (Monday) to 7 (Sunday)');
  }
  final date = localDateOf(instant, timeZone);
  final back = (date.weekday - workweekStartDay) % 7;
  return startOfLocalDay(addCalendarDays(date, -back), timeZone);
}

/// Minutes worked on one local calendar day of a workweek.
class DayOvertime {
  const DayOvertime({required this.date, required this.workedMinutes, required this.dailyOvertimeMinutes});

  /// Local calendar date.
  final DateTime date;
  final int workedMinutes;
  final int dailyOvertimeMinutes;
}

/// Regular and overtime minutes for one workweek.
class WorkweekOvertime {
  const WorkweekOvertime({
    required this.weekStart,
    required this.weekEnd,
    required this.days,
    required this.totalMinutes,
    required this.regularMinutes,
    required this.dailyOvertimeMinutes,
    required this.weeklyOvertimeMinutes,
  });

  /// UTC instants; the week is [weekStart, weekEnd).
  final DateTime weekStart;
  final DateTime weekEnd;

  /// The seven local days of the week, in order.
  final List<DayOvertime> days;
  final int totalMinutes;
  final int regularMinutes;
  final int dailyOvertimeMinutes;
  final int weeklyOvertimeMinutes;

  int get overtimeMinutes => dailyOvertimeMinutes + weeklyOvertimeMinutes;
}

/// Overtime for the workweek containing [weekContaining], counting only the parts of
/// [intervals] inside that week. Overlapping intervals are counted once and times
/// are truncated to whole minutes.
WorkweekOvertime overtimeForWeek(
  List<WorkInterval> intervals, {
  required DateTime weekContaining,
  required String timeZone,
  required OvertimeRules rules,
}) {
  final merged = mergeIntervals(intervals);
  final start = workweekStart(weekContaining, timeZone, rules.workweekStartDay);
  final firstDate = localDateOf(start, timeZone);
  final dailyLimit = rules.dailyThresholdHours == null ? null : hoursToMinutes(rules.dailyThresholdHours!);

  final days = <DayOvertime>[];
  for (var i = 0; i < 7; i++) {
    final date = addCalendarDays(firstDate, i);
    final worked =
        minutesWithin(merged, startOfLocalDay(date, timeZone), startOfLocalDay(addCalendarDays(date, 1), timeZone));
    final daily = dailyLimit == null || worked <= dailyLimit ? 0 : worked - dailyLimit;
    days.add(DayOvertime(date: date, workedMinutes: worked, dailyOvertimeMinutes: daily));
  }

  final total = days.fold(0, (s, d) => s + d.workedMinutes);
  final dailyOt = days.fold(0, (s, d) => s + d.dailyOvertimeMinutes);
  final weeklyLimit = hoursToMinutes(rules.weeklyThresholdHours);
  final towardWeekly = total - dailyOt;
  final weeklyOt = towardWeekly > weeklyLimit ? towardWeekly - weeklyLimit : 0;

  return WorkweekOvertime(
    weekStart: start,
    weekEnd: startOfLocalDay(addCalendarDays(firstDate, 7), timeZone),
    days: List.unmodifiable(days),
    totalMinutes: total,
    regularMinutes: total - dailyOt - weeklyOt,
    dailyOvertimeMinutes: dailyOt,
    weeklyOvertimeMinutes: weeklyOt,
  );
}

/// Overtime for every workweek touched by [intervals], in date order. Intervals
/// that cross a workweek boundary are split between the weeks.
List<WorkweekOvertime> splitOvertime(
  List<WorkInterval> intervals, {
  required String timeZone,
  required OvertimeRules rules,
}) {
  final merged = mergeIntervals(intervals);
  final weekStarts = <DateTime>{};
  for (final i in merged) {
    var ws = workweekStart(i.start, timeZone, rules.workweekStartDay);
    while (ws.isBefore(i.end)) {
      weekStarts.add(ws);
      ws = startOfLocalDay(addCalendarDays(localDateOf(ws, timeZone), 7), timeZone);
    }
  }
  final sorted = weekStarts.toList()..sort();
  return [
    for (final ws in sorted) overtimeForWeek(merged, weekContaining: ws, timeZone: timeZone, rules: rules),
  ];
}

/// Overtime warning for the live view.
class OvertimeOutlook {
  const OvertimeOutlook({
    required this.minutesUntilOvertime,
    required this.inOvertime,
    required this.approaching,
    required this.overtimeMinutesSoFar,
    this.projectedOvertimeMinutes,
  });

  /// Minutes of work left before overtime starts (0 when at or past it).
  final int minutesUntilOvertime;

  /// Already past a threshold.
  final bool inOvertime;

  /// Not in overtime but within [OvertimeRules.warnWithinHours] of it.
  final bool approaching;
  final int overtimeMinutesSoFar;

  /// Total overtime minutes if the person works without pause until the scheduled
  /// end. Null when no scheduled end is known.
  final int? projectedOvertimeMinutes;
}

/// Live overtime outlook from minutes already worked this workweek (up to [now]).
///
/// [workedMinutesTodayBeforeNow] is used only when the rules have a daily threshold.
/// This is an estimate for warnings; payroll uses [splitOvertime]. The projection
/// assumes work continues without unpaid breaks until [scheduledEnd], and with both
/// thresholds it takes the larger of the daily and weekly figures.
OvertimeOutlook overtimeOutlook({
  required int workedMinutesThisWeekBeforeNow,
  required DateTime now,
  DateTime? scheduledEnd,
  required OvertimeRules rules,
  int? workedMinutesTodayBeforeNow,
}) {
  final week = workedMinutesThisWeekBeforeNow;
  final weekLimit = hoursToMinutes(rules.weeklyThresholdHours);
  final today = workedMinutesTodayBeforeNow;
  final dayLimit = rules.dailyThresholdHours == null ? null : hoursToMinutes(rules.dailyThresholdHours!);
  final useDaily = today != null && dayLimit != null;

  int over(int worked, int limit) => worked > limit ? worked - limit : 0;
  int left(int worked, int limit) => worked < limit ? limit - worked : 0;

  var until = left(week, weekLimit);
  var soFar = over(week, weekLimit);
  var inOt = week > weekLimit;
  if (useDaily) {
    final dUntil = left(today, dayLimit);
    if (dUntil < until) until = dUntil;
    final dOver = over(today, dayLimit);
    if (dOver > soFar) soFar = dOver;
    inOt = inOt || today > dayLimit;
  }

  int? projected;
  if (scheduledEnd != null) {
    final n = truncateToMinute(now);
    final end = truncateToMinute(scheduledEnd);
    final remaining = end.isAfter(n) ? end.difference(n).inMinutes : 0;
    projected = over(week + remaining, weekLimit);
    if (useDaily) {
      final d = over(today + remaining, dayLimit);
      if (d > projected) projected = d;
    }
  }

  return OvertimeOutlook(
    minutesUntilOvertime: until,
    inOvertime: inOt,
    approaching: !inOt && until <= hoursToMinutes(rules.warnWithinHours),
    overtimeMinutesSoFar: soFar,
    projectedOvertimeMinutes: projected,
  );
}
