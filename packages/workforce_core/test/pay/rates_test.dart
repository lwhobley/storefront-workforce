import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

import 'pay_helpers.dart';

void main() {
  group('resolveRate precedence', () {
    // $8 venue default < $10 role < $11 role+type < $12 worker < $13 worker+role < $14 all three.
    final all = [
      rate('default', 800),
      rate('role', 1000, role: 'cashier'),
      rate('roleType', 1100, role: 'cashier', eventType: 'concert'),
      rate('worker', 1200, workerId: 'w1'),
      rate('workerRole', 1300, workerId: 'w1', role: 'cashier'),
      rate('workerRoleType', 1400, workerId: 'w1', role: 'cashier', eventType: 'concert'),
    ];
    int? resolve(String worker, String? role, String? type, [List<PayRate>? rates]) => resolveRate(
          workerId: worker,
          jobRoleCode: role,
          eventTypeCode: type,
          date: day(2026, 11, 10),
          rates: rates ?? all,
        )?.hourlyRateCents;

    test('each level wins over the less specific ones', () {
      expect(resolve('w1', 'cashier', 'concert'), 1400);
      expect(resolve('w1', 'cashier', 'game'), 1300);
      expect(resolve('w1', 'cook', 'concert'), 1200);
      expect(resolve('w2', 'cashier', 'concert'), 1100);
      expect(resolve('w2', 'cashier', 'game'), 1000);
      expect(resolve('w2', 'cook', 'game'), 800);
    });

    test('list order does not matter', () {
      expect(resolve('w1', 'cashier', 'concert', all.reversed.toList()), 1400);
      expect(resolve('w2', 'cashier', 'game', all.reversed.toList()), 1000);
    });

    test('a row applies only when every field it sets matches', () {
      // The worker+role row for w1/cashier never applies to w1 as cook.
      expect(resolve('w1', 'cook', 'game', [rate('wr', 1300, workerId: 'w1', role: 'cashier')]), isNull);
      expect(resolve('w1', null, null, [rate('r', 1000, role: 'cashier')]), isNull);
    });

    test('unlisted shapes: worker+type sits between worker+role and worker; type alone above default', () {
      final rates = [
        rate('w', 1200, workerId: 'w1'),
        rate('wt', 1250, workerId: 'w1', eventType: 'concert'),
        rate('wr', 1300, workerId: 'w1', role: 'cashier'),
        rate('t', 900, eventType: 'concert'),
        rate('d', 800),
      ];
      expect(resolve('w1', 'cashier', 'concert', rates), 1300);
      expect(resolve('w1', 'cook', 'concert', rates), 1250);
      expect(resolve('w1', 'cook', 'game', rates), 1200);
      expect(resolve('w2', 'cook', 'concert', rates), 900);
      expect(rateSpecificity(rates[1]), 5);
      expect(rateSpecificity(rates[3]), 1);
    });

    test('no rate is null', () {
      expect(resolve('w1', 'cashier', 'game', const []), isNull);
    });
  });

  group('effective dates', () {
    final rates = [
      rate('old', 1000, role: 'cashier', from: day(2026, 1, 1), to: day(2026, 6, 30)),
      rate('new', 1050, role: 'cashier', from: day(2026, 7, 1)),
    ];
    int? on(DateTime d, [List<PayRate>? list]) =>
        resolveRate(workerId: 'w1', jobRoleCode: 'cashier', eventTypeCode: 'game', date: d, rates: list ?? rates)
            ?.hourlyRateCents;

    test('effective_to is inclusive and effective_from is inclusive', () {
      expect(on(day(2026, 6, 30)), 1000);
      expect(on(day(2026, 7, 1)), 1050);
      expect(on(day(2025, 12, 31)), isNull);
    });

    test('an expired specific rate falls back to a less specific active one', () {
      final list = [
        rate('wr', 1500, workerId: 'w1', role: 'cashier', to: day(2026, 3, 31)),
        rate('r', 1000, role: 'cashier'),
      ];
      expect(on(day(2026, 3, 31), list), 1500);
      expect(on(day(2026, 4, 1), list), 1000);
    });

    test('ties at the same level go to the latest effective_from', () {
      final list = [
        rate('a', 1000, role: 'cashier', from: day(2026, 1, 1)),
        rate('b', 1100, role: 'cashier', from: day(2026, 3, 1)),
      ];
      expect(on(day(2026, 2, 1), list), 1000);
      expect(on(day(2026, 4, 1), list), 1100);
      expect(on(day(2026, 4, 1), list.reversed.toList()), 1100);
    });

    test('same effective_from: latest created_at, then greatest id', () {
      final list = [
        rate('b', 1100, role: 'cashier', createdAt: DateTime.utc(2026, 1, 1)),
        rate('a', 1200, role: 'cashier', createdAt: DateTime.utc(2026, 2, 1)),
      ];
      expect(on(day(2026, 4, 1), list), 1200);
      final noCreated = [rate('a', 1200, role: 'cashier'), rate('b', 1100, role: 'cashier')];
      expect(on(day(2026, 4, 1), noCreated), 1100);
      expect(on(day(2026, 4, 1), noCreated.reversed.toList()), 1100);
    });
  });

  group('differentials', () {
    PayDifferential diff(String id, String code,
            {String? role, String? workerId, String? type, int perHour = 0, int perShift = 0, DateTime? to}) =>
        PayDifferential(
          id: id,
          venueId: 'v1',
          name: id,
          payCode: code,
          jobRoleCode: role,
          workerId: workerId,
          eventTypeCode: type,
          perHourCents: perHour,
          perShiftCents: perShift,
          effectiveFrom: day(2026, 1, 1),
          effectiveTo: to,
        );
    final diffs = [
      diff('lead', 'LEAD', role: 'lead', perHour: 200),
      diff('leadW1', 'LEAD', role: 'lead', workerId: 'w1', perHour: 50),
      diff('concert', 'BONUS', type: 'concert', perShift: 1000),
      diff('expired', 'LEAD', role: 'lead', perHour: 999, to: day(2026, 6, 30)),
    ];

    test('every active differential that applies is returned', () {
      final got = resolveDifferentials(
          workerId: 'w1', jobRoleCode: 'lead', eventTypeCode: 'concert', date: day(2026, 11, 10), differentials: diffs);
      expect(got.map((d) => d.id), ['concert', 'lead', 'leadW1']);
      expect(got.fold(0, (s, d) => s + d.perHourCents), 250);
      expect(got.fold(0, (s, d) => s + d.perShiftCents), 1000);
    });

    test('does not apply to other roles, workers, or types', () {
      final got = resolveDifferentials(
          workerId: 'w2', jobRoleCode: 'cashier', eventTypeCode: 'game', date: day(2026, 11, 10), differentials: diffs);
      expect(got, isEmpty);
    });

    test('expired differential is used only while active', () {
      final got = resolveDifferentials(
          workerId: 'w2', jobRoleCode: 'lead', eventTypeCode: 'game', date: day(2026, 6, 30), differentials: diffs);
      expect(got.map((d) => d.id), ['expired', 'lead']);
    });
  });

  group('bill rates and NPO agreements', () {
    AgencyBillRate bill(String id, String agency, int cents, DateTime from, {DateTime? to}) => AgencyBillRate(
        id: id,
        venueId: 'v1',
        agencyId: agency,
        jobRoleCode: 'cashier',
        billRateCents: cents,
        effectiveFrom: from,
        effectiveTo: to);

    test('bill rate by agency, role and date', () {
      final rates = [
        bill('a', 'ag1', 2000, day(2026, 1, 1)),
        bill('b', 'ag1', 2100, day(2026, 9, 1)),
        bill('c', 'ag2', 1800, day(2026, 1, 1)),
      ];
      expect(
          resolveBillRate(agencyId: 'ag1', jobRoleCode: 'cashier', date: day(2026, 8, 31), billRates: rates)!.id, 'a');
      expect(
          resolveBillRate(agencyId: 'ag1', jobRoleCode: 'cashier', date: day(2026, 9, 1), billRates: rates)!.id, 'b');
      expect(
          resolveBillRate(agencyId: 'ag2', jobRoleCode: 'cashier', date: day(2026, 9, 1), billRates: rates)!.id, 'c');
      expect(resolveBillRate(agencyId: 'ag2', jobRoleCode: 'cook', date: day(2026, 9, 1), billRates: rates), isNull);
    });

    test('group agreement beats the venue default; default when the group has none active', () {
      final agreements = [
        NpoAgreement(id: 'd', venueId: 'v1', hourlyRateCents: 1000, effectiveFrom: day(2026, 1, 1)),
        NpoAgreement(
            id: 'g',
            venueId: 'v1',
            npoGroupId: 'g1',
            hourlyRateCents: 1200,
            effectiveFrom: day(2026, 1, 1),
            effectiveTo: day(2026, 10, 31)),
      ];
      expect(resolveNpoAgreement(npoGroupId: 'g1', date: day(2026, 10, 31), agreements: agreements)!.id, 'g');
      expect(resolveNpoAgreement(npoGroupId: 'g1', date: day(2026, 11, 1), agreements: agreements)!.id, 'd');
      expect(resolveNpoAgreement(npoGroupId: 'g2', date: day(2026, 6, 1), agreements: agreements)!.id, 'd');
      expect(resolveNpoAgreement(npoGroupId: 'g2', date: day(2025, 6, 1), agreements: agreements), isNull);
    });
  });
}
