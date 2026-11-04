import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  ShiftOutcome outcome(String worker, AttendanceOutcome o, {int minutesLate = 0}) => ShiftOutcome(
        workerId: worker,
        eventId: 'e1',
        storefrontId: 'sf1',
        jobRoleCode: 'cashier',
        callTime: DateTime.utc(2026, 11, 10, 17),
        outcome: o,
        minutesLate: minutesLate,
      );

  test('reliability is on time out of the shifts a person was expected at', () {
    final r = reliabilityOf([
      outcome('w2', AttendanceOutcome.onTime),
      outcome('w1', AttendanceOutcome.onTime),
      outcome('w1', AttendanceOutcome.late, minutesLate: 12),
      outcome('w1', AttendanceOutcome.noShow),
      outcome('w1', AttendanceOutcome.onTime),
    ]);
    expect(r.map((x) => x.workerId).toList(), ['w1', 'w2'], reason: 'sorted by id');
    expect(r[0].expected, 4);
    expect(r[0].onTime, 2);
    expect(r[0].late, 1);
    expect(r[0].noShows, 1);
    expect(r[0].score, 0.5);
    expect(r[1].score, 1);
  });

  test('call-offs count against reliability; released and pending do not count at all', () {
    final r = reliabilityOf([
      outcome('w1', AttendanceOutcome.onTime),
      outcome('w1', AttendanceOutcome.callOff),
      outcome('w1', AttendanceOutcome.released),
      outcome('w1', AttendanceOutcome.pending),
    ]).single;
    expect(r.expected, 2, reason: 'on time and the call-off');
    expect(r.callOffs, 1);
    expect(r.score, 0.5);
  });

  test('a person with nothing to measure has no score', () {
    final r = reliabilityOf([outcome('w1', AttendanceOutcome.released)]).single;
    expect(r.expected, 0);
    expect(r.score, isNull);
  });

  test('seasons run August 1 to July 31', () {
    expect(seasonLabel(DateTime.utc(2026, 7, 31)), '2025–26');
    expect(seasonLabel(DateTime.utc(2026, 8, 1)), '2026–27');
    expect(seasonLabel(DateTime.utc(2027, 1, 15)), '2026–27');
    expect(seasonLabel(DateTime.utc(2099, 12, 31)), '2099–00');
  });

  EventKpis kpis(String id, {int needed = 0, int assigned = 0, int attended = 0, int noShows = 0, int? labor, int? budget}) {
    final cost = labor == null
        ? null
        : LaborCostReport(
            eventId: id,
            attendance: 100,
            attendanceIsActual: true,
            storefronts: const [],
            total: LaborCostRow(
              storefrontId: null,
              payrollCents: labor,
              burdenCents: 0,
              tempCents: 0,
              npoCents: 0,
              tipsCents: 0,
              budgetCents: budget,
            ),
          );
    return EventKpis(
      eventId: id,
      needed: needed,
      assigned: assigned,
      attended: attended,
      late: 0,
      noShows: noShows,
      staffingMix: const {},
      labor: cost,
    );
  }

  test('season totals add up, newest season first, and labor needs a report', () {
    final rows = [
      (DateTime.utc(2025, 9, 1), kpis('a', needed: 10, assigned: 9, attended: 8, noShows: 1, labor: 50000, budget: 60000)),
      (DateTime.utc(2025, 10, 1), kpis('b', needed: 10, assigned: 10, attended: 10)),
      (DateTime.utc(2026, 9, 1), kpis('c', needed: 4, assigned: 2, attended: 2, labor: 9000)),
      (DateTime.utc(2026, 9, 8), kpis('d', needed: 4, assigned: 4, attended: 3, noShows: 1)),
    ];
    final seasons = seasonSummaries(rows);
    expect(seasons.map((s) => s.label).toList(), ['2026–27', '2025–26']);

    final current = seasons.first;
    expect(current.events, 2);
    expect(current.needed, 8);
    expect(current.assigned, 6);
    expect(current.attended, 5);
    expect(current.noShows, 1);
    expect(current.laborCostCents, 9000);
    expect(current.budgetCents, isNull, reason: 'no budget on either event');
    expect(current.fillRate, 0.75);
    expect(current.attendanceRate, closeTo(5 / 6, 1e-9));

    final last = seasons.last;
    expect(last.laborCostCents, 50000);
    expect(last.budgetCents, 60000);
  });
}
