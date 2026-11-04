import 'package:flutter_test/flutter_test.dart';
import 'package:storefront_workforce/data/demo_repository.dart';
import 'package:storefront_workforce/data/models.dart';
import 'package:storefront_workforce/data/performance_repository.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4, 1, 42);

  Future<(DemoWorkforceRepository, AppSession)> signIn(String pin, [DemoWorkforceRepository? repo]) async {
    final r = repo ?? DemoWorkforceRepository(now: now);
    await r.signOut();
    return (r, await r.signInWithPin(pin));
  }

  group('demo data', () {
    test('past events have every kind of outcome, varied scores, ratings and one flag', () async {
      final (repo, admin) = await signIn('100001');
      final data = await repo.loadPerformance(admin);
      final summary = AttendanceSummary(data.outcomes);
      expect(summary.onTime, greaterThan(100));
      expect(summary.late, greaterThan(5));
      expect(summary.noShows, greaterThan(0));
      expect(summary.callOffs, greaterThanOrEqualTo(8), reason: 'the demo adds call-offs');
      final scores = data.scores().values.where((s) => s.score != null).map((s) => s.score!).toSet();
      expect(scores.length, greaterThanOrEqualTo(4), reason: 'scores vary');
      expect(scores.any((s) => s < 75), isTrue, reason: 'someone is unreliable');
      expect(data.ratings.length, greaterThan(20));
      expect(data.flags.length, 1);
      expect(data.events.values.every((e) => !e.callTime.isAfter(data.now)), isTrue);
    });

    test('the same every time (deterministic)', () async {
      final (a, sa) = await signIn('100001');
      final (b, sb) = await signIn('100001', DemoWorkforceRepository(now: now));
      final da = await a.loadPerformance(sa);
      final db = await b.loadPerformance(sb);
      expect(da.flags.keys, db.flags.keys);
      expect([for (final r in da.ratings) '${r.workerId}${r.stars}${r.note}'], [for (final r in db.ratings) '${r.workerId}${r.stars}${r.note}']);
      expect(da.outcomes.length, db.outcomes.length);
    });

    test('the demo employees are never the flagged person', () async {
      final (repo, admin) = await signIn('100001');
      final flags = (await repo.loadPerformance(admin)).flags.keys.toSet();
      for (final pin in ['300003', '400004', '400005']) {
        final (_, s) = await signIn(pin, repo);
        expect(flags.contains(s.workerId), isFalse, reason: pin);
      }
    });
  });

  group('who sees what', () {
    test('employees, leads and partners cannot read or change any of it', () async {
      final repo = DemoWorkforceRepository(now: now);
      final (_, admin) = await signIn('100001', repo);
      final someone = (await repo.listWorkers(admin)).first;
      for (final pin in ['400004', '400005', '300003', '600006', '700007']) {
        final (_, s) = await signIn(pin, repo);
        expect(() => repo.loadPerformance(s), throwsA(isA<AppFailure>()), reason: pin);
        expect(() => repo.workerPerformance(s, s.workerId ?? someone.id), throwsA(isA<AppFailure>()), reason: '$pin, even about themselves');
        expect(() => repo.addRating(s, someone.id, stars: 5), throwsA(isA<AppFailure>()), reason: pin);
        expect(() => repo.addNote(s, someone.id, 'x'), throwsA(isA<AppFailure>()), reason: pin);
        expect(() => repo.setDoNotRehire(s, someone.id, 'x'), throwsA(isA<AppFailure>()), reason: pin);
      }
    });
  });

  group('ratings, notes and flags', () {
    test('a manager rates, adds a note, flags, edits the reason and clears', () async {
      final (repo, manager) = await signIn('200002');
      final w = (await repo.listWorkers(manager)).firstWhere((w) => w.type == WorkerType.regular);
      await repo.addRating(manager, w.id, stars: 4, note: 'Steady on the register');
      await repo.addNote(manager, w.id, 'Wants more weekend shifts');
      var d = await repo.workerPerformance(manager, w.id);
      expect(d.ratings.first.stars, 4);
      expect(d.ratings.first.ratedByName, 'Marcus Bell');
      expect(d.notes.first.body, 'Wants more weekend shifts');
      expect(() => repo.addRating(manager, w.id, stars: 6), throwsA(isA<AppFailure>()));
      expect(() => repo.addNote(manager, w.id, '   '), throwsA(isA<AppFailure>()));
      expect(() => repo.setDoNotRehire(manager, w.id, ''), throwsA(isA<AppFailure>()));

      await repo.setDoNotRehire(manager, w.id, 'Walked out');
      d = await repo.workerPerformance(manager, w.id);
      final firstAt = d.flag!.flaggedAt;
      await repo.setDoNotRehire(manager, w.id, 'Walked out twice');
      d = await repo.workerPerformance(manager, w.id);
      expect(d.flag!.reason, 'Walked out twice');
      expect(d.flag!.flaggedAt, firstAt, reason: 'only the reason changes');
      expect((await repo.loadPerformance(manager)).flags.containsKey(w.id), isTrue);
      await repo.clearDoNotRehire(manager, w.id);
      expect((await repo.workerPerformance(manager, w.id)).flag, isNull);
    });

    test('a flagged person cannot be put in a position', () async {
      final (repo, manager) = await signIn('200002');
      final events = await repo.listEvents(manager);
      final upcoming = events.firstWhere((e) => e.status == EventStatus.scheduled);
      await repo.generateOpenShifts(upcoming.id);
      final board = await repo.loadBoard(upcoming.id);
      final open = board.shifts.firstWhere((s) => s.isOpen && s.jobRoleCode == 'cashier');
      final candidate = (await repo.candidates(upcoming.id, 'cashier')).firstWhere((c) => c.worker.type == WorkerType.regular);
      await repo.setDoNotRehire(manager, candidate.id, 'Policy');
      await expectLater(repo.assign(open.id, candidate.id), throwsA(predicate((e) => e is AppFailure && e.message.contains('do not rehire'))));
      await repo.clearDoNotRehire(manager, candidate.id);
      await repo.assign(open.id, candidate.id);
    });
  });

  group('reliability', () {
    test('a call-off made in the demo shows in the person\'s score breakdown', () async {
      final (repo, admin) = await signIn('100001');
      final data = await repo.loadPerformance(admin);
      final callOff = data.outcomes.firstWhere((o) => o.outcome == AttendanceOutcome.callOff);
      final s = data.scoreOf(callOff.workerId);
      expect(s.callOffs, greaterThan(0));
      expect(s.breakdown, contains('call-off'));
      expect(s.score, lessThanOrEqualTo(90));
    });

    test('rankings put flagged and unreliable people below reliable ones', () async {
      final (repo, admin) = await signIn('100001');
      final data = await repo.loadPerformance(admin);
      final workers = await repo.listWorkers(admin);
      final ranked = sortRankings(
        buildRankings(
          workers: workers,
          outcomes: data.outcomes,
          ratings: [for (final r in data.ratings) (r.workerId, r.stars)],
          flagged: data.flags.keys.toSet(),
          rules: data.rules,
          now: data.now,
        ),
        RankingSort.reliability,
      );
      expect(ranked.first.score, 100);
      final flagged = ranked.indexWhere((e) => e.flagged);
      expect(flagged, greaterThan(0));
      expect(ranked.where((e) => e.score != null && !e.reliability.isNew).last.score, lessThan(100));
    });
  });

  group('staffing suggestions', () {
    test('suggest headcount for the next hockey game from past games, and "use" sets the need', () async {
      final (repo, manager) = await signIn('200002');
      final venue = await repo.loadVenue(manager);
      final events = await repo.listEvents(manager);
      final next = events.firstWhere((e) => e.status == EventStatus.scheduled && e.eventTypeCode == 'hockey');
      final history = await repo.staffingHistory(manager, 'hockey');
      expect(history, isNotEmpty);
      expect(history.every((h) => h.eventTypeCode == 'hockey'), isTrue);

      final board = await repo.loadBoard(next.id);
      final s = suggestStaffing(
        eventTypeCode: 'hockey',
        typeName: venue.eventTypes['hockey']!,
        expectedAttendance: next.expectedAttendance,
        storefrontIds: board.openStorefrontIds,
        history: history,
        defaults: venue.defaultNeeds,
        excludeEventId: next.id,
      );
      final used = s.values.where((x) => !x.fallback).toList();
      expect(used, isNotEmpty);
      expect(used.first.explanation, startsWith('Based on '));
      expect(used.first.explanation, contains('hockey game'));

      // Use one suggestion through the normal staffing-need path.
      final pick = used.first;
      final role = pick.counts.keys.first;
      await repo.setStaffingNeed(next.id, pick.storefrontId, role, pick.counts[role]!);
      final after = await repo.loadBoard(next.id);
      expect(after.needs.singleWhere((n) => n.storefrontId == pick.storefrontId && n.jobRoleCode == role).count, pick.counts[role]);
    });

    test('only schedulers can load the history', () async {
      final (repo, employee) = await signIn('400004');
      expect(() => repo.staffingHistory(employee, 'hockey'), throwsA(isA<AppFailure>()));
    });
  });

  test('models read database rows', () {
    final r = WorkerRating.fromJson({
      'id': 'r1',
      'worker_id': 'w1',
      'event_id': null,
      'stars': 3,
      'note': 'ok',
      'rated_at': '2026-11-01T02:00:00+00:00',
    }, ratedByName: 'Dana');
    expect((r.stars, r.ratedByName, r.ratedAt.isUtc), (3, 'Dana', true));
    final n = WorkerNote.fromJson({'id': 'n1', 'worker_id': 'w1', 'body': 'hi', 'written_at': '2026-11-01T02:00:00Z'});
    expect(n.body, 'hi');
    final f = RehireFlag.fromJson({'worker_id': 'w1', 'reason': 'x', 'flagged_at': '2026-11-01T02:00:00Z'});
    expect(f.reason, 'x');
    expect(const WorkerPerformanceDetail(ratings: [], notes: []).averageStars, isNull);
  });
}
