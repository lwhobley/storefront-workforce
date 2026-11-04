import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

import 'pay_helpers.dart';

void main() {
  AgencyBillRate bill(String id, String agency, String role, int cents, {int? ot, DateTime? from}) => AgencyBillRate(
    id: id,
    venueId: 'v1',
    agencyId: agency,
    jobRoleCode: role,
    billRateCents: cents,
    overtimeBillRateCents: ot,
    effectiveFrom: from ?? day(2026, 1, 1),
  );

  /// A temp working one event per day: (day of November, start hour, end hour).
  (WorkerPayInput, Map<String, Event>) temp(
    String id,
    String agency,
    List<(int, int, int)> days, {
    String role = 'cashier',
  }) {
    final w = worker(id, type: WorkerType.temp, agencyId: agency);
    final shifts = <Shift>[];
    final punches = <Punch>[];
    final events = <String, Event>{};
    for (final (d, from, to) in days) {
      final eid = 'e$d';
      events[eid] = event(eid, ct(2026, 11, d, from));
      shifts.add(shift('s-$id-$d', workerId: id, eventId: eid, call: ct(2026, 11, d, from), role: role));
      punches.addAll(worked(id, ct(2026, 11, d, from), ct(2026, 11, d, to), eventId: eid, shiftId: 's-$id-$d'));
    }
    return (WorkerPayInput(worker: w, punches: punches, shifts: shifts), events);
  }

  final rates = [
    bill('a1-cash', 'a1', 'cashier', 2000, ot: 3000),
    bill('a2-cash', 'a2', 'cashier', 1800), // no OT bill rate: OT at the bill rate
  ];

  test('hours over 40 in a workweek are billed at the overtime bill rate', () {
    // t1 (agency a1): Mon-Thu 09:00-19:00 (40h) + Fri 09:00-13:00 (4h) = 44h.
    // Mon-Thu 4 x 10h x $20 = $800; Fri 4h OT x $30 = $120. Agency a1 total $920.
    // t2 (agency a2): Mon-Thu 10h + Fri 1h = 41h x $18 (OT at bill rate) = $738.
    final (t1, ev1) = temp('t1', 'a1', [for (var d = 9; d <= 12; d++) (d, 9, 19), (13, 9, 13)]);
    final (t2, ev2) = temp('t2', 'a2', [for (var d = 9; d <= 12; d++) (d, 9, 19), (13, 9, 10)]);
    final r = calculateAgencyBilling(
      timeZone: tz,
      overtimeRules: texas.overtime,
      from: day(2026, 11, 9),
      to: day(2026, 11, 22),
      temps: [
        t1,
        t2,
        WorkerPayInput(worker: worker('reg')),
      ],
      events: {...ev1, ...ev2},
      billRates: rates,
    );
    expect(r.problems, isEmpty);
    expect(r.invoices.map((i) => i.agencyId), ['a1', 'a2']);
    final a1 = r.invoice('a1')!;
    expect(a1.totalCents, 92000);
    expect(a1.regularMinutes, 2400);
    expect(a1.overtimeMinutes, 240);
    final fri = a1.lines.singleWhere((l) => l.eventId == 'e13');
    expect(fri.regularMinutes, 0);
    expect(fri.overtimeMinutes, 240);
    expect(fri.overtimeBillRateCents, 3000);
    expect(fri.overtimeAmountCents, 12000);
    expect(a1.lines.map((l) => l.amountCents), [20000, 20000, 20000, 20000, 12000]);
    final a2 = r.invoice('a2')!;
    expect(a2.overtimeMinutes, 60);
    expect(a2.lines.last.overtimeBillRateCents, 1800);
    expect(a2.totalCents, 73800);
    expect(r.totalCents, 92000 + 73800);
  });

  test('a date range bills only its dates, with overtime from the whole workweek', () {
    // Range Mon-Thu only: Friday's OT is outside it. 4 x $200 = $800.
    final (t1, ev1) = temp('t1', 'a1', [for (var d = 9; d <= 12; d++) (d, 9, 19), (13, 9, 13)]);
    final r = calculateAgencyBilling(
      timeZone: tz,
      overtimeRules: texas.overtime,
      from: day(2026, 11, 9),
      to: day(2026, 11, 12),
      temps: [t1],
      events: ev1,
      billRates: rates,
    );
    expect(r.totalCents, 80000);
    expect(r.invoice('a1')!.overtimeMinutes, 0);
  });

  test('missing bill rate and missing agency are blocking problems', () {
    final (t1, ev1) = temp('t1', 'a1', [(10, 16, 22)], role: 'cook');
    final noAgency = WorkerPayInput(
      worker: worker('t9', type: WorkerType.temp),
      punches: worked('t9', ct(2026, 11, 10, 16), ct(2026, 11, 10, 22), eventId: 'e10'),
      shifts: [shift('s9', workerId: 't9', eventId: 'e10', call: ct(2026, 11, 10, 16))],
    );
    final r = calculateAgencyBilling(
      timeZone: tz,
      overtimeRules: texas.overtime,
      from: day(2026, 11, 9),
      to: day(2026, 11, 22),
      temps: [t1, noAgency],
      events: ev1,
      billRates: rates,
    );
    expect(r.problems.map((p) => p.kind).toSet(), {PayProblemKind.missingBillRate, PayProblemKind.missingAgency});
    expect(r.problems.every((p) => p.isBlocking), isTrue);
    final line = r.invoice('a1')!.lines.single;
    expect(line.billRateCents, isNull);
    expect(line.amountCents, 0);
    expect(line.regularMinutes, 360);
  });

  test('bill rate change mid-range splits the line', () {
    // $20 until Nov 10, $22 from Nov 11. Two 5h days: $100 + $110.
    final (t1, ev1) = temp('t1', 'a1', [(10, 16, 21), (11, 16, 21)]);
    final r = calculateAgencyBilling(
      timeZone: tz,
      overtimeRules: texas.overtime,
      from: day(2026, 11, 9),
      to: day(2026, 11, 22),
      temps: [t1],
      events: ev1,
      billRates: [
        bill('old', 'a1', 'cashier', 2000),
        bill('new', 'a1', 'cashier', 2200, from: day(2026, 11, 11)),
      ],
    );
    expect(r.invoice('a1')!.lines.map((l) => (l.billRateCents, l.amountCents)), [(2000, 10000), (2200, 11000)]);
  });
}
