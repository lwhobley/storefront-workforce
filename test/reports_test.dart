import 'package:flutter_test/flutter_test.dart';
import 'package:storefront_workforce/data/demo_repository.dart';
import 'package:storefront_workforce/data/models.dart';
import 'package:storefront_workforce/core/time/venue_time.dart';
import 'package:storefront_workforce/features/reports/reports_labor.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  test('finished demo events: the KPIs add up from their boards', () async {
    final repo = DemoWorkforceRepository(now: DateTime.utc(2026, 11, 4, 1, 42));
    final session = await repo.signInWithPin('100001');
    final done = [
      for (final e in await repo.listEvents(session))
        if (e.status == EventStatus.completed) e,
    ];
    expect(done, isNotEmpty);

    var assigned = 0;
    for (final e in done) {
      final board = await repo.loadBoard(e.id);
      final k = calculateEventKpis(
        eventId: e.id,
        shifts: board.shifts,
        needs: board.needs,
        punches: board.punches,
        attendance: session.rules.attendance,
      );
      expect(k.attended + k.noShows, k.assigned, reason: e.name);
      expect(k.late, lessThanOrEqualTo(k.attended), reason: e.name);
      assigned += k.assigned;
    }
    expect(assigned, greaterThan(0));
  });

  test('finished demo events: labor cost is worked out and compared with the event budget', () async {
    final repo = DemoWorkforceRepository(now: DateTime.utc(2026, 11, 4, 1, 42));
    final session = await repo.signInWithPin('100001');
    final venue = await repo.loadVenue(session);
    final done = [
      for (final e in await repo.listEvents(session))
        if (e.status == EventStatus.completed) e,
    ];
    await repo.ensurePayPeriods(session, DateTime.utc(2026, 11, 4));
    final setup = await repo.loadPaySetup(session);

    final labor = await laborCostByEvent(repo: repo, session: session, venue: venue, setup: setup, events: done);
    expect(labor, isNotEmpty);
    expect(labor.values.any((r) => r.total.payrollCents > 0), isTrue, reason: 'sample staff are paid');
    for (final e in done) {
      final r = labor[e.id];
      if (r == null) continue;
      expect(r.total.budgetCents, e.laborBudgetCents, reason: e.name);
      expect(r.total.payrollCents + r.total.tempCents + r.total.npoCents + r.total.burdenCents, r.total.totalCents, reason: e.name);
    }
    expect(done.every((e) => e.laborBudgetCents != null), isTrue, reason: 'sample events have budgets');
  });

  test('finished demo events: reliability and season totals come from the same shifts', () async {
    final repo = DemoWorkforceRepository(now: DateTime.utc(2026, 11, 4, 1, 42));
    final session = await repo.signInWithPin('100001');
    final done = [
      for (final e in await repo.listEvents(session))
        if (e.status == EventStatus.completed) e,
    ];

    final now = DateTime.utc(2026, 11, 4, 1, 42);
    final outcomes = <ShiftOutcome>[];
    final rows = <(DateTime, EventKpis)>[];
    for (final e in done) {
      final board = await repo.loadBoard(e.id);
      outcomes.addAll(attendanceOutcomes(
        shifts: board.shifts,
        punches: board.punches,
        changes: board.changes,
        rules: session.rules.attendance,
        now: now,
      ));
      final k = calculateEventKpis(
        eventId: e.id,
        shifts: board.shifts,
        needs: board.needs,
        punches: board.punches,
        attendance: session.rules.attendance,
      );
      rows.add((venueDate(e.startTime, session.venue.timeZone), k));
    }

    final people = reliabilityOf(outcomes);
    expect(people, isNotEmpty);
    for (final r in people) {
      expect(r.onTime + r.late + r.noShows + r.callOffs, r.expected, reason: r.workerId);
    }
    expect(people.any((r) => r.expected > 0), isTrue);

    final seasons = seasonSummaries(rows);
    expect(seasons.fold(0, (s, x) => s + x.events), done.length);
  });

  test('ratings are added and kept; do-not-rehire is flagged with a reason and can be cleared', () async {
    final repo = DemoWorkforceRepository(now: DateTime.utc(2026, 11, 4, 1, 42));
    final session = await repo.signInWithPin('100001');
    final person = (await repo.listWorkers(session)).firstWhere((w) => w.type == WorkerType.regular);

    await repo.rateWorker(session, workerId: person.id, stars: 5, note: 'Great with the line');
    await repo.rateWorker(session, workerId: person.id, stars: 3);
    final ratings = (await repo.loadWorkerRatings(session)).where((r) => r.workerId == person.id).toList();
    expect(ratings.length, 2);
    expect(averageRatings(ratings)[person.id], 4);
    await expectLater(repo.rateWorker(session, workerId: person.id, stars: 6), throwsA(isA<AppFailure>()));

    await repo.flagDoNotRehire(session, person.id, 'Left mid-shift without notice');
    expect((await repo.loadRehireFlags(session))[person.id], 'Left mid-shift without notice');
    await expectLater(repo.flagDoNotRehire(session, person.id, '  '), throwsA(isA<AppFailure>()));
    await repo.clearDoNotRehire(session, person.id);
    expect((await repo.loadRehireFlags(session)).containsKey(person.id), isFalse);
  });

  test('report targets: defaults until a manager saves new ones', () async {
    final repo = DemoWorkforceRepository(now: DateTime.utc(2026, 11, 4, 1, 42));
    final session = await repo.signInWithPin('100001');
    expect(await repo.loadReportTargets(session), ReportTargets.defaults);

    final saved = ReportTargets.tryCreate(fillGreen: 1, fillYellow: 0.95, attendanceGreen: 0.9, attendanceYellow: 0.8)!;
    await repo.saveReportTargets(session, saved);
    expect(await repo.loadReportTargets(session), saved);
    expect(ReportTargets.tryCreate(fillGreen: 0.9, fillYellow: 0.95, attendanceGreen: 0.9, attendanceYellow: 0.8), isNull);
  });
}
