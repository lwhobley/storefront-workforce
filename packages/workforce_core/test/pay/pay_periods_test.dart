import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

import 'pay_helpers.dart';

void main() {
  const biweekly = PayPeriodRules(frequency: 'biweekly', anchorDate: '2026-01-05');

  group('biweekly from the anchor', () {
    test('period containing a date, with payday 5 days after the end', () {
      // 2026-01-05 + 21 x 14 days = 2026-10-26.
      final p = periodContaining(day(2026, 11, 4), rules: biweekly, paydayDaysAfterEnd: 5);
      expect(p.startsOn, day(2026, 10, 26));
      expect(p.endsOn, day(2026, 11, 8));
      expect(p.payDate, day(2026, 11, 13));
      expect(p.days, 14);
      expect(p.contains(day(2026, 11, 8)), isTrue);
      expect(p.contains(day(2026, 11, 9)), isFalse);
    });

    test('first and last day of a period map to that period', () {
      expect(periodContaining(day(2026, 11, 9), rules: biweekly, paydayDaysAfterEnd: 5).startsOn, day(2026, 11, 9));
      expect(periodContaining(day(2026, 11, 22), rules: biweekly, paydayDaysAfterEnd: 5).startsOn, day(2026, 11, 9));
    });

    test('dates before the anchor go backward', () {
      final p = periodContaining(day(2025, 12, 31), rules: biweekly, paydayDaysAfterEnd: 5);
      expect(p.startsOn, day(2025, 12, 22));
      expect(p.endsOn, day(2026, 1, 4));
    });

    test('generate covers the range', () {
      final ps = generatePayPeriods(
        rules: biweekly,
        paydayDaysAfterEnd: 5,
        from: day(2026, 11, 1),
        to: day(2026, 11, 30),
      );
      expect(ps.map((p) => formatDate(p.startsOn)), ['2026-10-26', '2026-11-09', '2026-11-23']);
      expect(ps.map((p) => formatDate(p.payDate)), ['2026-11-13', '2026-11-27', '2026-12-11']);
      for (var i = 1; i < ps.length; i++) {
        expect(ps[i].startsOn, addCalendarDays(ps[i - 1].endsOn, 1));
      }
    });

    test('from venue settings', () {
      final ps = generatePayPeriodsFor(
        venueRules: texas,
        payRules: const PayRules(paydayDaysAfterEnd: 3),
        from: day(2026, 11, 10),
        to: day(2026, 11, 10),
        venueId: 'v1',
      );
      expect(ps.single, PayPeriod(startsOn: day(2026, 11, 9), endsOn: day(2026, 11, 22), payDate: day(2026, 11, 25)));
      expect(ps.single.venueId, 'v1');
    });
  });

  test('weekly', () {
    const weekly = PayPeriodRules(frequency: 'weekly', anchorDate: '2026-01-05');
    final p = periodContaining(day(2026, 11, 15), rules: weekly, paydayDaysAfterEnd: 5);
    expect(p.startsOn, day(2026, 11, 9));
    expect(p.endsOn, day(2026, 11, 15));
    expect(p.payDate, day(2026, 11, 20));
  });

  group('semimonthly', () {
    const semi = PayPeriodRules(frequency: 'semimonthly');

    test('1-15 and 16-end of month', () {
      final ps = generatePayPeriods(rules: semi, paydayDaysAfterEnd: 5, from: day(2026, 11, 3), to: day(2026, 12, 20));
      expect(ps.map((p) => '${formatDate(p.startsOn)}..${formatDate(p.endsOn)} ${formatDate(p.payDate)}'), [
        '2026-11-01..2026-11-15 2026-11-20',
        '2026-11-16..2026-11-30 2026-12-05',
        '2026-12-01..2026-12-15 2026-12-20',
        '2026-12-16..2026-12-31 2027-01-05',
      ]);
    });

    test('February, including a leap year', () {
      expect(periodContaining(day(2027, 2, 20), rules: semi, paydayDaysAfterEnd: 5).endsOn, day(2027, 2, 28));
      expect(periodContaining(day(2028, 2, 20), rules: semi, paydayDaysAfterEnd: 5).endsOn, day(2028, 2, 29));
    });
  });

  group('compliance notes', () {
    List<String> codes(PayPeriodRules rules, {PayRules pay = PayRules.texasDefaults}) =>
        payPeriodComplianceNotes(rules: rules, payRules: pay, overtime: texas.overtime).map((n) => n.code).toList();

    test('biweekly anchored on the workweek start is clean', () {
      expect(codes(biweekly), isEmpty);
    });

    test('monthly warns under the Texas Payday Law', () {
      final notes = payPeriodComplianceNotes(
        rules: const PayPeriodRules(frequency: 'monthly'),
        payRules: PayRules.texasDefaults,
        overtime: texas.overtime,
      );
      final n = notes.firstWhere((n) => n.code == 'texas_payday_law_monthly');
      expect(n.severity, ComplianceSeverity.warning);
      expect(n.message, contains('twice a month'));
    });

    test('anchor off the workweek start, semimonthly, bad lag, unknown frequency', () {
      expect(codes(const PayPeriodRules(frequency: 'biweekly', anchorDate: '2026-01-07')), [
        'period_not_aligned_to_workweek',
      ]);
      expect(codes(const PayPeriodRules(frequency: 'semimonthly')), ['workweeks_straddle_periods']);
      expect(codes(biweekly, pay: const PayRules(paydayDaysAfterEnd: -1)), ['payday_before_period_end']);
      expect(codes(const PayPeriodRules(frequency: 'quarterly')), ['unknown_frequency']);
      expect(
        () => periodContaining(
          day(2026, 1, 1),
          rules: const PayPeriodRules(frequency: 'quarterly'),
          paydayDaysAfterEnd: 5,
        ),
        throwsArgumentError,
      );
    });
  });
}
