import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

import 'helpers.dart';

void main() {
  const rules = MinorRules(); // 14-15: 3h school day, 8h other day, 18h/40h week, 07:00-19:00 (21:00 summer).

  MinorCheckResult check(int? age, DateTime start, DateTime end,
          {String role = 'cashier', List<WorkInterval> others = const []}) =>
      checkMinorShift(
        age: age,
        rules: rules,
        jobRoleCode: role,
        start: start,
        end: end,
        timeZone: chicago,
        otherIntervals: others,
      );

  List<MinorViolationCode> codes(MinorCheckResult r) => [for (final v in r.violations) v.code];

  group('time of day', () {
    test('14-year-old on a school night past 19:00', () {
      // Tuesday Nov 3, 2026, 16:30-19:30 (3h, within the daily cap).
      final r = check(14, ct(2026, 11, 3, 16, 30), ct(2026, 11, 3, 19, 30));
      expect(r.isMinor, isTrue);
      expect(codes(r), [MinorViolationCode.tooLate]);
      expect(r.violations.single.message, contains('19:00'));
      expect(r.violations.single.message, contains('19:30'));
    });

    test('ending exactly at 19:00 is allowed', () {
      expect(check(14, ct(2026, 11, 3, 16), ct(2026, 11, 3, 19)).ok, isTrue);
    });

    test('summer shift ending 20:30 is fine, 21:30 is not', () {
      // Saturday July 11, 2026: summer, non-school day (8h cap).
      expect(check(14, ct(2026, 7, 11, 12, 30), ct(2026, 7, 11, 20, 30)).ok, isTrue);
      final late = check(14, ct(2026, 7, 11, 13, 30), ct(2026, 7, 11, 21, 30));
      expect(codes(late), [MinorViolationCode.tooLate]);
      expect(late.violations.single.message, contains('21:00'));
    });

    test('summer runs through Labor Day, not the day after', () {
      // Labor Day 2026 is Mon Sep 7 (a school day here, since holidays are not known).
      // 17:00-20:00 is 3h, at the school-day cap.
      expect(check(15, ct(2026, 9, 7, 17), ct(2026, 9, 7, 20)).ok, isTrue);
      expect(codes(check(15, ct(2026, 9, 8, 17), ct(2026, 9, 8, 20))), [MinorViolationCode.tooLate]);
    });

    test('shift ending after midnight is too late', () {
      // Friday Nov 6 18:00 to Saturday 00:30.
      final r = check(14, ct(2026, 11, 6, 18), ct(2026, 11, 7, 0, 30));
      expect(codes(r), contains(MinorViolationCode.tooLate));
      expect(r.violations.firstWhere((v) => v.code == MinorViolationCode.tooLate).message,
          contains('00:30 the next day'));
    });

    test('summer shift ending after midnight is too late for 21:00', () {
      final r = check(15, ct(2026, 7, 11, 20), ct(2026, 7, 12, 0, 30));
      expect(codes(r), [MinorViolationCode.tooLate]);
    });

    test('starting before 07:00 is too early', () {
      final r = check(14, ct(2026, 11, 7, 6, 30), ct(2026, 11, 7, 10));
      expect(codes(r), [MinorViolationCode.tooEarly]);
      expect(r.violations.single.message, contains('06:30'));
      expect(check(14, ct(2026, 11, 7, 7), ct(2026, 11, 7, 10)).ok, isTrue);
    });
  });

  group('hours', () {
    test('15-year-old 4 hours on a school day is over', () {
      final r = check(15, ct(2026, 11, 4, 15), ct(2026, 11, 4, 19));
      expect(codes(r), [MinorViolationCode.dailyHours]);
      expect(r.violations.single.message, contains('school day'));
      expect(r.violations.single.message, contains('4h'));
      expect(r.violations.single.date, DateTime.utc(2026, 11, 4));
    });

    test('15-year-old 4 hours on a Saturday is fine', () {
      expect(check(15, ct(2026, 11, 7, 12), ct(2026, 11, 7, 16)).ok, isTrue);
    });

    test('3 hours on a school day is exactly at the cap', () {
      expect(check(15, ct(2026, 11, 4, 15), ct(2026, 11, 4, 18)).ok, isTrue);
    });

    test('other shifts the same day add up', () {
      final r = check(15, ct(2026, 11, 4, 17), ct(2026, 11, 4, 19),
          others: [iv(ct(2026, 11, 4, 7), ct(2026, 11, 4, 8, 30))]);
      expect(codes(r), [MinorViolationCode.dailyHours]);
    });

    test('the same shift passed again in others is not double counted', () {
      final r = check(15, ct(2026, 11, 4, 15), ct(2026, 11, 4, 18),
          others: [iv(ct(2026, 11, 4, 15), ct(2026, 11, 4, 18))]);
      expect(r.ok, isTrue);
    });

    // School week Mon Nov 2 - Sun Nov 8, 2026: 3h each weekday = 15h.
    final weekdays = [for (var d = 2; d <= 6; d++) iv(ct(2026, 11, d, 16), ct(2026, 11, d, 19))];

    test('weekly 18h cap in a school week: 19h is over', () {
      final r = check(15, ct(2026, 11, 7, 10), ct(2026, 11, 7, 14), others: weekdays);
      expect(codes(r), [MinorViolationCode.weeklyHours]);
      expect(r.violations.single.message, contains('school week'));
      expect(r.violations.single.message, contains('19h'));
      expect(r.violations.single.date, DateTime.utc(2026, 11, 2));
    });

    test('weekly 18h cap in a school week: exactly 18h is fine', () {
      expect(check(15, ct(2026, 11, 7, 10), ct(2026, 11, 7, 13), others: weekdays).ok, isTrue);
    });

    test('time in other weeks is ignored', () {
      final lastWeek = [for (var d = 26; d <= 30; d++) iv(ct(2026, 10, d, 16), ct(2026, 10, d, 19))];
      expect(check(15, ct(2026, 11, 7, 10), ct(2026, 11, 7, 13), others: lastWeek).ok, isTrue);
    });

    test('summer week uses the 40h non-school cap', () {
      // Week of Mon Jul 6, 2026: five 8h days = 40h, OK. A sixth day goes over.
      final summer = [for (var d = 6; d <= 10; d++) iv(ct(2026, 7, d, 9), ct(2026, 7, d, 17))];
      expect(check(15, ct(2026, 7, 10, 9), ct(2026, 7, 10, 17), others: summer).ok, isTrue);
      final r = check(15, ct(2026, 7, 11, 9), ct(2026, 7, 11, 11), others: summer);
      expect(codes(r), [MinorViolationCode.weeklyHours]);
      expect(r.violations.single.message, contains('non-school week'));
    });
  });

  group('age', () {
    test('16-year-old bartender is prohibited', () {
      final r = check(16, ct(2026, 11, 7, 18), ct(2026, 11, 7, 23), role: 'bartender');
      expect(codes(r), [MinorViolationCode.prohibitedRole]);
      expect(r.violations.single.code.code, 'prohibited_role');
    });

    test('16-year-old cashier late at night is fine (no hour limits)', () {
      expect(check(16, ct(2026, 11, 3, 18), ct(2026, 11, 4, 1)).ok, isTrue);
    });

    test('14-year-old cook is prohibited', () {
      expect(codes(check(14, ct(2026, 11, 7, 12), ct(2026, 11, 7, 14), role: 'cook')),
          [MinorViolationCode.prohibitedRole]);
    });

    test('13-year-old is under the minimum age', () {
      final r = check(13, ct(2026, 11, 7, 12), ct(2026, 11, 7, 14));
      expect(codes(r), [MinorViolationCode.underMinimumAge]);
      expect(r.violations.single.code.code, 'under_minimum_age');
    });

    test('adult has no violations', () {
      final r = check(18, ct(2026, 11, 3, 2), ct(2026, 11, 3, 14), role: 'bartender');
      expect(r.isMinor, isFalse);
      expect(r.ok, isTrue);
      expect(r.ageUnknown, isFalse);
    });

    test('unknown age is flagged, not a violation', () {
      final r = check(null, ct(2026, 11, 3, 16), ct(2026, 11, 3, 23), role: 'bartender');
      expect(r.ageUnknown, isTrue);
      expect(r.isMinor, isFalse);
      expect(r.violations, isEmpty);
    });

    test('age uses the venue-local date', () {
      final w = Worker(
        id: 'w1',
        venueId: 'v1',
        type: WorkerType.regular,
        employeeNumber: '1',
        firstName: 'A',
        lastName: 'B',
        dateOfBirth: DateTime.utc(2012, 11, 4),
      );
      // Nov 3 23:30 in Chicago is already Nov 4 in UTC.
      final at = ct(2026, 11, 3, 23, 30);
      expect(at.day, 4);
      expect(workerAgeAt(w, at, chicago), 13);
      expect(workerAgeAt(w, ct(2026, 11, 4, 0, 30), chicago), 14);
    });
  });

  group('calendar', () {
    test('school days wrap across New Year', () {
      expect(isSchoolDay(DateTime.utc(2026, 8, 14), rules), isFalse); // Fri before start
      expect(isSchoolDay(DateTime.utc(2026, 8, 17), rules), isTrue); // Mon
      expect(isSchoolDay(DateTime.utc(2027, 1, 5), rules), isTrue);
      expect(isSchoolDay(DateTime.utc(2027, 5, 31), rules), isTrue); // last day, Mon
      expect(isSchoolDay(DateTime.utc(2027, 6, 1), rules), isFalse);
      expect(isSchoolDay(DateTime.utc(2026, 11, 7), rules), isFalse); // Sat
    });

    test('school year that does not wrap', () {
      const r = MinorRules(schoolYearStart: '01-10', schoolYearEnd: '06-01');
      expect(isSchoolDay(DateTime.utc(2027, 1, 11), r), isTrue);
      expect(isSchoolDay(DateTime.utc(2026, 11, 3), r), isFalse);
    });

    test('school week has at least one school day', () {
      expect(isSchoolWeek(DateTime.utc(2027, 5, 31), rules), isTrue); // only Monday
      expect(isSchoolWeek(DateTime.utc(2027, 6, 7), rules), isFalse);
    });

    test('summer and Labor Day', () {
      expect(laborDay(2026), DateTime.utc(2026, 9, 7));
      expect(laborDay(2025), DateTime.utc(2025, 9, 1));
      expect(isSummer(DateTime.utc(2026, 5, 31)), isFalse);
      expect(isSummer(DateTime.utc(2026, 6, 1)), isTrue);
      expect(isSummer(DateTime.utc(2026, 9, 7)), isTrue);
      expect(isSummer(DateTime.utc(2026, 9, 8)), isFalse);
    });
  });
}
