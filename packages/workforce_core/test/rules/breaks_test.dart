import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

import 'helpers.dart';

void main() {
  // Saturday Nov 7, 2026, clock-in 10:00. Default rules: rest 10 min after 4h
  // (due 14:00), meal 30 min after 6h (due 16:00), reminder 15 min before.
  DateTime t(int h, [int m = 0]) => ct(2026, 11, 7, h, m);
  const rules = BreakRules();

  BreakEvaluation eval(List<Punch> punches, DateTime now, {int? age, BreakRules r = rules}) => evaluateBreaks(
        timeline: WorkTimeline.fromPunches(punches, now: now),
        rules: r,
        age: age,
        now: now,
      );

  BreakRuleStatus rest(BreakEvaluation e) => e.statuses.firstWhere((s) => s.rule.id == 'rest_4h');
  BreakRuleStatus meal(BreakEvaluation e) => e.statuses.firstWhere((s) => s.rule.id == 'meal_6h');

  group('before due', () {
    test('not yet due', () {
      final e = eval([clockIn(t(10))], t(13));
      expect(rest(e).status, BreakStatus.notYetDue);
      expect(rest(e).minutesUntilDue, 60);
      expect(meal(e).minutesUntilDue, 180);
      expect(e.minutesUntilNextDue, 60);
      expect(e.needsAttention, isFalse);
    });

    test('not started counts the full threshold', () {
      final e = eval(const [], t(9));
      expect(rest(e).status, BreakStatus.notYetDue);
      expect(rest(e).minutesUntilDue, 240);
    });

    test('due soon starts exactly reminder minutes before', () {
      expect(rest(eval([clockIn(t(10))], t(13, 44))).status, BreakStatus.notYetDue);
      final e = eval([clockIn(t(10))], t(13, 45));
      expect(rest(e).status, BreakStatus.dueSoon);
      expect(rest(e).minutesUntilDue, 15);
      expect(e.needsAttention, isFalse);
    });

    test('a break taken early satisfies the rule', () {
      final e = eval([clockIn(t(10)), breakStart(t(11), BreakKind.meal), breakEnd(t(11, 30))], t(12));
      expect(meal(e).status, BreakStatus.taken);
      expect(meal(e).breakTaken!.start, t(11));
    });
  });

  group('due', () {
    test('at the due point', () {
      final e = eval([clockIn(t(10))], t(14));
      expect(rest(e).status, BreakStatus.due);
      expect(rest(e).dueAt, t(14));
      expect(rest(e).minutesPastDue, 0);
      expect(e.needsAttention, isTrue);
      expect(e.minutesUntilNextDue, 0);
    });

    test('overdue reports worked minutes past due', () {
      final e = eval([clockIn(t(10))], t(14, 20));
      expect(rest(e).status, BreakStatus.due);
      expect(rest(e).minutesPastDue, 20);
    });

    test('due point uses cumulative worked minutes, so breaks push it later', () {
      // Rest 13:00-13:10 then meal due after 360 worked minutes: 16:10.
      final e = eval([clockIn(t(10)), breakStart(t(13)), breakEnd(t(13, 10))], t(16, 10));
      expect(rest(e).status, BreakStatus.taken);
      expect(meal(e).status, BreakStatus.due);
      expect(meal(e).dueAt, t(16, 10));
    });

    test('a meal does not satisfy a rest rule', () {
      final e = eval([clockIn(t(10)), breakStart(t(13), BreakKind.meal), breakEnd(t(13, 30))], t(14, 30));
      expect(meal(e).status, BreakStatus.taken);
      expect(rest(e).status, BreakStatus.due);
    });
  });

  group('taken', () {
    test('rest at exactly the due point is on time', () {
      final e = eval([clockIn(t(10)), breakStart(t(14)), breakEnd(t(14, 10))], t(15));
      expect(rest(e).status, BreakStatus.taken);
      expect(e.hasExceptions, isFalse);
    });

    test('rest after the due point is taken late', () {
      final e = eval([clockIn(t(10)), breakStart(t(14, 30)), breakEnd(t(14, 40))], t(15));
      expect(rest(e).status, BreakStatus.takenLate);
      expect(rest(e).dueAt, t(14));
      expect(e.needsAttention, isFalse);
      expect(e.hasExceptions, isTrue);
    });

    test('a break in progress shows in progress until it reaches the minimum', () {
      final punches = [clockIn(t(10)), breakStart(t(15, 50), BreakKind.meal)];
      expect(meal(eval(punches, t(16))).status, BreakStatus.inProgress);
      expect(meal(eval(punches, t(16, 20))).status, BreakStatus.taken);
    });
  });

  group('short and missed', () {
    test('short rest after the due point', () {
      final e = eval([clockIn(t(10)), breakStart(t(14)), breakEnd(t(14, 5))], t(15));
      expect(rest(e).status, BreakStatus.short);
      expect(rest(e).breakTaken!.minutes, 5);
      expect(e.needsAttention, isTrue);
      expect(e.hasExceptions, isTrue);
    });

    test('short early break does not flag until the rule is due', () {
      final e = eval([clockIn(t(10)), breakStart(t(12)), breakEnd(t(12, 5))], t(13));
      expect(rest(e).status, BreakStatus.notYetDue);
    });

    test('a proper break after a short one counts (late)', () {
      final e = eval([
        clockIn(t(10)),
        breakStart(t(12)),
        breakEnd(t(12, 5)),
        breakStart(t(14, 30)),
        breakEnd(t(14, 40)),
      ], t(15));
      expect(rest(e).status, BreakStatus.takenLate);
    });

    test('clocked out after the due point with no break is missed', () {
      final e = eval([clockIn(t(10)), clockOut(t(17))], t(18));
      expect(rest(e).status, BreakStatus.missed);
      expect(meal(e).status, BreakStatus.missed);
      expect(e.needsAttention, isTrue);
      expect(e.minutesUntilNextDue, isNull);
    });

    test('clocked out with a short meal stays short', () {
      final e = eval([
        clockIn(t(10)),
        breakStart(t(13)),
        breakEnd(t(13, 10)),
        breakStart(t(16), BreakKind.meal),
        breakEnd(t(16, 20)),
        clockOut(t(18)),
      ], t(18));
      expect(rest(e).status, BreakStatus.taken);
      expect(meal(e).status, BreakStatus.short);
    });

    test('clocked out before the due point means not required', () {
      final e = eval([clockIn(t(10)), clockOut(t(13))], t(14));
      expect(rest(e).status, BreakStatus.notRequired);
      expect(meal(e).status, BreakStatus.notRequired);
      expect(e.needsAttention, isFalse);
      expect(e.minutesUntilNextDue, isNull);
    });

    test('clocked out exactly at the due point with no break is missed', () {
      final e = eval([clockIn(t(10)), clockOut(t(14))], t(15));
      expect(rest(e).status, BreakStatus.missed);
    });
  });

  group('several rules of one kind', () {
    const twoRests = BreakRules(rules: [
      BreakRule(id: 'rest_b', kind: 'rest', afterWorkedMinutes: 360, minimumMinutes: 10, paid: true),
      BreakRule(id: 'rest_a', kind: 'rest', afterWorkedMinutes: 120, minimumMinutes: 10, paid: true),
    ]);

    test('one break satisfies only one rule', () {
      final e = eval([clockIn(t(10)), breakStart(t(11, 30)), breakEnd(t(11, 40))], t(16, 10), r: twoRests);
      // Output keeps rule order.
      expect(e.statuses.map((s) => s.rule.id), ['rest_b', 'rest_a']);
      expect(e.statuses[1].status, BreakStatus.taken);
      expect(e.statuses[0].status, BreakStatus.due);
    });

    test('the same const rule listed twice is evaluated twice', () {
      const r = BreakRule(id: 'x', kind: 'rest', afterWorkedMinutes: 60, minimumMinutes: 10, paid: true);
      final e = eval([clockIn(t(10)), breakStart(t(10, 30)), breakEnd(t(10, 40))], t(12),
          r: const BreakRules(rules: [r, r]));
      expect(e.statuses.map((s) => s.status), [BreakStatus.taken, BreakStatus.due]);
    });
  });

  group('audience', () {
    // Minors: meal of 30 after 5h. Adults: meal of 30 after 6h.
    const mixed = BreakRules(rules: [
      BreakRule(id: 'adult_meal', kind: 'meal', afterWorkedMinutes: 360, minimumMinutes: 30, paid: false,
          audience: BreakAudience.adults),
      BreakRule(id: 'minor_meal', kind: 'meal', afterWorkedMinutes: 300, minimumMinutes: 30, paid: false,
          audience: BreakAudience.minors),
      BreakRule(id: 'rest', kind: 'rest', afterWorkedMinutes: 240, minimumMinutes: 10, paid: true),
    ]);

    test('rule filter', () {
      const adult = BreakRule(id: 'a', kind: 'rest', afterWorkedMinutes: 1, minimumMinutes: 1, paid: true,
          audience: BreakAudience.adults);
      const minor = BreakRule(id: 'm', kind: 'rest', afterWorkedMinutes: 1, minimumMinutes: 1, paid: true,
          audience: BreakAudience.minors);
      expect(breakRuleApplies(adult, null, 18), isTrue);
      expect(breakRuleApplies(minor, null, 18), isFalse);
      expect(breakRuleApplies(adult, 18, 18), isTrue);
      expect(breakRuleApplies(minor, 17, 18), isTrue);
      expect(breakRuleApplies(adult, 17, 18), isFalse);
    });

    test('16-year-old gets the minor meal rule, due after 5 hours', () {
      final e = eval([clockIn(t(10))], t(15), age: 16, r: mixed);
      expect(e.statuses.map((s) => s.rule.id), ['minor_meal', 'rest']);
      expect(e.statuses.first.status, BreakStatus.due);
      expect(e.needsAttention, isTrue);
    });

    test('adult at the same time is not due yet', () {
      final e = eval([clockIn(t(10))], t(15), age: 30, r: mixed);
      expect(e.statuses.map((s) => s.rule.id), ['adult_meal', 'rest']);
      expect(e.statuses.first.status, BreakStatus.notYetDue);
      expect(e.statuses.first.minutesUntilDue, 60);
    });

    test('unknown age is treated as adult', () {
      final e = eval([clockIn(t(10))], t(15), r: mixed);
      expect(e.statuses.first.rule.id, 'adult_meal');
    });

    test('minor missed meal after clocking out', () {
      final e = eval([clockIn(t(10)), breakStart(t(14)), breakEnd(t(14, 10)), clockOut(t(16))], t(16), age: 15,
          r: mixed);
      expect(e.statuses.first.status, BreakStatus.missed);
      expect(e.statuses.last.status, BreakStatus.taken);
    });

    test('minor took the meal late', () {
      final e = eval([clockIn(t(10)), breakStart(t(15, 30), BreakKind.meal), breakEnd(t(16))], t(17), age: 15,
          r: mixed);
      expect(e.statuses.first.status, BreakStatus.takenLate);
    });
  });
}
