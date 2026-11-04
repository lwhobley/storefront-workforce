import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

import 'helpers.dart';

void main() {
  // Tuesday Nov 3, 2026: call 17:00, scheduled end 23:00.
  DateTime t(int h, [int m = 0]) => ct(2026, 11, 3, h, m);
  const rules = VenueRules.texasDefaults;

  final shift = Shift(
    id: 's1',
    venueId: 'v1',
    eventId: 'e1',
    storefrontId: 'sf1',
    jobRoleCode: 'cashier',
    workerId: 'w1',
    callTime: t(17),
    scheduledEnd: t(23),
    status: ShiftStatus.assigned,
  );

  Worker worker({DateTime? dob}) => Worker(
        id: 'w1',
        venueId: 'v1',
        type: WorkerType.regular,
        employeeNumber: '100',
        firstName: 'Ana',
        lastName: 'Diaz',
        dateOfBirth: dob,
      );

  LiveShiftStatus live(List<Punch> punches, DateTime now,
          {Shift? s, Worker? w, int weekBefore = 0, int? ageOnEvent}) =>
      evaluateLiveShift(
        shift: s ?? shift,
        worker: w ?? worker(),
        punches: punches,
        rules: rules,
        timeZone: chicago,
        now: now,
        workedMinutesThisWeekBeforeEvent: weekBefore,
        ageOnEvent: ageOnEvent,
      );

  group('headline', () {
    test('cancelled beats everything', () {
      final r = live([clockIn(t(17))], t(18), s: shift.copyWith(status: ShiftStatus.cancelled));
      expect(r.headline, LiveHeadline.cancelled);
    });

    test('open position', () {
      final open = Shift(
        id: 's2',
        venueId: 'v1',
        eventId: 'e1',
        storefrontId: 'sf1',
        jobRoleCode: 'cashier',
        callTime: t(17),
      );
      final r = evaluateLiveShift(
          shift: open, punches: [clockIn(t(17))], rules: rules, timeZone: chicago, now: t(19));
      expect(r.headline, LiveHeadline.openPosition);
      expect(r.timeline.state, TimelineState.notStarted);
    });

    test('released beats no-show and working', () {
      final released = shift.copyWith(status: ShiftStatus.released, releasedAt: t(20));
      expect(live(const [], t(21), s: released).headline, LiveHeadline.released);
      expect(live([clockIn(t(17))], t(21), s: released).headline, LiveHeadline.released);
    });

    test('no-show', () {
      final r = live(const [], t(18, 1));
      expect(r.headline, LiveHeadline.noShow);
      expect(r.attendance.status, AttendanceStatus.noShow);
    });

    test('not arrived', () {
      expect(live(const [], t(17, 6)).headline, LiveHeadline.notArrived);
    });

    test('upcoming before call and inside grace', () {
      expect(live(const [], t(16)).headline, LiveHeadline.upcoming);
      expect(live(const [], t(17, 5)).headline, LiveHeadline.upcoming);
    });

    test('late and working', () {
      final r = live([clockIn(t(17, 20))], t(18));
      expect(r.headline, LiveHeadline.late);
      expect(r.attendance.minutesLate, 20);
      expect(r.state, TimelineState.working);
    });

    test('late but on break shows on break', () {
      final r = live([clockIn(t(17, 20)), breakStart(t(19))], t(19, 5));
      expect(r.headline, LiveHeadline.onBreak);
      expect(r.attendance.status, AttendanceStatus.late);
    });

    test('on time and working', () {
      final r = live([clockIn(t(16, 50))], t(18));
      expect(r.headline, LiveHeadline.working);
      expect(r.workedMinutes, 70);
    });

    test('clocked out', () {
      final r = live([clockIn(t(17)), clockOut(t(21))], t(21, 30));
      expect(r.headline, LiveHeadline.clockedOut);
      expect(r.workedMinutes, 240);
    });

    test('other workers\' punches are ignored', () {
      final r = live([clockIn(t(17), workerId: 'w2')], t(17, 30));
      expect(r.headline, LiveHeadline.notArrived);
    });
  });

  group('breaks on the card', () {
    test('rest due after 4 hours flags attention', () {
      final r = live([clockIn(t(17))], t(21));
      expect(r.needsBreakAttention, isTrue);
      expect(r.breaks.minutesUntilNextDue, 0);
    });

    test('rest taken clears attention', () {
      final r = live([clockIn(t(17)), breakStart(t(20)), breakEnd(t(20, 10))], t(21, 10));
      expect(r.needsBreakAttention, isFalse);
    });
  });

  group('minors', () {
    test('age from birth date on the local call date', () {
      final r = live([clockIn(t(17))], t(18), w: worker(dob: DateTime.utc(2010, 11, 3)));
      expect(r.age, 16);
      expect(r.isMinor, isTrue);
    });

    test('ageOnEvent wins over the birth date', () {
      final r = live([clockIn(t(17))], t(18), w: worker(dob: DateTime.utc(1990, 1, 1)), ageOnEvent: 15);
      expect(r.age, 15);
      expect(r.isMinor, isTrue);
    });

    test('ageOnEvent works with no worker record', () {
      final r = evaluateLiveShift(
          shift: shift, punches: const [], rules: rules, timeZone: chicago, now: t(16), ageOnEvent: 17);
      expect(r.isMinor, isTrue);
    });

    test('unknown age is not a minor', () {
      final r = live([clockIn(t(17))], t(18));
      expect(r.age, isNull);
      expect(r.isMinor, isFalse);
    });

    test('minor-only break rules apply from ageOnEvent', () {
      const minorRules = VenueRules(
        breaks: BreakRules(rules: [
          BreakRule(id: 'minor_meal', kind: 'meal', afterWorkedMinutes: 240, minimumMinutes: 30, paid: false,
              audience: BreakAudience.minors),
        ]),
      );
      LiveShiftStatus at(int? age) => evaluateLiveShift(
          shift: shift,
          worker: worker(),
          punches: [clockIn(t(17))],
          rules: minorRules,
          timeZone: chicago,
          now: t(21),
          ageOnEvent: age);
      expect(at(15).needsBreakAttention, isTrue);
      expect(at(30).breaks.statuses, isEmpty);
    });
  });

  group('overtime on the card', () {
    test('approaching, with projection to scheduled end', () {
      // 36h before the event, 2h so far: 38h, 2h left. Working to 23:00 adds 4h more.
      final r = live([clockIn(t(17))], t(19), weekBefore: 36 * 60);
      expect(r.overtime.minutesUntilOvertime, 120);
      expect(r.overtime.approaching, isTrue);
      expect(r.overtime.inOvertime, isFalse);
      expect(r.overtime.projectedOvertimeMinutes, 120);
    });

    test('paid rest break counts toward overtime; unpaid meal does not', () {
      final rest = live([clockIn(t(17)), breakStart(t(18)), breakEnd(t(18, 10))], t(19), weekBefore: 2400);
      expect(rest.overtime.overtimeMinutesSoFar, 120);
      expect(rest.paidMinutes, 120);
      final meal = live([clockIn(t(17)), breakStart(t(18), BreakKind.meal), breakEnd(t(18, 30))], t(19),
          weekBefore: 2400);
      expect(meal.overtime.overtimeMinutesSoFar, 90);
    });

    test('clocked out: projection is overtime so far', () {
      final r = live([clockIn(t(17)), clockOut(t(20))], t(21), weekBefore: 39 * 60);
      expect(r.overtime.inOvertime, isTrue);
      expect(r.overtime.projectedOvertimeMinutes, 120);
    });

    test('not started yet: projection runs from call time', () {
      final r = live(const [], t(16), weekBefore: 38 * 60);
      expect(r.overtime.projectedOvertimeMinutes, 4 * 60);
    });

    test('Sunday night event: only time after Monday midnight counts in the new week', () {
      // Sun Nov 8 20:00 to now Mon Nov 9 01:00. The caller passes 0 for the new week.
      final sunday = Shift(
        id: 's3',
        venueId: 'v1',
        eventId: 'e2',
        storefrontId: 'sf1',
        jobRoleCode: 'cashier',
        workerId: 'w1',
        callTime: ct(2026, 11, 8, 20),
        status: ShiftStatus.assigned,
      );
      final r = live([clockIn(ct(2026, 11, 8, 20))], ct(2026, 11, 9, 1), s: sunday);
      expect(r.workedMinutes, 300);
      expect(r.overtime.minutesUntilOvertime, 2400 - 60);
    });
  });
}
