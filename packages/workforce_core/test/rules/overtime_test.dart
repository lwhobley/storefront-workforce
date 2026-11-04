import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

import 'helpers.dart';

void main() {
  const weekly = OvertimeRules(); // 40h weekly, Monday start, warn within 4h.
  const daily8 = OvertimeRules(dailyThresholdHours: 8);

  /// One shift per day from [firstDay], [hours] long, starting 09:00 local.
  List<WorkInterval> days(DateTime firstDay, int count, int hours, {int extraMinutesLastDay = 0}) => [
        for (var i = 0; i < count; i++)
          iv(
            ct(firstDay.year, firstDay.month, firstDay.day + i, 9),
            ct(firstDay.year, firstDay.month, firstDay.day + i, 9 + hours)
                .add(Duration(minutes: i == count - 1 ? extraMinutesLastDay : 0)),
          ),
      ];

  group('workweekStart', () {
    test('Wednesday goes back to Monday local midnight', () {
      final ws = workweekStart(ct(2026, 11, 4, 12), chicago, DateTime.monday);
      expect(ws, ct(2026, 11, 2));
      expect(ws, DateTime.utc(2026, 11, 2, 6)); // CST is UTC-6.
      expect(ws.isUtc, isTrue);
    });

    test('Monday 00:00 is its own week start; Sunday 23:59 is the previous week', () {
      expect(workweekStart(ct(2026, 11, 2), chicago, DateTime.monday), ct(2026, 11, 2));
      expect(workweekStart(ct(2026, 11, 8, 23, 59), chicago, DateTime.monday), ct(2026, 11, 2));
      expect(workweekStart(ct(2026, 11, 9), chicago, DateTime.monday), ct(2026, 11, 9));
    });

    test('uses the local date, not the UTC date', () {
      // Sunday 20:00 CST is Monday 02:00 UTC, but still the previous workweek.
      final sundayNight = ct(2026, 11, 8, 20);
      expect(sundayNight.weekday, DateTime.monday);
      expect(workweekStart(sundayNight, chicago, DateTime.monday), ct(2026, 11, 2));
    });

    test('Sunday start day', () {
      expect(workweekStart(ct(2026, 11, 4, 12), chicago, DateTime.sunday), ct(2026, 11, 1));
      expect(workweekStart(ct(2026, 11, 1, 0, 30), chicago, DateTime.sunday), ct(2026, 11, 1));
    });

    test('fall-back week starts at midnight CDT and is 169 hours', () {
      final ws = workweekStart(ct(2026, 11, 1, 12), chicago, DateTime.monday);
      expect(ws, DateTime.utc(2026, 10, 26, 5));
      final next = workweekStart(ct(2026, 11, 2, 12), chicago, DateTime.monday);
      expect(next, DateTime.utc(2026, 11, 2, 6));
      expect(next.difference(ws).inHours, 169);
    });

    test('spring-forward week is 167 hours', () {
      final ws = workweekStart(ct(2027, 3, 14, 12), chicago, DateTime.monday);
      expect(ws, DateTime.utc(2027, 3, 8, 6));
      final next = workweekStart(ct(2027, 3, 15, 12), chicago, DateTime.monday);
      expect(next, DateTime.utc(2027, 3, 15, 5));
      expect(next.difference(ws).inHours, 167);
    });

    test('bad start day throws', () {
      expect(() => workweekStart(ct(2026, 11, 4), chicago, 0), throwsArgumentError);
      expect(() => workweekStart(ct(2026, 11, 4), chicago, 8), throwsArgumentError);
    });
  });

  group('weekly overtime', () {
    test('exactly 40 hours has no overtime', () {
      final w = overtimeForWeek(days(DateTime(2026, 11, 2), 5, 8),
          weekContaining: ct(2026, 11, 4), timeZone: chicago, rules: weekly);
      expect(w.totalMinutes, 2400);
      expect(w.regularMinutes, 2400);
      expect(w.overtimeMinutes, 0);
    });

    test('40 hours and 1 minute has 1 minute of overtime', () {
      final w = overtimeForWeek(days(DateTime(2026, 11, 2), 5, 8, extraMinutesLastDay: 1),
          weekContaining: ct(2026, 11, 4), timeZone: chicago, rules: weekly);
      expect(w.totalMinutes, 2401);
      expect(w.regularMinutes, 2400);
      expect(w.weeklyOvertimeMinutes, 1);
      expect(w.overtimeMinutes, 1);
    });

    test('overlapping intervals are counted once', () {
      final shifts = days(DateTime(2026, 11, 2), 5, 8);
      final w = overtimeForWeek([...shifts, shifts.first, iv(ct(2026, 11, 2, 10), ct(2026, 11, 2, 12))],
          weekContaining: ct(2026, 11, 4), timeZone: chicago, rules: weekly);
      expect(w.totalMinutes, 2400);
      expect(w.overtimeMinutes, 0);
    });

    test('only time inside the week counts', () {
      final w = overtimeForWeek([...days(DateTime(2026, 11, 2), 5, 8), ...days(DateTime(2026, 11, 9), 2, 8)],
          weekContaining: ct(2026, 11, 4), timeZone: chicago, rules: weekly);
      expect(w.totalMinutes, 2400);
    });

    test('shift crossing Sunday to Monday midnight is split between weeks', () {
      // Mon-Thu 9.5h = 38h, then Sun 20:00 to Mon 04:00 (4h each side).
      final intervals = [
        for (var d = 2; d <= 5; d++) iv(ct(2026, 11, d, 9), ct(2026, 11, d, 18, 30)),
        iv(ct(2026, 11, 8, 20), ct(2026, 11, 9, 4)),
      ];
      final weeks = splitOvertime(intervals, timeZone: chicago, rules: weekly);
      expect(weeks.length, 2);
      expect(weeks[0].weekStart, ct(2026, 11, 2));
      expect(weeks[0].weekEnd, ct(2026, 11, 9));
      expect(weeks[0].totalMinutes, 42 * 60);
      expect(weeks[0].weeklyOvertimeMinutes, 120);
      expect(weeks[1].weekStart, ct(2026, 11, 9));
      expect(weeks[1].totalMinutes, 240);
      expect(weeks[1].overtimeMinutes, 0);
    });

    test('fall-back week counts the extra hour', () {
      // Mon-Thu 9h = 36h, plus Sat Oct 31 22:00 CDT to Sun Nov 1 06:00 CST = 9 real hours.
      final intervals = [
        ...days(DateTime(2026, 10, 26), 4, 9),
        iv(ct(2026, 10, 31, 22), ct(2026, 11, 1, 6)),
      ];
      final weeks = splitOvertime(intervals, timeZone: chicago, rules: weekly);
      expect(weeks.length, 1);
      expect(weeks.single.totalMinutes, 45 * 60);
      expect(weeks.single.weeklyOvertimeMinutes, 300);
      expect(weeks.single.days[6].date, DateTime.utc(2026, 11, 1));
      expect(weeks.single.days[6].workedMinutes, 420); // 00:00 to 06:00 on a 25-hour day.
    });

    test('spring-forward week loses an hour', () {
      // Mon-Thu 10h = 40h, plus Sat Mar 13 22:00 CST to Sun Mar 14 06:00 CDT = 7 real hours.
      final intervals = [
        ...days(DateTime(2027, 3, 8), 4, 10),
        iv(ct(2027, 3, 13, 22), ct(2027, 3, 14, 6)),
      ];
      final w = overtimeForWeek(intervals, weekContaining: ct(2027, 3, 10), timeZone: chicago, rules: weekly);
      expect(w.totalMinutes, 47 * 60);
      expect(w.weeklyOvertimeMinutes, 420);
    });

    test('week split uses local midnight across DST', () {
      // Sun Nov 1 23:00 CST to Mon Nov 2 01:00 CST.
      final weeks = splitOvertime([iv(ct(2026, 11, 1, 23), ct(2026, 11, 2, 1))], timeZone: chicago, rules: weekly);
      expect(weeks.map((w) => w.totalMinutes), [60, 60]);
    });

    test('no intervals gives no weeks', () {
      expect(splitOvertime(const [], timeZone: chicago, rules: weekly), isEmpty);
    });
  });

  group('daily and weekly together', () {
    test('five 10-hour days: daily overtime only, no double counting', () {
      final w = overtimeForWeek(days(DateTime(2026, 11, 2), 5, 10),
          weekContaining: ct(2026, 11, 4), timeZone: chicago, rules: daily8);
      expect(w.totalMinutes, 3000);
      expect(w.dailyOvertimeMinutes, 600);
      // 50h total minus 10h daily OT = 40h toward weekly: no weekly OT.
      expect(w.weeklyOvertimeMinutes, 0);
      expect(w.regularMinutes, 2400);
      expect(w.overtimeMinutes, 600);
    });

    test('six 9-hour days: 6h daily plus 8h weekly', () {
      final w = overtimeForWeek(days(DateTime(2026, 11, 2), 6, 9),
          weekContaining: ct(2026, 11, 4), timeZone: chicago, rules: daily8);
      expect(w.totalMinutes, 54 * 60);
      expect(w.dailyOvertimeMinutes, 360);
      expect(w.weeklyOvertimeMinutes, 480);
      expect(w.regularMinutes, 2400);
      expect(w.regularMinutes + w.overtimeMinutes, w.totalMinutes);
    });

    test('daily overtime splits at local midnight', () {
      // 20:00 to 06:00 is 4h + 6h on two calendar days: no daily overtime.
      final w = overtimeForWeek([iv(ct(2026, 11, 3, 20), ct(2026, 11, 4, 6))],
          weekContaining: ct(2026, 11, 4), timeZone: chicago, rules: daily8);
      expect(w.days[1].workedMinutes, 240);
      expect(w.days[2].workedMinutes, 360);
      expect(w.dailyOvertimeMinutes, 0);
    });

    test('Texas rules ignore long days', () {
      final w = overtimeForWeek([iv(ct(2026, 11, 3, 6), ct(2026, 11, 3, 20))],
          weekContaining: ct(2026, 11, 4), timeZone: chicago, rules: weekly);
      expect(w.overtimeMinutes, 0);
    });
  });

  group('outlook', () {
    final now = ct(2026, 11, 6, 18);

    test('far from overtime', () {
      final o = overtimeOutlook(workedMinutesThisWeekBeforeNow: 35 * 60, now: now, rules: weekly);
      expect(o.minutesUntilOvertime, 300);
      expect(o.approaching, isFalse);
      expect(o.inOvertime, isFalse);
      expect(o.projectedOvertimeMinutes, isNull);
    });

    test('approaching at exactly the warning window', () {
      final o = overtimeOutlook(workedMinutesThisWeekBeforeNow: 36 * 60, now: now, rules: weekly);
      expect(o.minutesUntilOvertime, 240);
      expect(o.approaching, isTrue);
    });

    test('at exactly 40h: not yet in overtime, nothing left', () {
      final o = overtimeOutlook(workedMinutesThisWeekBeforeNow: 2400, now: now, rules: weekly);
      expect(o.inOvertime, isFalse);
      expect(o.minutesUntilOvertime, 0);
      expect(o.approaching, isTrue);
      expect(o.overtimeMinutesSoFar, 0);
    });

    test('in overtime', () {
      final o = overtimeOutlook(workedMinutesThisWeekBeforeNow: 2401, now: now, rules: weekly);
      expect(o.inOvertime, isTrue);
      expect(o.approaching, isFalse);
      expect(o.overtimeMinutesSoFar, 1);
    });

    test('projection to scheduled end', () {
      final o = overtimeOutlook(
        workedMinutesThisWeekBeforeNow: 38 * 60,
        now: now,
        scheduledEnd: ct(2026, 11, 6, 22),
        rules: weekly,
      );
      expect(o.projectedOvertimeMinutes, 120);
    });

    test('projection when the end has passed is overtime so far', () {
      final o = overtimeOutlook(
        workedMinutesThisWeekBeforeNow: 2430,
        now: now,
        scheduledEnd: ct(2026, 11, 6, 17),
        rules: weekly,
      );
      expect(o.projectedOvertimeMinutes, 30);
    });

    test('daily threshold, when today is given', () {
      final o = overtimeOutlook(
        workedMinutesThisWeekBeforeNow: 20 * 60,
        workedMinutesTodayBeforeNow: 7 * 60 + 30,
        now: now,
        scheduledEnd: ct(2026, 11, 6, 20),
        rules: daily8,
      );
      expect(o.minutesUntilOvertime, 30);
      expect(o.approaching, isTrue);
      expect(o.projectedOvertimeMinutes, 90);
    });

    test('daily threshold is ignored without today minutes', () {
      final o = overtimeOutlook(workedMinutesThisWeekBeforeNow: 20 * 60, now: now, rules: daily8);
      expect(o.minutesUntilOvertime, 20 * 60);
    });
  });
}
