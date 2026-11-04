import 'dart:convert';

import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

import 'pay_helpers.dart';

void main() {
  group('money helpers', () {
    test('half-up division, half away from zero', () {
      expect(divRoundHalfUp(5, 10), 1); // 0.5 -> 1
      expect(divRoundHalfUp(4, 10), 0);
      expect(divRoundHalfUp(15, 10), 2); // 1.5 -> 2
      expect(divRoundHalfUp(25, 10), 3); // 2.5 -> 3 (not banker's 2)
      expect(divRoundHalfUp(-5, 10), -1);
      expect(divRoundHalfUp(-4, 10), 0);
      expect(() => divRoundHalfUp(1, 0), throwsArgumentError);
    });

    test('minutes to hundredths of an hour', () {
      expect(minutesToHundredths(60), 100);
      expect(minutesToHundredths(90), 150);
      expect(minutesToHundredths(20), 33); // 33.33
      expect(minutesToHundredths(40), 67); // 66.67
      expect(minutesToHundredths(1), 2); // 1.67
      expect(minutesToHundredths(2401), 4002); // 40.0167
    });

    test('amount for minutes rounds once to the cent', () {
      expect(amountForMinutes(360, 1500), 9000);
      expect(amountForMinutes(1, 1500), 25);
      expect(amountForMinutes(20, 1001), 334); // 333.67
      expect(amountForMinutes(7, 1000), 117); // 116.67
    });

    test('formatting is fixed-point with no locale', () {
      expect(formatCents(123456789), '1234567.89');
      expect(formatCents(5), '0.05');
      expect(formatCents(-5), '-0.05');
      expect(formatCents(0), '0.00');
      expect(formatHundredths(4002), '40.02');
      expect(formatE4(231667), '23.1667');
      expect(formatE4(231667, decimals: 2), '23.17');
      expect(formatE4(57550, decimals: 2), '5.76'); // 5.755 half-up
    });

    test('parsing decimal strings is exact; doubles are read to their decimal value', () {
      expect(parseCents('0.29'), 29);
      expect(parseCents('1234.5'), 123450);
      expect(parseCents('-12.345'), -1235); // extra digits half-up
      expect(parseCents(0.29), 29);
      expect(parseCents(2.675), 268);
      expect(parseCents(15), 1500);
      expect(parseScaled('23.1667', 4), 231667);
      expect(() => parseCents('12a'), throwsFormatException);
    });

    test('largest remainder adds up exactly, ties to the lower index', () {
      expect(splitByLargestRemainder(10000, [1, 1, 1]), [3334, 3333, 3333]);
      expect(splitByLargestRemainder(10001, [1, 1, 1]), [3334, 3334, 3333]);
      expect(splitByLargestRemainder(100, [0, 1, 0]), [0, 100, 0]);
      expect(splitByLargestRemainder(0, [0, 0]), [0, 0]);
      expect(() => splitByLargestRemainder(5, [0, 0]), throwsArgumentError);
      // 7 cents by 1:2 -> 2.33 and 4.67 -> 2 and 5.
      expect(splitByLargestRemainder(7, [1, 2]), [2, 5]);
    });

    test('roundPreservingTotal keeps the rounded total', () {
      // Three 20-minute lines: 33.33 each, total 100.
      expect(roundPreservingTotal([2000, 2000, 2000], 60), [34, 33, 33]);
      // Three 5h20m lines: 533.33 each, total 1600.
      expect(roundPreservingTotal([32000, 32000, 32000], 60), [534, 533, 533]);
      expect(roundPreservingTotal([6000, 3000], 60), [100, 50]);
    });
  });

  group('PayRules', () {
    test('Texas defaults', () {
      const r = PayRules.texasDefaults;
      expect(r.minimumWageCents, 725);
      expect(r.tipCredit.enabled, isFalse);
      expect(r.tipCredit.cashWageCents, 213);
      expect(r.tipCreditCents, 512);
      expect(r.overtimeMultiplierThousandths, 1500);
      expect(r.tipPool.method, 'hours');
      expect(r.tipPool.eligibleRoles, ['bartender', 'runner', 'cook', 'cashier']);
      expect(r.tipPool.eligibleRoles, isNot(contains('lead')));
      expect(r.paydayDaysAfterEnd, 5);
      expect(r.laborBurdenBasisPoints, 0);
      expect(r.complianceNotes(), isEmpty);
    });

    test('fromJson reads every setting, and round-trips', () {
      final r = PayRules.fromJson({
        'minimum_wage': 7.25,
        'tip_credit': {'enabled': true, 'cash_wage': '2.13'},
        'overtime_multiplier': 1.5,
        'tip_pool': {
          'method': 'role_points',
          'eligible_roles': ['bartender', 'lead'],
        },
        'payday_days_after_end': 6,
        'labor_burden_percent': 7.65,
      });
      expect(r.tipCredit.enabled, isTrue);
      expect(r.tipCredit.cashWageCents, 213);
      expect(r.tipPool.method, 'role_points');
      expect(r.paydayDaysAfterEnd, 6);
      expect(r.laborBurdenBasisPoints, 765);
      expect(r.complianceNotes().single, contains('Leads are in the tip pool'));
      final again = PayRules.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
      expect(again.laborBurdenBasisPoints, 765);
      expect(again.tipPool.eligibleRoles, ['bartender', 'lead']);
    });

    test('fromVenueSettings reads payday lag from pay, else pay_period (as ensure_pay_periods does)', () {
      expect(
          PayRules.fromVenueSettings({
            'pay_period': {'frequency': 'biweekly', 'payday_days_after_end': 4},
          }).paydayDaysAfterEnd,
          4);
      expect(
          PayRules.fromVenueSettings({
            'pay': {'payday_days_after_end': 3},
            'pay_period': {'payday_days_after_end': 4},
          }).paydayDaysAfterEnd,
          3);
      expect(PayRules.fromVenueSettings({}).paydayDaysAfterEnd, 5);
    });

    test('compliance notes for settings below federal floors', () {
      final notes = PayRules.fromJson({
        'minimum_wage': 7.00,
        'tip_credit': {'enabled': true, 'cash_wage': 2.00},
        'overtime_multiplier': 1.25,
      }).complianceNotes();
      expect(notes.length, 3);
    });
  });

  group('model JSON keys match 0009_pay.sql columns', () {
    Set<String> keys(Map<String, dynamic> j) => j.keys.toSet();

    test('pay_period_lines', () {
      final l = PayLine(
        venueId: 'v1',
        payPeriodId: 'pp1',
        workerId: 'w1',
        workDate: day(2026, 11, 10),
        eventId: 'e1',
        storefrontId: 'sf1',
        jobRoleCode: 'cashier',
        payCode: 'OT',
        hoursHundredths: 500,
        rateE4: 231667,
        amountCents: 11583,
      );
      final j = l.toJson();
      expect(keys(j), {
        'venue_id', 'pay_period_id', 'worker_id', 'work_date', 'event_id', 'storefront_id', 'job_role_code', //
        'pay_code', 'hours', 'rate', 'amount',
      });
      expect(j['hours'], 5.0);
      expect(j['rate'], 23.1667);
      expect(j['amount'], 115.83);
      expect(j['work_date'], '2026-11-10');
      final back = PayLine.fromJson(jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
      expect(back.amountCents, 11583);
      expect(back.rateE4, 231667);
      expect(back.hoursHundredths, 500);
      // Postgres numeric can also arrive as a string.
      expect(PayLine.fromJson({...j, 'amount': '115.83', 'rate': '23.1667', 'hours': '5.00'}).amountCents, 11583);
    });

    test('every pay table', () {
      expect(keys(PayCode(venueId: 'v', code: 'REG', name: 'Regular', kind: PayCodeKind.regular).toJson()),
          {'venue_id', 'code', 'name', 'kind', 'paycom_code', 'sort'});
      expect(keys(rate('r', 1500, role: 'cashier').toJson()), {
        'id', 'venue_id', 'worker_id', 'job_role_code', 'event_type_code', 'hourly_rate', 'effective_from', //
        'effective_to', 'note',
      });
      expect(
          keys(PayDifferential(
                  id: 'd', venueId: 'v', name: 'Lead', payCode: 'LEAD', effectiveFrom: day(2026, 1, 1), perHourCents: 200)
              .toJson()),
          {
            'id', 'venue_id', 'name', 'pay_code', 'job_role_code', 'worker_id', 'event_type_code', 'per_hour', //
            'per_shift', 'effective_from', 'effective_to',
          });
      expect(keys(PayPeriod(id: 'p', venueId: 'v', startsOn: day(2026, 11, 9), endsOn: day(2026, 11, 22), payDate: day(2026, 11, 27)).toJson()), {
        'id', 'venue_id', 'starts_on', 'ends_on', 'pay_date', 'status', 'approved_by', 'approved_at', 'rules_version',
      });
      expect(
          keys(TipPool(id: 't', venueId: 'v', eventId: 'e', amountCents: 100, rolePointsThousandths: const {'bartender': 1000})
              .toJson()),
          {'id', 'venue_id', 'event_id', 'storefront_id', 'amount', 'source', 'method', 'role_points', 'status', 'note'});
      expect(keys(const TipAllocation(poolId: 't', venueId: 'v', workerId: 'w', amountCents: 1).toJson()),
          {'pool_id', 'venue_id', 'worker_id', 'hours', 'points', 'amount'});
      expect(
          keys(AgencyBillRate(
                  id: 'b', venueId: 'v', agencyId: 'a', jobRoleCode: 'cashier', billRateCents: 2000, effectiveFrom: day(2026, 1, 1))
              .toJson()),
          {
            'id', 'venue_id', 'agency_id', 'job_role_code', 'bill_rate', 'overtime_bill_rate', 'effective_from', //
            'effective_to',
          });
      expect(keys(NpoAgreement(id: 'a', venueId: 'v', hourlyRateCents: 1000, effectiveFrom: day(2026, 1, 1)).toJson()), {
        'id', 'venue_id', 'npo_group_id', 'hourly_rate', 'min_headcount', 'shortfall_deduction', 'no_show_deduction', //
        'effective_from', 'effective_to',
      });
      expect(keys(const NpoPayout(eventId: 'e', npoGroupId: 'g').toJson()), {
        'event_id', 'npo_group_id', 'members_scheduled', 'members_worked', 'no_shows', 'hours', 'hourly_rate', //
        'gross', 'deductions', 'adjustment', 'adjustment_reason', 'total', 'status', 'approved_by', 'approved_at', //
        'paid_at', 'payment_reference', 'detail',
      });
      expect(
          keys(const TimeCorrection(id: 'c', venueId: 'v', workerId: 'w', action: 'void', punchId: 'p', reason: 'dup')
              .toJson()),
          {
            'id', 'venue_id', 'worker_id', 'event_id', 'action', 'punch_id', 'new_kind', 'new_break_kind', //
            'new_occurred_at', 'reason', 'status', 'decided_by', 'decided_at', 'decision_note', 'result_punch_id',
          });
    });

    test('round trips', () {
      final pool = TipPool.fromJson({
        'id': 't1',
        'venue_id': 'v1',
        'event_id': 'e1',
        'storefront_id': null,
        'amount': 100.01,
        'method': 'role_points',
        'role_points': {'bartender': 1.0, 'runner': 0.5},
      });
      expect(pool.amountCents, 10001);
      expect(pool.rolePointsThousandths, {'bartender': 1000, 'runner': 500});
      final payout = NpoPayout.fromJson({
        'event_id': 'e1',
        'npo_group_id': 'g1',
        'total': '135.00',
        'detail': [
          {'worker_id': 'm1', 'hours': 5.0},
        ],
      });
      expect(payout.totalCents, 13500);
      expect(payout.detail.single.minutes, 300);
      final bill = AgencyBillRate.fromJson({
        'id': 'b',
        'venue_id': 'v',
        'agency_id': 'a',
        'job_role_code': 'cashier',
        'bill_rate': 20,
        'overtime_bill_rate': null,
        'effective_from': '2026-01-01',
      });
      expect(bill.overtimeBillRateCents, isNull);
      expect(bill.billRateCents, 2000);
      final tc = TimeCorrection.fromJson({
        'id': 'c',
        'venue_id': 'v',
        'worker_id': 'w',
        'action': 'replace',
        'punch_id': 'p',
        'new_occurred_at': '2026-11-10T22:00:00Z',
        'reason': 'Forgot to clock out',
      });
      expect(tc.newOccurredAt, DateTime.utc(2026, 11, 10, 22));
      expect(tc.toJson()['new_occurred_at'], '2026-11-10T22:00:00.000Z');
    });
  });
}
