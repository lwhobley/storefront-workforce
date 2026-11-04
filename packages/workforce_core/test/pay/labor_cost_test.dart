import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

import 'pay_helpers.dart';

void main() {
  PayLine line(String w, String? sf, String code, int cents, {String event = 'e1'}) => PayLine(
    workerId: w,
    workDate: day(2026, 11, 10),
    eventId: event,
    storefrontId: sf,
    payCode: code,
    amountCents: cents,
  );
  AgencyInvoiceLine temp(String? sf, int cents, {String event = 'e1'}) => AgencyInvoiceLine(
    agencyId: 'a1',
    workerId: 't1',
    firstWorkDate: day(2026, 11, 10),
    eventId: event,
    storefrontId: sf,
    jobRoleCode: 'cashier',
    regularMinutes: 600,
    overtimeMinutes: 0,
    billRateCents: 2000,
    overtimeBillRateCents: 2000,
    regularAmountCents: cents,
    overtimeAmountCents: 0,
  );

  final payLines = [
    line('w1', 'sf1', 'REG', 12000),
    line('w1', 'sf1', 'OT', 2250),
    line('w1', 'sf1', 'TIPS', 3000),
    line('w2', 'sf2', 'REG', 9000),
    line('w3', null, 'REG', 5000),
    line('w9', 'sf1', 'REG', 99999, event: 'other'), // another event: ignored
  ];
  const payout = NpoPayout(eventId: 'e1', npoGroupId: 'g2', totalCents: 13500);

  LaborCostReport report({int? actual = 100, int expected = 150}) => calculateLaborCost(
    event: event('e1', ct(2026, 11, 10, 19), expected: expected, actual: actual),
    payRules: const PayRules(laborBurdenBasisPoints: 1000), // 10%
    payLines: payLines,
    agencyLines: [
      temp('sf1', 20000),
      temp('sf2', 5555, event: 'other'),
    ],
    npoPayouts: [payout],
    npoMinutes: {
      'g2': {'sf1': 120, 'sf2': 240},
    },
    eventBudgetCents: 65000,
    storefrontBudgetsCents: {'sf1': 40000, 'sf2': 25000},
  );

  test('per storefront and total, tips separate, NPO split by hours', () {
    // sf1: payroll 120 + 22.50 = 142.50, burden 14.25, temp 200, NPO 135 x 120/360 = 45 -> $401.75; tips 30.
    // sf2: payroll 90, burden 9, NPO 90 -> $189.00.
    // unassigned: payroll 50, burden 5 -> $55.00.
    // Event: 401.75 + 189 + 55 = $645.75.
    final r = report();
    expect(r.storefronts.map((s) => s.storefrontId), ['sf1', 'sf2', null]);
    final sf1 = r.storefront('sf1')!;
    expect(sf1.payrollCents, 14250);
    expect(sf1.burdenCents, 1425);
    expect(sf1.tempCents, 20000);
    expect(sf1.npoCents, 4500);
    expect(sf1.tipsCents, 3000);
    expect(sf1.totalCents, 40175);
    expect(r.storefront('sf2')!.totalCents, 18900);
    expect(r.storefront(null)!.totalCents, 5500);
    expect(r.total.totalCents, 64575);
    expect(r.total.tipsCents, 3000);
    expect(r.total.npoCents, 13500);
    expect(r.storefronts.fold(0, (s, x) => s + x.totalCents), r.total.totalCents);
  });

  test('cost per attendee: actual attendance, else expected', () {
    // 645.75 / 100 = $6.4575 -> $6.46.
    expect(report().costPerAttendeeCents, 646);
    expect(report().attendanceIsActual, isTrue);
    // 645.75 / 150 = 4.305 -> $4.31 (half-up).
    final r = report(actual: null);
    expect(r.attendance, 150);
    expect(r.attendanceIsActual, isFalse);
    expect(r.costPerAttendeeCents, 431);
    expect(report(actual: null, expected: 0).costPerAttendeeCents, isNull);
  });

  test('budget status: under / near (within 5%) / over', () {
    final r = report();
    expect(r.total.status, BudgetStatus.near); // 645.75 vs 650: within 5%
    expect(r.total.varianceCents, 425);
    expect(r.storefront('sf1')!.status, BudgetStatus.over); // 401.75 > 400
    expect(r.storefront('sf2')!.status, BudgetStatus.under); // 189 < 237.50
    expect(r.storefront(null)!.status, isNull);
    expect(budgetStatus(9500, 10000), BudgetStatus.near);
    expect(budgetStatus(9499, 10000), BudgetStatus.under);
    expect(budgetStatus(10000, 10000), BudgetStatus.near);
    expect(budgetStatus(10001, 10000), BudgetStatus.over);
    expect(budgetStatus(0, 0), BudgetStatus.under);
    expect(budgetStatus(1, 0), BudgetStatus.over);
    expect(budgetStatus(1, null), isNull);
  });

  test('NPO payout with no minutes is unassigned; split always adds up', () {
    final r = calculateLaborCost(
      event: event('e1', ct(2026, 11, 10, 19)),
      payRules: PayRules.texasDefaults,
      npoPayouts: [
        const NpoPayout(eventId: 'e1', npoGroupId: 'g1', totalCents: 1000),
        const NpoPayout(eventId: 'e1', npoGroupId: 'g3', totalCents: 500),
      ],
      npoMinutes: {
        'g1': {'a': 1, 'b': 1, 'c': 1},
      },
    );
    // $10.00 / 3 storefronts = 3.34 / 3.33 / 3.33; g3 has no minutes: unassigned.
    expect({for (final s in r.storefronts) s.storefrontId: s.npoCents}, {'a': 334, 'b': 333, 'c': 333, null: 500});
    expect(r.total.npoCents, 1500);
    expect(r.costPerAttendeeCents, isNull);
  });

  test('npoMinutesByStorefront from shifts and punches', () {
    final ev = event('e1', ct(2026, 11, 10, 19));
    final m1 = worker('m1', type: WorkerType.npo, npoGroupId: 'g2');
    final m2 = worker('m2', type: WorkerType.npo, npoGroupId: 'g2');
    final mins = npoMinutesByStorefront(
      event: ev,
      members: [m1, m2, worker('r1')],
      shifts: [
        shift('s1', workerId: 'm1', eventId: 'e1', call: ct(2026, 11, 10, 16), storefrontId: 'sf1'),
        shift('s2', workerId: 'm2', eventId: 'e1', call: ct(2026, 11, 10, 16), storefrontId: 'sf2'),
      ],
      punchesByWorker: {
        'm1': worked('m1', ct(2026, 11, 10, 16), ct(2026, 11, 10, 18), eventId: 'e1'),
        'm2': worked('m2', ct(2026, 11, 10, 16), ct(2026, 11, 10, 20), eventId: 'e1'),
        'r1': worked('r1', ct(2026, 11, 10, 16), ct(2026, 11, 10, 20), eventId: 'e1'),
      },
      timeZone: tz,
    );
    expect(mins, {
      'g2': {'sf1': 120, 'sf2': 240},
    });
  });
}
