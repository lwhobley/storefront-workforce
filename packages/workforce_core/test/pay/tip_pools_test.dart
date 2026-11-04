import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

import 'pay_helpers.dart';

void main() {
  TipPool pool(int cents, {String method = 'hours', Map<String, int> points = const {}, String? storefront}) => TipPool(
        id: 'pool1',
        venueId: 'v1',
        eventId: 'e1',
        storefrontId: storefront,
        amountCents: cents,
        method: method,
        rolePointsThousandths: points,
      );
  TipParticipant p(String id, String role, int minutes,
          {WorkerType type = WorkerType.regular, bool released = false}) =>
      TipParticipant(workerId: id, jobRoleCode: role, paidMinutes: minutes, workerType: type, releasedBeforeArrival: released);

  Map<String, int> amounts(TipPoolResult r) => {for (final a in r.allocations) a.workerId: a.amountCents};

  group('hours', () {
    test('split by paid minutes, lead excluded', () {
      // $100 over 4h + 3h + 1h = 8h: 50.00 / 37.50 / 12.50. The lead's 5h are not in the pool.
      final r = allocateTipPool(pool: pool(10000), participants: [
        p('a', 'bartender', 240),
        p('b', 'runner', 180),
        p('c', 'cashier', 60),
        p('d', 'lead', 300),
      ]);
      expect(amounts(r), {'a': 5000, 'b': 3750, 'c': 1250});
      expect(r.distributedCents, 10000);
      expect(r.excluded.single.workerId, 'd');
      expect(r.excluded.single.reason, TipExclusionReason.roleNotEligible);
      expect(r.forWorker('a')!.hoursHundredths, 400);
      expect(r.forWorker('a')!.pointsThousandths, 0);
    });

    test('largest remainder: leftover cents to the lowest worker ids on ties', () {
      // $100.01 / 3 = 33.3367 each: floors 33.33 x 3 = 99.99; 2 cents left -> a and b.
      final r = allocateTipPool(
          pool: pool(10001), participants: [p('c', 'cook', 60), p('b', 'cook', 60), p('a', 'cook', 60)]);
      expect(amounts(r), {'a': 3334, 'b': 3334, 'c': 3333});
      expect(r.allocations.map((a) => a.workerId), ['a', 'b', 'c']);
      expect(r.distributedCents, 10001);
    });

    test('largest remainder favors the largest fraction, not the id', () {
      // $10.00 over 7 / 11 / 13 minutes (31): 225.81 / 354.84 / 419.35 -> floors 225 + 354 + 419 = 998;
      // fractions .81, .84, .35 -> b and a get a cent: 226 / 355 / 419 = 1000.
      final r = allocateTipPool(
          pool: pool(1000), participants: [p('a', 'cook', 7), p('b', 'cook', 11), p('c', 'cook', 13)]);
      expect(amounts(r), {'a': 226, 'b': 355, 'c': 419});
    });

    test('two shifts for one person are added together', () {
      final r = allocateTipPool(
          pool: pool(9000), participants: [p('a', 'cook', 60), p('a', 'runner', 60), p('b', 'cook', 60)]);
      expect(amounts(r), {'a': 6000, 'b': 3000});
      expect(r.forWorker('a')!.hoursHundredths, 200);
    });
  });

  group('equal', () {
    test('\$100.00 among 3 is 33.34 / 33.33 / 33.33', () {
      final r = allocateTipPool(pool: pool(10000, method: 'equal'), participants: [
        p('w1', 'cashier', 300),
        p('w2', 'cashier', 30),
        p('w3', 'cook', 480),
        p('w4', 'cashier', 0), // no-show
        p('w5', 'cashier', 0, released: true), // sent home before arriving
        p('w6', 'lead', 480),
      ]);
      expect(amounts(r), {'w1': 3334, 'w2': 3333, 'w3': 3333});
      expect(r.distributedCents, 10000);
      expect({for (final e in r.excluded) e.workerId: e.reason}, {
        'w4': TipExclusionReason.noPaidTime,
        'w5': TipExclusionReason.releasedBeforeArrival,
        'w6': TipExclusionReason.roleNotEligible,
      });
      expect(r.forWorker('w1')!.pointsThousandths, 1000);
    });
  });

  group('role_points', () {
    test('minutes x points; roles not in role_points are out', () {
      // $90: bartender 4h x 1.0 = 240 pts, runner 4h x 0.5 = 120 pts, cashier not listed.
      // 90 x 240/360 = 60.00, 90 x 120/360 = 30.00.
      final r = allocateTipPool(
        pool: pool(9000, method: 'role_points', points: {'bartender': 1000, 'runner': 500}),
        participants: [p('a', 'bartender', 240), p('b', 'runner', 240), p('c', 'cashier', 240)],
      );
      expect(amounts(r), {'a': 6000, 'b': 3000});
      expect(r.forWorker('a')!.pointsThousandths, 1000);
      expect(r.forWorker('b')!.pointsThousandths, 500);
      expect(r.excluded.single.reason, TipExclusionReason.roleNotInPoolPoints);
    });

    test('a lead listed in role_points is still out unless the venue makes leads eligible', () {
      final pts = pool(9000, method: 'role_points', points: {'bartender': 1000, 'lead': 1500});
      final r = allocateTipPool(pool: pts, participants: [p('a', 'bartender', 240), p('l', 'lead', 240)]);
      expect(amounts(r), {'a': 9000});
      final withLeads = allocateTipPool(
        pool: pts,
        participants: [p('a', 'bartender', 240), p('l', 'lead', 240)],
        payRules: const PayRules(tipPool: TipPoolRules(eligibleRoles: ['bartender', 'lead'])),
      );
      // 240 x 1.0 = 240 and 240 x 1.5 = 360: 36.00 / 54.00.
      expect(amounts(withLeads), {'a': 3600, 'l': 5400});
    });
  });

  test('temps and NPO members are left out by default', () {
    final r = allocateTipPool(pool: pool(1000), participants: [
      p('a', 'cashier', 60),
      p('t', 'cashier', 60, type: WorkerType.temp),
      p('n', 'cashier', 60, type: WorkerType.npo),
    ]);
    expect(amounts(r), {'a': 1000});
    expect(r.excluded.map((e) => e.reason).toSet(), {TipExclusionReason.workerTypeNotIncluded});
  });

  test('nobody eligible: not distributed, blocking problem', () {
    final r = allocateTipPool(pool: pool(5000), participants: [p('l', 'lead', 60)]);
    expect(r.allocations, isEmpty);
    expect(r.problems.single.kind, PayProblemKind.tipPoolNotDistributed);
    expect(r.problems.single.isBlocking, isTrue);
  });

  test('unknown method throws', () {
    expect(() => allocateTipPool(pool: pool(100, method: 'tenure'), participants: const []), throwsArgumentError);
  });

  test('participants from shifts and punches', () {
    // Storefront pool at sf1: a works 18:00-22:00 with an unpaid 30-min meal (3.5h); b works 4h;
    // c was released before arriving; d worked at sf2 (not in this pool); e is open (no worker).
    final shifts = [
      shift('sa', workerId: 'a', eventId: 'e1', call: ct(2026, 11, 10, 18)),
      shift('sb', workerId: 'b', eventId: 'e1', call: ct(2026, 11, 10, 18), role: 'runner'),
      shift('sc', workerId: 'c', eventId: 'e1', call: ct(2026, 11, 10, 18), status: ShiftStatus.released),
      shift('sd', workerId: 'd', eventId: 'e1', call: ct(2026, 11, 10, 18), storefrontId: 'sf2'),
    ];
    final punches = {
      'a': worked('a', ct(2026, 11, 10, 18), ct(2026, 11, 10, 22),
          eventId: 'e1', breaks: [(ct(2026, 11, 10, 20), ct(2026, 11, 10, 20, 30), BreakKind.meal)]),
      'b': worked('b', ct(2026, 11, 10, 18), ct(2026, 11, 10, 22), eventId: 'e1'),
      'd': worked('d', ct(2026, 11, 10, 18), ct(2026, 11, 10, 22), eventId: 'e1'),
    };
    final workers = {for (final id in ['a', 'b', 'c', 'd']) id: worker(id)};
    final pl = pool(7500, storefront: 'sf1');
    final parts = tipParticipantsFromShifts(
        pool: pl, workers: workers, shifts: shifts, punchesByWorker: punches, timeZone: tz);
    expect({for (final x in parts) x.workerId: x.paidMinutes}, {'a': 210, 'b': 240, 'c': 0});
    expect(parts.singleWhere((x) => x.workerId == 'c').releasedBeforeArrival, isTrue);
    final r = allocateTipPool(pool: pl, participants: parts);
    // $75 over 210 + 240 = 450 min: 35.00 / 40.00.
    expect(amounts(r), {'a': 3500, 'b': 4000});
    expect(r.excluded.single.reason, TipExclusionReason.releasedBeforeArrival);
    // Event-wide pool includes d.
    final wide = tipParticipantsFromShifts(
        pool: pool(100), workers: workers, shifts: shifts, punchesByWorker: punches, timeZone: tz);
    expect(wide.map((x) => x.workerId).toSet(), {'a', 'b', 'c', 'd'});
  });
}
