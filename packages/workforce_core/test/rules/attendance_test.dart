import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

import 'helpers.dart';

void main() {
  // Call 18:00 Tuesday Nov 3, 2026 in Chicago. Grace 5, no-show 60, early 30.
  DateTime t(int h, [int m = 0, int s = 0]) => ct(2026, 11, 3, h, m, s);
  final call = t(18);
  const rules = AttendanceRules();

  AttendanceResult eval({DateTime? inAt, required DateTime now, bool released = false}) => evaluateAttendance(
        callTime: call,
        timeline: WorkTimeline.fromPunches([if (inAt != null) clockIn(inAt)], now: now),
        rules: rules,
        now: now,
        released: released,
      );

  group('clocked in', () {
    test('before call is on time', () {
      final r = eval(inAt: t(17, 40), now: t(19));
      expect(r.status, AttendanceStatus.onTime);
      expect(r.minutesLate, 0);
      expect(r.clockedInAt, t(17, 40));
    });

    test('exactly at call is on time', () {
      expect(eval(inAt: t(18), now: t(19)).status, AttendanceStatus.onTime);
    });

    test('exactly at the grace minute is on time', () {
      expect(eval(inAt: t(18, 5), now: t(19)).status, AttendanceStatus.onTime);
    });

    test('18:05:59 is still on time (seconds truncated)', () {
      expect(eval(inAt: t(18, 5, 59), now: t(19)).status, AttendanceStatus.onTime);
    });

    test('one minute past grace is late, counted from call time', () {
      final r = eval(inAt: t(18, 6), now: t(19));
      expect(r.status, AttendanceStatus.late);
      expect(r.minutesLate, 6);
    });

    test('arriving after the no-show threshold is late, not a no-show', () {
      final r = eval(inAt: t(19, 30), now: t(20));
      expect(r.status, AttendanceStatus.late);
      expect(r.minutesLate, 90);
    });

    test('zero grace makes one minute late', () {
      final r = evaluateAttendance(
        callTime: call,
        timeline: WorkTimeline.fromPunches([clockIn(t(18, 1))]),
        rules: const AttendanceRules(lateGraceMinutes: 0),
        now: t(19),
      );
      expect(r.status, AttendanceStatus.late);
      expect(r.minutesLate, 1);
    });
  });

  group('not clocked in', () {
    test('before call is upcoming', () {
      expect(eval(now: t(17, 50)).status, AttendanceStatus.upcoming);
    });

    test('inside the grace period is still upcoming', () {
      expect(eval(now: t(18, 3)).status, AttendanceStatus.upcoming);
      expect(eval(now: t(18, 5)).status, AttendanceStatus.upcoming);
      expect(eval(now: t(18, 5, 59)).status, AttendanceStatus.upcoming);
    });

    test('past grace is not arrived', () {
      final r = eval(now: t(18, 6));
      expect(r.status, AttendanceStatus.notArrived);
      expect(r.minutesPastCall, 6);
    });

    test('exactly at the no-show minute is still not arrived', () {
      expect(eval(now: t(19)).status, AttendanceStatus.notArrived);
    });

    test('one minute past the no-show threshold is a no-show', () {
      final r = eval(now: t(19, 1));
      expect(r.status, AttendanceStatus.noShow);
      expect(r.minutesPastCall, 61);
    });
  });

  group('released', () {
    test('overrides no-show', () {
      expect(eval(now: t(20), released: true).status, AttendanceStatus.released);
    });

    test('keeps lateness facts', () {
      final r = eval(inAt: t(18, 20), now: t(21), released: true);
      expect(r.status, AttendanceStatus.released);
      expect(r.minutesLate, 20);
    });
  });

  group('early clock-in window', () {
    test('earliest is call minus 30 minutes', () {
      expect(earliestClockIn(call, rules), t(17, 30));
    });

    test('boundaries', () {
      expect(canClockIn(call, t(17, 29), rules), isFalse);
      expect(canClockIn(call, t(17, 29, 59), rules), isFalse);
      expect(canClockIn(call, t(17, 30), rules), isTrue);
      expect(canClockIn(call, t(18), rules), isTrue);
    });

    test('no latest time, so late people can clock in', () {
      expect(canClockIn(call, t(23), rules), isTrue);
    });
  });
}
