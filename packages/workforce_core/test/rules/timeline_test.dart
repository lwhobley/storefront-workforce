import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

import 'helpers.dart';

void main() {
  // Tuesday, after the 2026 fall-back, so Chicago is UTC-6.
  DateTime t(int h, [int m = 0, int s = 0]) => ct(2026, 11, 3, h, m, s);

  group('basic shape', () {
    test('no punches', () {
      final tl = WorkTimeline.fromPunches(const []);
      expect(tl.state, TimelineState.notStarted);
      expect(tl.firstClockIn, isNull);
      expect(tl.lastClockOut, isNull);
      expect(tl.workedMinutes, 0);
      expect(tl.breakMinutes, 0);
      expect(tl.isOpen, isFalse);
    });

    test('shift with a rest break', () {
      final tl = WorkTimeline.fromPunches([
        clockIn(t(16)),
        breakStart(t(18), BreakKind.rest),
        breakEnd(t(18, 10)),
        clockOut(t(22)),
      ]);
      expect(tl.state, TimelineState.clockedOut);
      expect(tl.firstClockIn, t(16));
      expect(tl.lastClockOut, t(22));
      expect(tl.workSegments.length, 2);
      expect(tl.breakSegments.single.kind, BreakKind.rest);
      expect(tl.breakSegments.single.minutes, 10);
      expect(tl.workedMinutes, 350);
      expect(tl.breakMinutes, 10);
      expect(tl.issues, isEmpty);
    });

    test('seconds are truncated from each punch before math', () {
      // 16:00:45 -> 16:00 and 16:30:10 -> 16:30.
      final tl = WorkTimeline.fromPunches([clockIn(t(16, 0, 45)), clockOut(t(16, 30, 10))]);
      expect(tl.firstClockIn, t(16));
      expect(tl.workedMinutes, 30);
      // 16:00:10 -> 16:00 and 16:29:59 -> 16:29: 29 minutes, never rounded up.
      final tl2 = WorkTimeline.fromPunches([clockIn(t(16, 0, 10)), clockOut(t(16, 29, 59))]);
      expect(tl2.workedMinutes, 29);
    });

    test('punches out of order are sorted', () {
      final tl = WorkTimeline.fromPunches([
        clockOut(t(22)),
        breakEnd(t(18, 10)),
        clockIn(t(16)),
        breakStart(t(18)),
      ]);
      expect(tl.workedMinutes, 350);
      expect(tl.state, TimelineState.clockedOut);
    });

    test('clock out and back in makes two work segments', () {
      final tl = WorkTimeline.fromPunches([
        clockIn(t(10)),
        clockOut(t(12)),
        clockIn(t(13)),
      ], now: t(14));
      expect(tl.state, TimelineState.working);
      expect(tl.workSegments.length, 2);
      expect(tl.workedMinutes, 180);
      expect(tl.firstClockIn, t(10));
      expect(tl.lastClockOut, t(12));
    });

    test('punches for more than one worker throw', () {
      expect(
        () => WorkTimeline.fromPunches([clockIn(t(16)), clockIn(t(16), workerId: 'w2')]),
        throwsArgumentError,
      );
    });

    test('shiftId keeps only that shift', () {
      final tl = WorkTimeline.fromPunches([
        clockIn(t(10), shiftId: 'a'),
        clockOut(t(12), shiftId: 'a'),
        clockIn(t(16), shiftId: 'b'),
        clockOut(t(20), shiftId: 'b'),
      ], shiftId: 'b');
      expect(tl.firstClockIn, t(16));
      expect(tl.workedMinutes, 240);
    });
  });

  group('messy sequences', () {
    test('voided punches are ignored', () {
      final tl = WorkTimeline.fromPunches([
        clockIn(t(16)),
        punch(PunchKind.clockOut, t(17), status: PunchStatus.voided),
        clockOut(t(22)),
      ]);
      expect(tl.workedMinutes, 360);
      expect(tl.lastClockOut, t(22));
    });

    test('needs-review punches still count', () {
      final tl = WorkTimeline.fromPunches([
        punch(PunchKind.clockIn, t(16), status: PunchStatus.needsReview),
        clockOut(t(17)),
      ]);
      expect(tl.workedMinutes, 60);
    });

    test('the same punch id twice is used once', () {
      final tl = WorkTimeline.fromPunches([
        clockIn(t(16), id: 'a'),
        breakStart(t(18), BreakKind.rest, 'b'),
        breakStart(t(18), BreakKind.rest, 'b'),
        breakEnd(t(18, 10), id: 'c'),
        clockOut(t(22), id: 'd'),
        clockOut(t(22), id: 'd'),
      ]);
      expect(tl.breakSegments.length, 1);
      expect(tl.workedMinutes, 350);
      expect(tl.issues.where((i) => i.kind == TimelineIssueKind.duplicatePunch).length, 2);
    });

    test('a punch id with a voided copy is ignored', () {
      final tl = WorkTimeline.fromPunches([
        clockIn(t(16), id: 'a'),
        clockOut(t(17), id: 'x'),
        punch(PunchKind.clockOut, t(17), id: 'x', status: PunchStatus.voided),
        clockOut(t(22), id: 'y'),
      ]);
      expect(tl.workedMinutes, 360);
    });

    test('two clock-ins in a row keep the first', () {
      final tl = WorkTimeline.fromPunches([
        clockIn(t(16), id: 'a'),
        clockIn(t(16, 20), id: 'b'),
        clockOut(t(20)),
      ]);
      expect(tl.firstClockIn, t(16));
      expect(tl.workSegments.length, 1);
      expect(tl.workedMinutes, 240);
      expect(tl.issues.single.kind, TimelineIssueKind.clockInWhileClockedIn);
      expect(tl.issues.single.punchId, 'b');
    });

    test('clock-in while on break is ignored', () {
      final tl = WorkTimeline.fromPunches([
        clockIn(t(16)),
        breakStart(t(18)),
        clockIn(t(18, 5)),
        breakEnd(t(18, 10)),
        clockOut(t(20)),
      ]);
      expect(tl.workedMinutes, 230);
      expect(tl.breakMinutes, 10);
    });

    test('break end without break start is ignored', () {
      final tl = WorkTimeline.fromPunches([
        clockIn(t(16)),
        breakEnd(t(17), id: 'stray'),
        clockOut(t(20)),
      ]);
      expect(tl.workSegments.length, 1);
      expect(tl.breakSegments, isEmpty);
      expect(tl.workedMinutes, 240);
      expect(tl.issues.single.kind, TimelineIssueKind.breakEndWithoutBreakStart);
    });

    test('break start before clock-in, and clock-out with no clock-in, are ignored', () {
      final tl = WorkTimeline.fromPunches([
        clockOut(t(15)),
        breakStart(t(15, 30)),
        clockIn(t(16)),
        clockOut(t(17)),
      ]);
      expect(tl.workedMinutes, 60);
      expect(tl.breakSegments, isEmpty);
      expect(tl.lastClockOut, t(17));
      expect(tl.issues.map((i) => i.kind), [
        TimelineIssueKind.clockOutWhileNotClockedIn,
        TimelineIssueKind.breakStartWhileNotWorking,
      ]);
    });

    test('second break start while on break is ignored', () {
      final tl = WorkTimeline.fromPunches([
        clockIn(t(16)),
        breakStart(t(18), BreakKind.meal),
        breakStart(t(18, 10), BreakKind.rest),
        breakEnd(t(18, 30)),
        clockOut(t(20)),
      ]);
      expect(tl.breakSegments.single.kind, BreakKind.meal);
      expect(tl.breakSegments.single.minutes, 30);
    });

    test('clock-out during a break ends the break at the clock-out', () {
      final tl = WorkTimeline.fromPunches([
        clockIn(t(16)),
        breakStart(t(20), BreakKind.meal),
        clockOut(t(20, 25)),
      ]);
      expect(tl.state, TimelineState.clockedOut);
      expect(tl.lastClockOut, t(20, 25));
      expect(tl.workedMinutes, 240);
      expect(tl.breakSegments.single.end, t(20, 25));
      expect(tl.breakMinutes, 25);
      expect(tl.isOpen, isFalse);
      expect(tl.issues.single.kind, TimelineIssueKind.clockOutDuringBreak);
    });

    test('break start with no kind is treated as rest', () {
      final tl = WorkTimeline.fromPunches([
        clockIn(t(16)),
        breakStart(t(17), null),
        breakEnd(t(17, 10)),
      ], now: t(18));
      expect(tl.breakSegments.single.kind, BreakKind.rest);
    });
  });

  group('open shifts', () {
    test('missing clock-out runs until now', () {
      final tl = WorkTimeline.fromPunches([clockIn(t(16))], now: t(19, 15, 40));
      expect(tl.state, TimelineState.working);
      expect(tl.isOpen, isTrue);
      expect(tl.workSegments.single.isOpen, isTrue);
      expect(tl.workSegments.single.end, t(19, 15));
      expect(tl.workedMinutes, 195);
      expect(tl.lastClockOut, isNull);
      expect(tl.issues.single.kind, TimelineIssueKind.missingClockOut);
    });

    test('missing clock-out without now has zero length', () {
      final tl = WorkTimeline.fromPunches([clockIn(t(16))]);
      expect(tl.isOpen, isTrue);
      expect(tl.workedMinutes, 0);
    });

    test('open break runs until now', () {
      final tl = WorkTimeline.fromPunches([
        clockIn(t(16)),
        breakStart(t(18), BreakKind.meal),
      ], now: t(18, 12));
      expect(tl.state, TimelineState.onBreak);
      expect(tl.currentBreak!.kind, BreakKind.meal);
      expect(tl.currentBreak!.minutes, 12);
      expect(tl.workedMinutes, 120);
    });

    test('now before the open segment start is clamped', () {
      final tl = WorkTimeline.fromPunches([clockIn(t(16))], now: t(15));
      expect(tl.workedMinutes, 0);
    });
  });

  group('windows', () {
    test('worked minutes inside a window exclude breaks', () {
      final tl = WorkTimeline.fromPunches([
        clockIn(t(16)),
        breakStart(t(18)),
        breakEnd(t(18, 30)),
        clockOut(t(22)),
      ]);
      expect(tl.workedMinutesBetween(t(17), t(19)), 90);
      expect(tl.workedMinutesBetween(t(0), t(23)), tl.workedMinutes);
      expect(tl.workedMinutesBetween(t(22), t(23)), 0);
    });

    test('overnight shift across fall-back counts real elapsed time', () {
      // Sat Oct 31 22:00 CDT to Sun Nov 1 06:00 CST: 8 wall-clock hours, 9 real hours.
      final tl = WorkTimeline.fromPunches([clockIn(ct(2026, 10, 31, 22)), clockOut(ct(2026, 11, 1, 6))]);
      expect(tl.workedMinutes, 540);
      // Split at local midnight: 2h on Saturday, 7h on Sunday (which has 25 hours).
      expect(tl.workedMinutesBetween(ct(2026, 10, 31), ct(2026, 11, 1)), 120);
      expect(tl.workedMinutesBetween(ct(2026, 11, 1), ct(2026, 11, 2)), 420);
    });

    test('overnight shift across spring-forward counts real elapsed time', () {
      // Sat Mar 13 22:00 CST to Sun Mar 14 06:00 CDT: 7 real hours.
      final tl = WorkTimeline.fromPunches([clockIn(ct(2027, 3, 13, 22)), clockOut(ct(2027, 3, 14, 6))]);
      expect(tl.workedMinutes, 420);
    });
  });

  group('paid breaks', () {
    const rules = BreakRules(); // rest 10 min paid, meal 30 min unpaid, 20-minute federal limit.

    WorkTimeline withBreak(BreakKind kind, int minutes) => WorkTimeline.fromPunches([
          clockIn(t(16)),
          breakStart(t(18), kind),
          breakEnd(t(18).add(Duration(minutes: minutes))),
          clockOut(t(22)),
        ]);

    test('15-minute meal is paid (20 minutes or less is always paid)', () {
      final tl = withBreak(BreakKind.meal, 15);
      expect(tl.paidBreakMinutes(rules), 15);
      expect(tl.paidMinutes(rules), tl.workedMinutes + 15);
    });

    test('20-minute meal is paid, 21-minute meal is not', () {
      expect(withBreak(BreakKind.meal, 20).paidBreakMinutes(rules), 20);
      expect(withBreak(BreakKind.meal, 21).paidBreakMinutes(rules), 0);
    });

    test('30-minute meal is unpaid', () {
      final tl = withBreak(BreakKind.meal, 30);
      expect(tl.paidBreakMinutes(rules), 0);
      expect(tl.paidMinutes(rules), 330);
    });

    test('10-minute rest is paid', () {
      expect(withBreak(BreakKind.rest, 10).paidBreakMinutes(rules), 10);
    });

    test('long rest break is paid when the rest rule is paid', () {
      expect(withBreak(BreakKind.rest, 25).paidBreakMinutes(rules), 25);
    });

    test('long break follows the rule for its kind', () {
      const paidMeals = BreakRules(rules: [
        BreakRule(id: 'm', kind: 'meal', afterWorkedMinutes: 300, minimumMinutes: 30, paid: true),
      ]);
      expect(withBreak(BreakKind.meal, 30).paidBreakMinutes(paidMeals), 30);
      // No rest rule configured: long rest still paid.
      expect(withBreak(BreakKind.rest, 25).paidBreakMinutes(paidMeals), 25);
      const noRules = BreakRules(rules: []);
      expect(withBreak(BreakKind.meal, 30).paidBreakMinutes(noRules), 0);
    });

    test('paid intervals join work and paid breaks; unpaid meal leaves a gap', () {
      final rest = withBreak(BreakKind.rest, 10).paidIntervals(rules);
      expect(rest, [iv(t(16), t(22))]);
      final meal = withBreak(BreakKind.meal, 30).paidIntervals(rules);
      expect(meal, [iv(t(16), t(18)), iv(t(18, 30), t(22))]);
    });
  });
}
