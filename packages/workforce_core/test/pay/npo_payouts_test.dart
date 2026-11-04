import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

import 'pay_helpers.dart';

void main() {
  final ev = event('e1', ct(2026, 11, 10, 19));
  final call = ct(2026, 11, 10, 16);

  // Venue default: $10/h, 5 people, $25 per missing person, $40 per no-show.
  final defaultAgreement = NpoAgreement(
      id: 'default',
      venueId: 'v1',
      hourlyRateCents: 1000,
      minHeadcount: 5,
      shortfallDeductionCents: 2500,
      noShowDeductionCents: 4000,
      effectiveFrom: day(2026, 1, 1));
  // Group g1's own: $12/h, 4 people, $30 short, $20 no-show.
  final g1Agreement = NpoAgreement(
      id: 'g1',
      venueId: 'v1',
      npoGroupId: 'g1',
      hourlyRateCents: 1200,
      minHeadcount: 4,
      shortfallDeductionCents: 3000,
      noShowDeductionCents: 2000,
      effectiveFrom: day(2026, 1, 1));
  final agreements = [defaultAgreement, g1Agreement];

  Worker member(String id, String group) =>
      worker(id, type: WorkerType.npo, npoGroupId: group, first: 'M', last: id.toUpperCase());

  group('deduction rule (no double penalty)', () {
    int d(int shortfall, int noShows, {int sd = 3000, int nd = 2000}) => npoDeductionsCents(
        shortfall: shortfall, noShows: noShows, shortfallDeductionCents: sd, noShowDeductionCents: nd);

    test('a no-show that also causes the shortfall is charged once, at the larger amount', () {
      expect(d(1, 1), 3000); // not 3000 + 2000
      expect(d(1, 1, sd: 2500, nd: 4000), 4000);
    });

    test('extra shortfall and extra no-shows are charged at their own amounts', () {
      expect(d(2, 1), 3000 + 3000); // 1 both (max 30) + 1 short (30)
      expect(d(1, 3), 3000 + 2 * 2000); // 1 both (max 30) + 2 no-shows (20)
      expect(d(0, 2), 4000);
      expect(d(3, 0), 9000);
      expect(d(0, 0), 0);
    });
  });

  test('default agreement with shortfall, no-shows, release and adjustment', () {
    // Group g2 (no agreement of its own -> default $10/h, min 5, $25 short, $40 no-show).
    // Scheduled: 6 assigned + 1 released = 7. Four worked 5h each (20h); two never came; one was released.
    // Gross 20h x $10 = $200. Shortfall 5 - 4 = 1; no-shows 2.
    // Deductions: 1 person is both (max(25, 40) = 40) + 1 more no-show (40) = $80.
    // Adjustment +$15. Total 200 - 80 + 15 = $135.
    final ids = ['m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7'];
    final members = [for (final id in ids) member(id, 'g2')];
    final shifts = [
      for (final id in ids)
        shift('s-$id', workerId: id, eventId: 'e1', call: call,
            status: id == 'm7' ? ShiftStatus.released : ShiftStatus.assigned),
      // Someone from another group at the same event is ignored.
      shift('s-x', workerId: 'x1', eventId: 'e1', call: call),
    ];
    final punches = {
      for (final id in ['m1', 'm2', 'm3', 'm4']) id: worked(id, ct(2026, 11, 10, 16), ct(2026, 11, 10, 21), eventId: 'e1'),
    };
    final r = calculateNpoPayout(
      event: ev,
      npoGroupId: 'g2',
      members: [...members, member('x1', 'g9')],
      shifts: shifts,
      punchesByWorker: punches,
      agreements: agreements,
      timeZone: tz,
      adjustmentCents: 1500,
      adjustmentReason: 'Stayed late for clean-up',
    );
    final p = r.payout;
    expect(r.agreement!.id, 'default');
    expect(p.membersScheduled, 7);
    expect(p.membersWorked, 4);
    expect(p.noShows, 2);
    expect(r.shortfall, 1);
    expect(p.hoursHundredths, 2000);
    expect(p.hourlyRateCents, 1000);
    expect(p.grossCents, 20000);
    expect(p.deductionsCents, 8000);
    expect(p.totalCents, 13500);
    expect({for (final m in p.detail) m.workerId: m.status}, {
      'm1': 'worked', 'm2': 'worked', 'm3': 'worked', 'm4': 'worked', //
      'm5': 'no_show', 'm6': 'no_show', 'm7': 'released',
    });
    final json = p.toJson();
    expect(json['total'], 135.0);
    expect(json['deductions'], 80.0);
    expect(json['adjustment_reason'], 'Stayed late for clean-up');
    expect((json['detail'] as List).first, {'worker_id': 'm1', 'name': 'M M1', 'hours': 5.0, 'minutes': 300, 'status': 'worked'});
  });

  test('group-specific agreement; hours from exact minutes; break rules apply', () {
    // g1: $12/h, min 4, $30 short. Three members 16:00-21:00 with a 30-min unpaid meal = 4.5h each.
    // 13.5h x $12 = $162.00. Shortfall 4 - 3 = 1 -> $30. No no-shows. Total $132.00.
    final ids = ['a', 'b', 'c'];
    final r = calculateNpoPayout(
      event: ev,
      npoGroupId: 'g1',
      members: [for (final id in ids) member(id, 'g1')],
      shifts: [for (final id in ids) shift('s-$id', workerId: id, eventId: 'e1', call: call)],
      punchesByWorker: {
        for (final id in ids)
          id: worked(id, ct(2026, 11, 10, 16), ct(2026, 11, 10, 21),
              eventId: 'e1', breaks: [(ct(2026, 11, 10, 18), ct(2026, 11, 10, 18, 30), BreakKind.meal)]),
      },
      agreements: agreements,
      timeZone: tz,
    );
    expect(r.agreement!.id, 'g1');
    expect(r.payout.hoursHundredths, 1350);
    expect(r.payout.grossCents, 16200);
    expect(r.payout.deductionsCents, 3000);
    expect(r.payout.totalCents, 13200);
  });

  test('total is floored at zero', () {
    // One member worked 1h at $10 = $10; 4 short of 5 = $100 + no-shows; total max(0, negative) = 0.
    final r = calculateNpoPayout(
      event: ev,
      npoGroupId: 'g2',
      members: [member('a', 'g2'), member('b', 'g2')],
      shifts: [
        shift('sa', workerId: 'a', eventId: 'e1', call: call),
        shift('sb', workerId: 'b', eventId: 'e1', call: call),
      ],
      punchesByWorker: {'a': worked('a', ct(2026, 11, 10, 16), ct(2026, 11, 10, 17), eventId: 'e1')},
      agreements: agreements,
      timeZone: tz,
      adjustmentCents: -500,
      adjustmentReason: 'Damaged equipment',
    );
    // Shortfall 4, no-shows 1: 1 both at max(25,40)=40 + 3 short x 25 = $115. 10 - 115 - 5 < 0.
    expect(r.payout.deductionsCents, 11500);
    expect(r.payout.totalCents, 0);
    expect(r.payout.adjustmentCents, -500);
  });

  test('adjustment needs a reason', () {
    expect(
      () => calculateNpoPayout(
          event: ev,
          npoGroupId: 'g2',
          members: const [],
          shifts: const [],
          punchesByWorker: const {},
          agreements: agreements,
          timeZone: tz,
          adjustmentCents: 100),
      throwsArgumentError,
    );
  });

  test('no agreement is a blocking problem; open punch is not a no-show', () {
    final r = calculateNpoPayout(
      event: ev,
      npoGroupId: 'g2',
      members: [member('a', 'g2')],
      shifts: [shift('sa', workerId: 'a', eventId: 'e1', call: call)],
      punchesByWorker: {
        'a': [punch('a', PunchKind.clockIn, ct(2026, 11, 10, 16), eventId: 'e1')],
      },
      agreements: const [],
      timeZone: tz,
    );
    expect(r.problems.map((p) => p.kind).toSet(), {PayProblemKind.missingNpoAgreement, PayProblemKind.openClockIn});
    expect(r.payout.noShows, 0);
    expect(r.payout.detail.single.status, 'open_punch');
    expect(r.payout.totalCents, 0);
  });

  test('season statement adds up payouts with a status breakdown', () {
    final payouts = [
      const NpoPayout(eventId: 'e1', npoGroupId: 'g1', hoursHundredths: 2000, grossCents: 20000, deductionsCents: 8000,
          adjustmentCents: 1500, totalCents: 13500, status: 'paid'),
      const NpoPayout(eventId: 'e2', npoGroupId: 'g1', hoursHundredths: 1350, grossCents: 16200, deductionsCents: 3000,
          totalCents: 13200, status: 'approved'),
      const NpoPayout(eventId: 'e3', npoGroupId: 'g1', hoursHundredths: 100, grossCents: 1000, totalCents: 1000),
      const NpoPayout(eventId: 'e1', npoGroupId: 'g2', totalCents: 99999),
    ];
    final st = npoSeasonStatement('g1', payouts);
    expect(st.events, 3);
    expect(st.hoursHundredths, 3450);
    expect(st.grossCents, 37200);
    expect(st.deductionsCents, 11000);
    expect(st.adjustmentCents, 1500);
    expect(st.totalCents, 27700);
    expect(st.byStatus['paid']!.totalCents, 13500);
    expect(st.byStatus['approved']!.totalCents, 13200);
    expect(st.byStatus['pending']!.count, 1);
    expect(st.paidCents, 13500);
    expect(st.outstandingCents, 14200);
  });
}
