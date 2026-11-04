import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4, 12);
  const rules = ReliabilityRules();

  Worker worker(String id, String first, {WorkerType type = WorkerType.regular, String? npo}) =>
      Worker(id: id, venueId: 'v', type: type, employeeNumber: id.toUpperCase(), firstName: first, lastName: 'X', npoGroupId: npo);

  ShiftOutcome o(String worker, AttendanceOutcome outcome, int daysAgo) => ShiftOutcome(
        workerId: worker,
        eventId: 'e$daysAgo',
        storefrontId: 'sf',
        jobRoleCode: 'cashier',
        callTime: now.subtract(Duration(days: daysAgo)),
        outcome: outcome,
      );

  final workers = [worker('a', 'Ann'), worker('b', 'Bo'), worker('c', 'Cy'), worker('d', 'Di'), worker('e', 'Ed')];
  final outcomes = [
    // Ann: 4 on time.
    for (var i = 1; i <= 4; i++) o('a', AttendanceOutcome.onTime, i),
    // Bo: 3 events, one no-show (75).
    o('b', AttendanceOutcome.onTime, 1), o('b', AttendanceOutcome.onTime, 2), o('b', AttendanceOutcome.noShow, 3),
    // Cy: 5 events, one late (95).
    for (var i = 1; i <= 4; i++) o('c', AttendanceOutcome.onTime, i), o('c', AttendanceOutcome.late, 5),
    // Di: one event only (new, 100).
    o('d', AttendanceOutcome.onTime, 1),
    // Ed: nothing.
  ];
  final entries = buildRankings(
    workers: workers,
    outcomes: outcomes,
    ratings: [('a', 3), ('a', 4), ('b', 5), ('c', 4), ('c', 5)],
    flagged: {'b'},
    rules: rules,
    now: now,
  );
  RankingEntry of(String id) => entries.singleWhere((e) => e.workerId == id);

  test('builds score, average rating, events worked and the flag', () {
    expect(of('a').score, 100);
    expect(of('a').averageStars, 3.5);
    expect(of('a').ratingCount, 2);
    expect(of('a').eventsWorked, 4);
    expect(of('b').score, 75);
    expect(of('b').eventsWorked, 2, reason: 'a no-show is not an event worked');
    expect(of('b').flagged, isTrue);
    expect(of('c').eventsWorked, 5, reason: 'late still counts as worked');
    expect(of('e').score, isNull);
    expect(of('e').averageStars, isNull);
    expect(of('e').eventsWorked, 0);
  });

  test('by reliability: best first, new and unscored people last', () {
    expect(sortRankings(entries, RankingSort.reliability).map((e) => e.workerId), ['a', 'c', 'b', 'd', 'e']);
  });

  test('by rating: highest average first, no ratings last', () {
    expect(sortRankings(entries, RankingSort.rating).map((e) => e.workerId), ['b', 'c', 'a', 'd', 'e']);
  });

  test('by events worked, then by score', () {
    expect(sortRankings(entries, RankingSort.events).map((e) => e.workerId), ['c', 'a', 'b', 'd', 'e']);
  });

  test('by name', () {
    expect(sortRankings(entries, RankingSort.name).map((e) => e.name), ['Ann X', 'Bo X', 'Cy X', 'Di X', 'Ed X']);
  });

  test('worked minutes per person skip voided punches', () {
    final call = now.subtract(const Duration(days: 1));
    Punch p(String id, String w, String e, PunchKind k, int minutes, {PunchStatus status = PunchStatus.accepted}) => Punch(
          id: id,
          venueId: 'v',
          workerId: w,
          eventId: e,
          kind: k,
          occurredAt: call.add(Duration(minutes: minutes)),
          status: status,
        );
    final minutes = workedMinutesByWorker([
      p('1', 'a', 'e1', PunchKind.clockIn, 0),
      p('2', 'a', 'e1', PunchKind.clockOut, 300),
      p('3', 'a', 'e2', PunchKind.clockIn, 1440),
      p('4', 'a', 'e2', PunchKind.clockOut, 1440 + 240),
      p('5', 'b', 'e1', PunchKind.clockIn, 0, status: PunchStatus.voided),
      p('6', 'b', 'e1', PunchKind.clockIn, 30),
      p('7', 'b', 'e1', PunchKind.clockOut, 90),
    ], now: now);
    expect(minutes, {'a': 540, 'b': 60});
  });

  test('group totals: members, hours, shifts, no-shows, call-offs, average score', () {
    final groups = groupReliability(
      groupOf: {'a': 'g1', 'b': 'g1', 'd': 'g1', 'c': 'g2'},
      outcomes: [...outcomes, o('a', AttendanceOutcome.callOff, 40)],
      workedMinutes: {'a': 600, 'b': 120},
      scores: reliabilityScores([...outcomes, o('a', AttendanceOutcome.callOff, 40)], rules: rules, now: now),
    );
    final g1 = groups['g1']!;
    expect(g1.members, 3);
    expect(g1.workedMinutes, 720);
    expect(g1.shiftsWorked, 4 + 2 + 1);
    expect(g1.noShows, 1);
    expect(g1.callOffs, 1);
    expect(g1.expected, 9);
    expect(g1.attendanceRate, closeTo(7 / 9, 1e-9));
    // Ann 90 (call-off), Bo 75; Di is new and not averaged.
    expect(g1.scored, 2);
    expect(g1.averageScore, 83);
    expect(groups['g2']!.late, 1);
    expect(groups['g2']!.averageScore, 95);
  });
}
