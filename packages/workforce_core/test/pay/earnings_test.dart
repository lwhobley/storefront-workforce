import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

import 'pay_helpers.dart';

/// One shift: event, role, clock in, clock out.
typedef Spec = ({
  String event,
  String role,
  DateTime inAt,
  DateTime outAt,
  List<(DateTime, DateTime, BreakKind)> breaks,
  String storefront,
});

Spec s(String event, String role, DateTime inAt, DateTime outAt,
        {List<(DateTime, DateTime, BreakKind)> breaks = const [], String storefront = 'sf1'}) =>
    (event: event, role: role, inAt: inAt, outAt: outAt, breaks: breaks, storefront: storefront);

/// A worker with one shift (and punches tied to it) per spec.
WorkerPayInput staff(Worker w, List<Spec> specs) {
  final shifts = <Shift>[];
  final punches = <Punch>[];
  for (final sp in specs) {
    final id = 'sh-${w.id}-${sp.event}';
    shifts.add(shift(id, workerId: w.id, eventId: sp.event, call: sp.inAt, storefrontId: sp.storefront, role: sp.role));
    punches.addAll(worked(w.id, sp.inAt, sp.outAt, eventId: sp.event, shiftId: id, breaks: sp.breaks));
  }
  return WorkerPayInput(worker: w, punches: punches, shifts: shifts);
}

Map<String, Event> eventsFor(List<WorkerPayInput> inputs, {Map<String, String> types = const {}}) => {
      for (final i in inputs)
        for (final sh in i.shifts) sh.eventId: event(sh.eventId, sh.callTime, type: types[sh.eventId] ?? 'game'),
    };

final cashier15 = rate('cashier', 1500, role: 'cashier');
final cook18 = rate('cook', 1800, role: 'cook');
final lead15 = rate('lead', 1500, role: 'lead');

EarningsResult run(
  List<WorkerPayInput> inputs, {
  List<PayRate>? rates,
  PayPeriod? period,
  VenueRules rules = texas,
  PayRules pay = PayRules.texasDefaults,
  List<PayDifferential> differentials = const [],
  List<TipPool> tipPools = const [],
  List<TipAllocation> tipAllocations = const [],
  Set<String> tipCreditWorkers = const {},
  Map<String, JobRole> jobRoles = const {},
  Map<String, String> eventTypes = const {},
  Map<String, Event>? events,
}) =>
    calculateEarnings(
      timeZone: tz,
      venueRules: rules,
      payRules: pay,
      period: period ?? novPeriod,
      workers: inputs,
      events: events ?? eventsFor(inputs, types: eventTypes),
      rates: rates ?? [cashier15, cook18, lead15],
      differentials: differentials,
      tipPools: tipPools,
      tipAllocations: tipAllocations,
      tipCreditWorkers: tipCreditWorkers,
      jobRoles: jobRoles,
    );

/// (code, date, hundredths, rateE4, cents) for compact assertions.
List<(String, String, int, int?, int)> shape(Iterable<PayLine> lines) =>
    [for (final l in lines) (l.payCode, formatDate(l.workDate), l.hoursHundredths, l.rateE4, l.amountCents)];

void main() {
  final w1 = worker('w1');

  group('basic hours', () {
    test('a simple 6-hour shift', () {
      // Tue Nov 10 16:00-22:00 = 6.00h x $15.00 = $90.00.
      final r = run([
        staff(w1, [s('e10', 'cashier', ct(2026, 11, 10, 16), ct(2026, 11, 10, 22))])
      ]);
      expect(shape(r.lines), [('REG', '2026-11-10', 600, 150000, 9000)]);
      final l = r.lines.single;
      expect(l.eventId, 'e10');
      expect(l.storefrontId, 'sf1');
      expect(l.jobRoleCode, 'cashier');
      expect(r.problems, isEmpty);
      expect(sumCents(r.lines), 9000);
      expect(r.worker('w1')!.grossCents, 9000);
      expect(r.worker('w1')!.regularMinutes, 360);
    });

    test('paid 10-minute rest break counts; unpaid 30-minute meal does not', () {
      // 16:00-23:00 is 420 min; rest 18:00-18:10 is paid; meal 19:30-20:00 is not.
      // Paid 390 min = 6.50h x $15 = $97.50.
      final r = run([
        staff(w1, [
          s('e10', 'cashier', ct(2026, 11, 10, 16), ct(2026, 11, 10, 23), breaks: [
            (ct(2026, 11, 10, 18), ct(2026, 11, 10, 18, 10), BreakKind.rest),
            (ct(2026, 11, 10, 19, 30), ct(2026, 11, 10, 20), BreakKind.meal),
          ])
        ])
      ]);
      expect(shape(r.lines), [('REG', '2026-11-10', 650, 150000, 9750)]);
      expect(sumCents(r.lines), 9750);
    });

    test('a meal break of 20 minutes or less is paid (federal short-break rule)', () {
      // 420 min, 20-min meal is paid: 7.00h x $15 = $105.00.
      final r = run([
        staff(w1, [
          s('e10', 'cashier', ct(2026, 11, 10, 16), ct(2026, 11, 10, 23), breaks: [
            (ct(2026, 11, 10, 19, 30), ct(2026, 11, 10, 19, 50), BreakKind.meal),
          ])
        ])
      ]);
      expect(sumCents(r.lines), 10500);
      expect(r.lines.single.hoursHundredths, 700);
    });

    test('punches with no event are paid at the default role', () {
      final cook = worker('c1', roles: ['cook']);
      final r = run([
        WorkerPayInput(worker: cook, punches: worked('c1', ct(2026, 11, 10, 8), ct(2026, 11, 10, 12)))
      ]);
      // 4h x $18 = $72.00.
      expect(shape(r.lines), [('REG', '2026-11-10', 400, 180000, 7200)]);
      expect(r.lines.single.eventId, isNull);
    });

    test('voided punches are ignored', () {
      final punches = [
        punch('w1', PunchKind.clockIn, ct(2026, 11, 10, 15), eventId: 'e10', status: PunchStatus.voided),
        punch('w1', PunchKind.clockIn, ct(2026, 11, 10, 16), eventId: 'e10'),
        punch('w1', PunchKind.clockOut, ct(2026, 11, 10, 23), eventId: 'e10', status: PunchStatus.voided),
        punch('w1', PunchKind.clockOut, ct(2026, 11, 10, 22), eventId: 'e10'),
      ];
      final r = run([
        WorkerPayInput(worker: w1, punches: punches, shifts: [
          shift('sh', workerId: 'w1', eventId: 'e10', call: ct(2026, 11, 10, 16)),
        ])
      ]);
      // 16:00-22:00 = $90.00, not 15:00-23:00.
      expect(sumCents(r.lines), 9000);
      expect(r.problems, isEmpty);
    });

    test('open clock-in is reported and not paid; closed shifts are paid', () {
      final input = staff(w1, [s('e9', 'cashier', ct(2026, 11, 9, 16), ct(2026, 11, 9, 22))]);
      final open = punch('w1', PunchKind.clockIn, ct(2026, 11, 10, 16), eventId: 'e10', shiftId: 'sh-open');
      final r = run([
        WorkerPayInput(
          worker: w1,
          punches: [...input.punches, open],
          shifts: [...input.shifts, shift('sh-open', workerId: 'w1', eventId: 'e10', call: ct(2026, 11, 10, 16))],
        )
      ], events: {
        'e9': event('e9', ct(2026, 11, 9, 16)),
        'e10': event('e10', ct(2026, 11, 10, 16)),
      });
      expect(shape(r.lines), [('REG', '2026-11-09', 600, 150000, 9000)]);
      final p = r.problems.singleWhere((p) => p.kind == PayProblemKind.openClockIn);
      expect(p.isBlocking, isTrue);
      expect(p.shiftId, 'sh-open');
      expect(r.hasBlockingProblems, isTrue);
    });

    test('punch needing review is counted and blocks approval', () {
      final punches = [
        punch('w1', PunchKind.clockIn, ct(2026, 11, 10, 16), eventId: 'e10'),
        punch('w1', PunchKind.clockOut, ct(2026, 11, 10, 22), eventId: 'e10', status: PunchStatus.needsReview, id: 'pr'),
      ];
      final r = run([
        WorkerPayInput(worker: w1, punches: punches, shifts: [
          shift('sh', workerId: 'w1', eventId: 'e10', call: ct(2026, 11, 10, 16)),
        ])
      ]);
      expect(sumCents(r.lines), 9000);
      final p = r.problems.single;
      expect(p.kind, PayProblemKind.punchNeedsReview);
      expect(p.punchId, 'pr');
      expect(p.isBlocking, isTrue);
    });

    test('temps and NPO members produce no payroll lines', () {
      final temp = worker('t1', type: WorkerType.temp, agencyId: 'a1');
      final npo = worker('n1', type: WorkerType.npo, npoGroupId: 'g1');
      final r = run([
        staff(w1, [s('e10', 'cashier', ct(2026, 11, 10, 16), ct(2026, 11, 10, 22))]),
        staff(temp, [s('e10', 'cashier', ct(2026, 11, 10, 16), ct(2026, 11, 10, 22))]),
        staff(npo, [s('e10', 'cashier', ct(2026, 11, 10, 16), ct(2026, 11, 10, 22))]),
      ]);
      expect(r.lines.map((l) => l.workerId).toSet(), {'w1'});
      expect(r.excludedWorkerIds, ['t1', 'n1']);
      expect(r.workers.map((w) => w.workerId), ['w1']);
      expect(r.totalCents, 9000);
    });

    test('missing rate: line with rate null and \$0, blocking problem', () {
      final r = run([
        staff(w1, [s('e10', 'runner', ct(2026, 11, 10, 16), ct(2026, 11, 10, 22))])
      ]);
      expect(shape(r.lines), [('REG', '2026-11-10', 600, null, 0)]);
      final p = r.problems.single;
      expect(p.kind, PayProblemKind.missingRate);
      expect(p.isBlocking, isTrue);
      expect(p.workDate, day(2026, 11, 10));
    });

    test('rate below minimum wage is blocking', () {
      final r = run([
        staff(w1, [s('e10', 'cashier', ct(2026, 11, 10, 16), ct(2026, 11, 10, 22))])
      ], rates: [rate('low', 700, role: 'cashier')]);
      expect(r.problems.single.kind, PayProblemKind.belowMinimumWage);
      expect(sumCents(r.lines), 4200);
    });

    test('time clocked under two shifts at once is paid once and blocks', () {
      // A 16:00-20:00 and B 18:00-22:00: A keeps 16-20 (4h), B gets 20-22 (2h). 6h x $15 = $90.
      final r = run([
        staff(w1, [
          s('eA', 'cashier', ct(2026, 11, 10, 16), ct(2026, 11, 10, 20)),
          s('eB', 'cashier', ct(2026, 11, 10, 18), ct(2026, 11, 10, 22)),
        ])
      ]);
      expect(sumCents(r.lines), 9000);
      expect({for (final l in r.lines) l.eventId: l.hoursHundredths}, {'eA': 400, 'eB': 200});
      expect(r.problems.single.kind, PayProblemKind.overlappingTime);
      expect(r.problems.single.message, startsWith('120 minutes'));
    });
  });

  group('overtime and the regular rate', () {
    test('two roles, OT hours are the last hours (cashier): weighted regular rate', () {
      // Mon 9 cashier 10h, Tue 10 cashier 10h, Wed 11 cook 10h, Thu 12 cook 10h, Fri 13 cashier 5h = 45h.
      // Straight time: 25h x $15 + 20h x $18 = 375 + 360 = $735.00.
      // Regular rate = 735 / 45 = $16.3333. OT = 5h; premium = 5 x 0.5 x 16.3333 = $40.8333.
      // Week gross = 735 + 40.8333 = $775.8333 -> $775.83.
      // OT hours are Friday's 5 cashier hours: OT line = 5 x 15 + 40.8333 = $115.8333 -> $115.83,
      // line rate 115.8333 / 5 = $23.1667 (not 1.5 x 16.3333 = 24.50, because those hours were worked at $15).
      final r = run([
        staff(w1, [
          s('e9', 'cashier', ct(2026, 11, 9, 10), ct(2026, 11, 9, 20)),
          s('e10', 'cashier', ct(2026, 11, 10, 10), ct(2026, 11, 10, 20)),
          s('e11', 'cook', ct(2026, 11, 11, 10), ct(2026, 11, 11, 20)),
          s('e12', 'cook', ct(2026, 11, 12, 10), ct(2026, 11, 12, 20)),
          s('e13', 'cashier', ct(2026, 11, 13, 10), ct(2026, 11, 13, 15)),
        ])
      ]);
      expect(shape(r.lines), [
        ('REG', '2026-11-09', 1000, 150000, 15000),
        ('REG', '2026-11-10', 1000, 150000, 15000),
        ('REG', '2026-11-11', 1000, 180000, 18000),
        ('REG', '2026-11-12', 1000, 180000, 18000),
        ('OT', '2026-11-13', 500, 231667, 11583),
      ]);
      expect(sumCents(r.lines), 77583);
      final week = r.worker('w1')!.weeks.single;
      expect(week.totalMinutes, 2700);
      expect(week.overtimeMinutes, 300);
      expect(week.straightTimeCents, 73500);
      expect(week.regularRateE4, 163333);
      expect(week.overtimePremiumCents, 4083);
      expect(week.grossCents, 77583);
      expect(week.roundingAdjustmentCents, 0);
      final sum = r.worker('w1')!;
      expect(sum.regularMinutes, 2400);
      expect(sum.overtimeMinutes, 300);
      expect(sum.byPayCode['REG']!.amountCents, 66000);
      expect(sum.byPayCode['OT']!.hoursHundredths, 500);
    });

    test('same week, but the last hours are cook: same total, different lines', () {
      // Mon cashier 10h, Tue cashier 10h, Wed cashier 5h, Thu cook 10h, Fri cook 10h = 45h, $735 straight.
      // OT = Fri 15:00-20:00 cook: 5 x 18 + 40.8333 = $130.8333 -> $130.83 (rate $26.1667).
      // REG: 150 + 150 + 75 + 180 + Fri cook 5h 90 = $645. Total $775.83 again.
      // Paying "OT hours x 1.5 x regular rate" here (5 x 24.50 = 122.50) would total $767.50: $8.33 short.
      final r = run([
        staff(w1, [
          s('e9', 'cashier', ct(2026, 11, 9, 10), ct(2026, 11, 9, 20)),
          s('e10', 'cashier', ct(2026, 11, 10, 10), ct(2026, 11, 10, 20)),
          s('e11', 'cashier', ct(2026, 11, 11, 10), ct(2026, 11, 11, 15)),
          s('e12', 'cook', ct(2026, 11, 12, 10), ct(2026, 11, 12, 20)),
          s('e13', 'cook', ct(2026, 11, 13, 10), ct(2026, 11, 13, 20)),
        ])
      ]);
      expect(shape(r.lines), [
        ('REG', '2026-11-09', 1000, 150000, 15000),
        ('REG', '2026-11-10', 1000, 150000, 15000),
        ('REG', '2026-11-11', 500, 150000, 7500),
        ('REG', '2026-11-12', 1000, 180000, 18000),
        ('REG', '2026-11-13', 500, 180000, 9000),
        ('OT', '2026-11-13', 500, 261667, 13083),
      ]);
      expect(sumCents(r.lines), 77583);
    });

    test('lead differential is in the regular rate', () {
      // Lead $15 + LEAD $2/h; Mon-Thu 09:00-20:00 = 4 x 11h = 44h.
      // Straight: 44 x 15 = 660 + LEAD 44 x 2 = 88 -> $748. Regular rate 748 / 44 = $17.00.
      // OT 4h (Thu 16:00-20:00): premium 4 x 8.50 = $34. Gross $782.00.
      // REG 40h = $600 (Thu 7h = 105). OT line 4 x 15 + 34 = $94 (rate 23.50).
      // LEAD on all 44h = $88 (4 lines of 11h x 2 = $22). OT hour total: 15 + 2 + 8.50 = 25.50 = 1.5 x 17.
      final lead = worker('L1', roles: ['lead']);
      final r = run([
        staff(lead, [
          for (var d = 9; d <= 12; d++) s('e$d', 'lead', ct(2026, 11, d, 9), ct(2026, 11, d, 20)),
        ])
      ], differentials: [
        PayDifferential(
            id: 'lead', venueId: 'v1', name: 'Lead', payCode: 'LEAD', jobRoleCode: 'lead', perHourCents: 200,
            effectiveFrom: day(2026, 1, 1)),
      ]);
      expect(shape(r.lines), [
        ('REG', '2026-11-09', 1100, 150000, 16500),
        ('LEAD', '2026-11-09', 1100, 20000, 2200),
        ('REG', '2026-11-10', 1100, 150000, 16500),
        ('LEAD', '2026-11-10', 1100, 20000, 2200),
        ('REG', '2026-11-11', 1100, 150000, 16500),
        ('LEAD', '2026-11-11', 1100, 20000, 2200),
        ('REG', '2026-11-12', 700, 150000, 10500),
        ('OT', '2026-11-12', 400, 235000, 9400),
        ('LEAD', '2026-11-12', 1100, 20000, 2200),
      ]);
      expect(sumCents(r.lines), 78200);
      expect(r.worker('L1')!.weeks.single.regularRateE4, 170000);
    });

    test('per-shift bonus: BONUS line, and in the regular rate', () {
      // Mon-Thu game 10h ($600), Fri concert 17:00-19:00 (2h) with a $21 per-shift concert bonus.
      // Straight: 42 x 15 = 630 + 21 = $651; regular rate 651 / 42 = $15.50.
      // OT 2h (the concert): 2 x 15 + 2 x 0.5 x 15.50 = 30 + 15.50 = $45.50 (rate 22.75).
      // Gross 600 + 45.50 + 21 = $666.50.
      final r = run([
        staff(w1, [
          for (var d = 9; d <= 12; d++) s('e$d', 'cashier', ct(2026, 11, d, 9), ct(2026, 11, d, 19)),
          s('c13', 'cashier', ct(2026, 11, 13, 17), ct(2026, 11, 13, 19)),
        ])
      ], eventTypes: {
        'c13': 'concert'
      }, differentials: [
        PayDifferential(
            id: 'cb', venueId: 'v1', name: 'Concert bonus', payCode: 'BONUS', eventTypeCode: 'concert',
            perShiftCents: 2100, effectiveFrom: day(2026, 1, 1)),
      ]);
      expect(shape(r.lines).where((l) => l.$2 == '2026-11-13'), [
        ('OT', '2026-11-13', 200, 227500, 4550),
        ('BONUS', '2026-11-13', 0, null, 2100),
      ]);
      expect(linesOf(r.lines, 'BONUS').single.eventId, 'c13');
      expect(sumCents(r.lines), 66650);
      expect(r.worker('w1')!.weeks.single.regularRateE4, 155000);
    });

    test('per-shift bonus without overtime', () {
      // 6h concert: 90 + 21 = $111.00.
      final r = run([
        staff(w1, [s('c10', 'cashier', ct(2026, 11, 10, 16), ct(2026, 11, 10, 22))])
      ], eventTypes: {
        'c10': 'concert'
      }, differentials: [
        PayDifferential(
            id: 'cb', venueId: 'v1', name: 'Concert bonus', payCode: 'BONUS', eventTypeCode: 'concert',
            perShiftCents: 2100, effectiveFrom: day(2026, 1, 1)),
      ]);
      expect(shape(r.lines), [
        ('REG', '2026-11-10', 600, 150000, 9000),
        ('BONUS', '2026-11-10', 0, null, 2100),
      ]);
      expect(sumCents(r.lines), 11100);
    });

    test('exactly 40.00 hours has no overtime', () {
      final r = run([
        staff(w1, [for (var d = 9; d <= 13; d++) s('e$d', 'cashier', ct(2026, 11, d, 9), ct(2026, 11, d, 17))])
      ]);
      expect(linesOf(r.lines, 'OT'), isEmpty);
      expect(sumCents(r.lines), 60000);
      expect(r.worker('w1')!.byPayCode['REG']!.hoursHundredths, 4000);
    });

    test('40 hours and 1 minute: 1 minute of overtime', () {
      // Straight 2401 min x $15/60 = $600.25; premium 1 min x 7.50/60 = $0.125; gross $600.375 -> $600.38.
      // OT line: 1 min x 0.25 + 0.125 = $0.375 -> $0.38; hours 1/60 = 0.0167 -> 0.02; rate $22.50.
      final r = run([
        staff(w1, [
          for (var d = 9; d <= 12; d++) s('e$d', 'cashier', ct(2026, 11, d, 9), ct(2026, 11, d, 17)),
          s('e13', 'cashier', ct(2026, 11, 13, 9), ct(2026, 11, 13, 17, 1)),
        ])
      ]);
      expect(shape(r.lines).last, ('OT', '2026-11-13', 2, 225000, 38));
      expect(linesOf(r.lines, 'REG').map((l) => l.amountCents), [12000, 12000, 12000, 12000, 12000]);
      expect(sumCents(r.lines), 60038);
      expect(r.worker('w1')!.overtimeMinutes, 1);
      expect(r.worker('w1')!.weeks.single.grossCents, 60038);
    });

    test('daily overtime when the venue sets a daily threshold', () {
      // Daily 8h: one 10h day -> REG 8h $120, OT the last 2h at $22.50 = $45. Total $165.
      const daily = VenueRules(overtime: OvertimeRules(dailyThresholdHours: 8));
      final r = run([
        staff(w1, [s('e10', 'cashier', ct(2026, 11, 10, 9), ct(2026, 11, 10, 19))])
      ], rules: daily);
      expect(shape(r.lines), [
        ('REG', '2026-11-10', 800, 150000, 12000),
        ('OT', '2026-11-10', 200, 225000, 4500),
      ]);
      expect(sumCents(r.lines), 16500);
    });
  });

  group('rounding reconciliation', () {
    test('remainder goes on the last REG line when there is no OT', () {
      // $10.01/h, three 20-minute shifts: each 333.67c -> 334c, sum 1002c; exact week 60 min = 1001c.
      // The last REG line (Wed) takes -1c. Hours: 0.3333 each -> 0.34 / 0.33 / 0.33 = 1.00 total.
      final r = run([
        staff(w1, [
          for (var d = 9; d <= 11; d++) s('e$d', 'cashier', ct(2026, 11, d, 16), ct(2026, 11, d, 16, 20)),
        ])
      ], rates: [
        rate('odd', 1001, role: 'cashier')
      ]);
      expect(shape(r.lines), [
        ('REG', '2026-11-09', 34, 100100, 334),
        ('REG', '2026-11-10', 33, 100100, 334),
        ('REG', '2026-11-11', 33, 100100, 333),
      ]);
      expect(r.lines.last.roundingAdjustmentCents, -1);
      expect(sumCents(r.lines), 1001);
      expect(r.worker('w1')!.weeks.single.roundingAdjustmentCents, -1);
    });

    test('remainder goes on the last OT line', () {
      // $10.01/h; Mon-Thu 10h (4 x $100.10) + Sat 1h + Sun 1h = 42h, OT = Sat and Sun.
      // Each OT hour: 10.01 + 5.005 = $15.015 -> $15.02; exact OT 2 x 15.015 = $30.03.
      // Week exact 400.40 + 30.03 = $430.43; lines 400.40 + 15.02 + 15.02 = 430.44 -> Sun takes -1c.
      final r = run([
        staff(w1, [
          for (var d = 9; d <= 12; d++) s('e$d', 'cashier', ct(2026, 11, d, 9), ct(2026, 11, d, 19)),
          s('e14', 'cashier', ct(2026, 11, 14, 12), ct(2026, 11, 14, 13)),
          s('e15', 'cashier', ct(2026, 11, 15, 12), ct(2026, 11, 15, 13)),
        ])
      ], rates: [
        rate('odd', 1001, role: 'cashier')
      ]);
      final ot = linesOf(r.lines, 'OT');
      expect(ot.map((l) => l.amountCents), [1502, 1501]);
      expect(ot.last.roundingAdjustmentCents, -1);
      expect(ot.last.workDate, day(2026, 11, 15));
      expect(sumCents(r.lines), 43043);
      expect(r.worker('w1')!.weeks.single.grossCents, 43043);
    });

    test('line hours add up to the true hours', () {
      // Three 5h20m shifts: 5.3333h each; rounded alone 5.33 x 3 = 15.99, but true total is 16.00.
      // Amounts: 320 min x $15 = $80.00 each.
      final r = run([
        staff(w1, [
          for (var d = 9; d <= 11; d++) s('e$d', 'cashier', ct(2026, 11, d, 16), ct(2026, 11, d, 21, 20)),
        ])
      ]);
      expect(r.lines.map((l) => l.hoursHundredths), [534, 533, 533]);
      expect(r.worker('w1')!.byPayCode['REG']!.hoursHundredths, 1600);
      expect(sumCents(r.lines), 24000);
    });
  });

  group('workweek and calendar edges', () {
    test('overnight shift crossing midnight and the workweek boundary', () {
      // Mon-Thu 10h = 40h, then Sun Nov 15 20:00 to Mon Nov 16 04:00.
      // Week 1 gets Sun 20:00-24:00 = 4h, all OT: 4 x 22.50 = $90 dated Nov 15.
      // Week 2 gets Mon 00:00-04:00 = 4h REG: $60 dated Nov 16. Total 600 + 90 + 60 = $750.
      final r = run([
        staff(w1, [
          for (var d = 9; d <= 12; d++) s('e$d', 'cashier', ct(2026, 11, d, 9), ct(2026, 11, d, 19)),
          s('late', 'cashier', ct(2026, 11, 15, 20), ct(2026, 11, 16, 4)),
        ])
      ]);
      final late = [
        for (final l in r.lines)
          if (l.eventId == 'late') l
      ];
      expect(shape(late), [
        ('OT', '2026-11-15', 400, 225000, 9000),
        ('REG', '2026-11-16', 400, 150000, 6000),
      ]);
      expect(sumCents(r.lines), 75000);
      expect(r.worker('w1')!.weeks.length, 2);
      expect(r.worker('w1')!.weeks[1].overtimeMinutes, 0);
    });

    test('daylight saving: fall-back week counts the extra real hour', () {
      // Period Mon Oct 26 - Sun Nov 8, 2026. Mon-Thu 09:00-18:00 = 36h.
      // Sat Oct 31 22:00 CDT to Sun Nov 1 06:00 CST = 9 real hours: 2h on Sat, 7h on the 25-hour Sunday.
      // Week = 45h; OT = the last 5h (all Sunday). Sun: REG 2h $30, OT 5h x 22.50 = $112.50.
      // Total 36 x 15 + 30 + 30 + 112.50 = $712.50 = 45 x 15 + 5 x 7.50.
      final period = PayPeriod(startsOn: day(2026, 10, 26), endsOn: day(2026, 11, 8), payDate: day(2026, 11, 13));
      final r = run([
        staff(w1, [
          for (var d = 26; d <= 29; d++) s('e$d', 'cashier', ct(2026, 10, d, 9), ct(2026, 10, d, 18)),
          s('dst', 'cashier', ct(2026, 10, 31, 22), ct(2026, 11, 1, 6)),
        ])
      ], period: period);
      final dst = [
        for (final l in r.lines)
          if (l.eventId == 'dst') l
      ];
      expect(shape(dst), [
        ('REG', '2026-10-31', 200, 150000, 3000),
        ('REG', '2026-11-01', 200, 150000, 3000),
        ('OT', '2026-11-01', 500, 225000, 11250),
      ]);
      expect(sumCents(r.lines), 71250);
      expect(r.problems, isEmpty);
    });

    test('a workweek spanning two pay periods is reported, and the two periods add up', () {
      // Weekly periods anchored on Wednesday: P1 Wed Nov 4 - Tue Nov 10, P2 Wed Nov 11 - Tue Nov 17.
      // The Mon Nov 9 workweek straddles them. Mon-Thu 10h + Fri 5h = 45h at $15:
      // week = 45 x 15 + 5 x 7.50 = $712.50. P1 pays Mon + Tue = $300; P2 pays Wed + Thu + OT Fri = $412.50.
      final p1 = PayPeriod(startsOn: day(2026, 11, 4), endsOn: day(2026, 11, 10), payDate: day(2026, 11, 15));
      final p2 = PayPeriod(startsOn: day(2026, 11, 11), endsOn: day(2026, 11, 17), payDate: day(2026, 11, 22));
      final input = staff(w1, [
        for (var d = 9; d <= 12; d++) s('e$d', 'cashier', ct(2026, 11, d, 9), ct(2026, 11, d, 19)),
        s('e13', 'cashier', ct(2026, 11, 13, 9), ct(2026, 11, 13, 14)),
      ]);
      final r1 = run([input], period: p1);
      final r2 = run([input], period: p2);
      expect(sumCents(r1.lines), 30000);
      expect(sumCents(r2.lines), 41250);
      expect(sumCents(r1.lines) + sumCents(r2.lines), 71250);
      expect(linesOf(r2.lines, 'OT').single.amountCents, 11250);
      for (final r in [r1, r2]) {
        final p = r.problems.singleWhere((p) => p.kind == PayProblemKind.periodNotAlignedToWorkweeks);
        expect(p.isBlocking, isFalse);
        expect(r.worker('w1')!.weeks.single.withinPeriod, isFalse);
      }
      // The aligned biweekly period reports nothing.
      expect(run([input]).problems, isEmpty);
    });
  });

  group('tips and tip credit', () {
    final bartender = worker('b1', roles: ['bartender']);
    const tipCreditOn = PayRules(tipCredit: TipCreditRules(enabled: true));
    TipPool pool(String id, String eventId, int cents, {String? storefront}) =>
        TipPool(id: id, venueId: 'v1', eventId: eventId, amountCents: cents, storefrontId: storefront);
    TipAllocation alloc(String poolId, String workerId, int cents) =>
        TipAllocation(poolId: poolId, venueId: 'v1', workerId: workerId, amountCents: cents);
    final threeDays = [
      for (var d = 9; d <= 11; d++) s('e$d', 'bartender', ct(2026, 11, d, 10), ct(2026, 11, d, 20)),
    ];

    test('one TIPS line per worker per date, amount only', () {
      // Two pools at the same event (two storefronts): $30 + $20 -> one $50 line on Mon.
      final r = run([
        staff(w1, [s('e9', 'cashier', ct(2026, 11, 9, 16), ct(2026, 11, 9, 22))])
      ], tipPools: [
        pool('p1', 'e9', 3000, storefront: 'sf1'),
        pool('p2', 'e9', 2000, storefront: 'sf2'),
      ], tipAllocations: [
        alloc('p1', 'w1', 3000),
        alloc('p2', 'w1', 2000),
      ]);
      final tips = linesOf(r.lines, 'TIPS').single;
      expect(tips.amountCents, 5000);
      expect(tips.hoursHundredths, 0);
      expect(tips.rateE4, isNull);
      expect(tips.eventId, 'e9');
      expect(tips.storefrontId, isNull);
      expect(sumCents(r.lines), 9000 + 5000);
      expect(r.worker('w1')!.tipsCents, 5000);
      expect(r.worker('w1')!.wagesCents, 9000);
    });

    test('tips allocated to a temp are reported, not paid', () {
      final temp = worker('t1', type: WorkerType.temp);
      final r = run([
        staff(temp, [s('e9', 'cashier', ct(2026, 11, 9, 16), ct(2026, 11, 9, 22))])
      ], tipPools: [
        pool('p1', 'e9', 3000)
      ], tipAllocations: [
        alloc('p1', 't1', 3000)
      ]);
      expect(r.lines, isEmpty);
      expect(r.problems.single.kind, PayProblemKind.tipsForNonPayrollWorker);
    });

    test('tip credit make-up when tips do not cover the credit', () {
      // 30h bartending at cash wage $2.13 = $63.90. Credit taken 30 x 5.12 = $153.60; tips $100.
      // TIPMU = 153.60 - 100 = $53.60. Check: 63.90 + 100 + 53.60 = $217.50 = 30 x 7.25.
      final r = run([
        staff(bartender, threeDays)
      ], pay: tipCreditOn, tipCreditWorkers: {
        'b1'
      }, tipPools: [
        pool('p1', 'e9', 10000)
      ], tipAllocations: [
        alloc('p1', 'b1', 10000)
      ], rates: [
        rate('bt', 1000, role: 'bartender')
      ]);
      expect(shape(r.lines), [
        ('REG', '2026-11-09', 1000, 21300, 2130),
        ('TIPS', '2026-11-09', 0, null, 10000),
        ('REG', '2026-11-10', 1000, 21300, 2130),
        ('REG', '2026-11-11', 1000, 21300, 2130),
        ('TIPMU', '2026-11-11', 0, null, 5360),
      ]);
      expect(sumCents(r.lines), 21750);
      final week = r.worker('b1')!.weeks.single;
      expect(week.tipCreditTakenCents, 15360);
      expect(week.tipsCents, 10000);
      expect(week.tipMakeupCents, 5360);
    });

    test('no make-up when tips cover the credit', () {
      final r = run([staff(bartender, threeDays)],
          pay: tipCreditOn,
          tipCreditWorkers: {'b1'},
          tipPools: [pool('p1', 'e9', 20000)],
          tipAllocations: [alloc('p1', 'b1', 20000)],
          rates: [rate('bt', 1000, role: 'bartender')]);
      expect(linesOf(r.lines, 'TIPMU'), isEmpty);
      expect(sumCents(r.lines), 6390 + 20000);
    });

    test('tip credit only for listed workers, only when the venue enables it, only in tipped roles', () {
      final rates = [rate('bt', 1000, role: 'bartender'), cook18];
      // Not in the set: full rate, 30h x $10.
      expect(
          sumCents(run([staff(bartender, threeDays)], pay: tipCreditOn, rates: rates).lines), 30000);
      // Venue switch off: full rate.
      expect(sumCents(run([staff(bartender, threeDays)], tipCreditWorkers: {'b1'}, rates: rates).lines), 30000);
      // Cook hours (not tipped) are paid at the cook rate even for a tip-credit worker.
      final r = run([
        staff(bartender, [s('e9', 'cook', ct(2026, 11, 9, 10), ct(2026, 11, 9, 14))])
      ], pay: tipCreditOn, tipCreditWorkers: {
        'b1'
      }, rates: rates, jobRoles: {
        'cook': const JobRole(venueId: 'v1', code: 'cook', name: 'Cook'),
        'bartender': const JobRole(venueId: 'v1', code: 'bartender', name: 'Bartender', tipped: true),
      });
      expect(shape(r.lines), [('REG', '2026-11-09', 400, 180000, 7200)]);
    });

    test('tip-credit overtime rate is 1.5 x minimum wage minus the tip credit', () {
      // Mon-Thu 10h + Fri 2h bartending = 42h; tips $500 (cover the credit).
      // REG 40h x 2.13 = $85.20. OT per hour = 2.13 + 0.5 x 7.25 = $5.755 = 1.5 x 7.25 - 5.12.
      // OT 2h = $11.51. Wages $96.71 + tips $500.
      final r = run([
        staff(bartender, [
          for (var d = 9; d <= 12; d++) s('e$d', 'bartender', ct(2026, 11, d, 9), ct(2026, 11, d, 19)),
          s('e13', 'bartender', ct(2026, 11, 13, 17), ct(2026, 11, 13, 19)),
        ])
      ], pay: tipCreditOn, tipCreditWorkers: {
        'b1'
      }, tipPools: [
        pool('p1', 'e9', 50000)
      ], tipAllocations: [
        alloc('p1', 'b1', 50000)
      ], rates: [
        rate('bt', 1000, role: 'bartender')
      ]);
      final ot = linesOf(r.lines, 'OT').single;
      expect(ot.rateE4, 57550);
      expect(ot.amountCents, 1151);
      expect(sumCents(linesOf(r.lines, 'REG')), 8520);
      expect(linesOf(r.lines, 'TIPMU'), isEmpty);
      expect(sumCents(r.lines), 9671 + 50000);
      final week = r.worker('b1')!.weeks.single;
      expect(week.regularRateE4, 72500); // the regular rate is the full minimum wage
      expect(week.grossCents, 9671);
    });
  });

  test('JSON lines can be sent to approve_pay_period', () {
    final r = run([
      staff(w1, [s('e10', 'cashier', ct(2026, 11, 10, 16), ct(2026, 11, 10, 22))])
    ], period: PayPeriod(
        id: 'pp1', venueId: 'v1', startsOn: day(2026, 11, 9), endsOn: day(2026, 11, 22), payDate: day(2026, 11, 27)));
    expect(r.lines.single.toJson(), {
      'venue_id': 'v1',
      'pay_period_id': 'pp1',
      'worker_id': 'w1',
      'work_date': '2026-11-10',
      'event_id': 'e10',
      'storefront_id': 'sf1',
      'job_role_code': 'cashier',
      'pay_code': 'REG',
      'hours': 6.0,
      'rate': 15.0,
      'amount': 90.0,
    });
  });
}
