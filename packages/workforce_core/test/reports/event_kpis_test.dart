import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  const rules = AttendanceRules();
  final call = DateTime.utc(2026, 11, 10, 17);

  Shift shift(String id, {String? worker, String role = 'cashier', DateTime? released, ShiftStatus status = ShiftStatus.assigned}) => Shift(
    id: id,
    venueId: 'v1',
    eventId: 'e1',
    storefrontId: 'sf1',
    jobRoleCode: role,
    callTime: call,
    workerId: worker,
    status: status,
    releasedAt: released,
  );

  Punch clockIn(String id, String worker, String shiftId, DateTime at, {PunchStatus status = PunchStatus.accepted}) => Punch(
    id: id,
    venueId: 'v1',
    workerId: worker,
    kind: PunchKind.clockIn,
    occurredAt: at,
    eventId: 'e1',
    shiftId: shiftId,
    status: status,
  );

  EventKpis run({
    required List<Shift> shifts,
    List<Punch> punches = const [],
    List<StaffingNeed> needs = const [],
    LaborCostReport? labor,
  }) =>
      calculateEventKpis(eventId: 'e1', shifts: shifts, needs: needs, punches: punches, attendance: rules, labor: labor);

  test('fill rate counts assigned positions against needed, and is null with nothing needed', () {
    final needs = [
      const StaffingNeed(storefrontId: 'sf1', jobRoleCode: 'cashier', count: 3),
      const StaffingNeed(storefrontId: 'sf1', jobRoleCode: 'bartender', count: 1),
    ];
    final k = run(shifts: [shift('a', worker: 'w1'), shift('b', worker: 'w2'), shift('c')], needs: needs);
    expect(k.needed, 4);
    expect(k.assigned, 2);
    expect(k.fillRate, 0.5);
    expect(run(shifts: [shift('a', worker: 'w1')]).fillRate, isNull);
  });

  test('released and cancelled positions are not assigned', () {
    final k = run(shifts: [
      shift('a', worker: 'w1'),
      shift('b', worker: 'w2', released: DateTime.utc(2026, 11, 10, 22)),
      shift('c', worker: 'w3', status: ShiftStatus.released),
      shift('d', worker: 'w4', status: ShiftStatus.cancelled),
    ]);
    expect(k.assigned, 1);
  });

  test('attendance: on time, late past grace, and no-show', () {
    final k = run(
      shifts: [shift('a', worker: 'w1'), shift('b', worker: 'w2'), shift('c', worker: 'w3')],
      punches: [
        clockIn('p1', 'w1', 'a', call.add(const Duration(minutes: 2))),
        clockIn('p2', 'w2', 'b', call.add(Duration(minutes: rules.lateGraceMinutes + 5))),
      ],
    );
    expect(k.attended, 2);
    expect(k.late, 1);
    expect(k.noShows, 1);
    expect(k.attendanceRate, closeTo(2 / 3, 1e-9));
  });

  test('the first clock-in counts, and voided clock-ins do not', () {
    final k = run(
      shifts: [shift('a', worker: 'w1'), shift('b', worker: 'w2')],
      punches: [
        clockIn('p1', 'w1', 'a', call.add(const Duration(minutes: 30))),
        clockIn('p2', 'w1', 'a', call.add(const Duration(minutes: 1))),
        clockIn('p3', 'w2', 'b', call.add(const Duration(minutes: 1)), status: PunchStatus.voided),
      ],
    );
    expect(k.attended, 1);
    expect(k.late, 0, reason: 'the earliest clock-in is the one that counts');
  });

  test('a clock-in with no shift id counts for the worker at this event', () {
    final k = run(
      shifts: [shift('a', worker: 'w1')],
      punches: [
        Punch(id: 'p1', venueId: 'v1', workerId: 'w1', kind: PunchKind.clockIn, occurredAt: call, eventId: 'e1'),
      ],
    );
    expect(k.attended, 1);
  });

  test('staffing mix counts assigned positions by role, sorted', () {
    final k = run(shifts: [
      shift('a', worker: 'w1', role: 'cashier'),
      shift('b', worker: 'w2', role: 'bartender'),
      shift('c', worker: 'w3', role: 'cashier'),
      shift('d', role: 'cook'),
    ]);
    expect(k.staffingMix, {'bartender': 1, 'cashier': 2});
    expect(k.staffingMix.keys.toList(), ['bartender', 'cashier']);
  });

  test('labor cost and cost per attendee come from the labor report', () {
    final labor = LaborCostReport(
      eventId: 'e1',
      attendance: 200,
      attendanceIsActual: true,
      storefronts: const [],
      total: const LaborCostRow(
        storefrontId: null,
        payrollCents: 90000,
        burdenCents: 0,
        tempCents: 0,
        npoCents: 0,
        tipsCents: 0,
        budgetCents: 94000,
      ),
    );
    final k = run(shifts: [shift('a', worker: 'w1')], labor: labor);
    expect(k.laborCostCents, 90000);
    expect(k.budgetCents, 94000);
    expect(k.budgetStatus, BudgetStatus.near);
    expect(k.costPerAttendeeCents, 450);
  });

  test('without a labor report, cost fields are null', () {
    final k = run(shifts: [shift('a', worker: 'w1')]);
    expect(k.laborCostCents, isNull);
    expect(k.budgetStatus, isNull);
    expect(k.costPerAttendeeCents, isNull);
  });

  test('targets: higher is better and lower is better', () {
    const fill = KpiTarget(green: 0.98, yellow: 0.9);
    expect(fill.band(1.0), KpiBand.green);
    expect(fill.band(0.95), KpiBand.yellow);
    expect(fill.band(0.8), KpiBand.red);
    expect(fill.band(null), isNull);

    const cost = KpiTarget(green: 500, yellow: 600, higherIsBetter: false);
    expect(cost.band(450), KpiBand.green);
    expect(cost.band(500), KpiBand.green);
    expect(cost.band(550), KpiBand.yellow);
    expect(cost.band(700), KpiBand.red);
  });

  test('targets refuse a green bound that is worse than yellow', () {
    expect(() => KpiTarget(green: 0.5, yellow: 0.9), throwsA(isA<AssertionError>()));
  });

  test('CSV has a header and one row per event, with blanks for unknown values', () {
    final rows = [
      run(shifts: [shift('a', worker: 'w1')], needs: const [StaffingNeed(storefrontId: 'sf1', jobRoleCode: 'cashier', count: 4)]),
      run(shifts: []),
    ];
    final lines = eventKpisCsv(rows).trim().split('\n');
    expect(lines.first, startsWith('event_id,needed,assigned,fill_rate_pct'));
    expect(lines[1], 'e1,4,1,25.0,0,0.0,0,1,,,,');
    expect(lines[2], 'e1,0,0,,0,,0,0,,,,');
  });
}
