import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:storefront_workforce/app/providers.dart';
import 'package:storefront_workforce/data/demo_repository.dart';
import 'package:storefront_workforce/data/models.dart';
import 'package:storefront_workforce/features/live/live_model.dart';
import 'package:storefront_workforce/features/reports/live_kpi_strip.dart';
import 'package:storefront_workforce/features/reports/report_tables.dart';
import 'package:storefront_workforce/features/reports/reports_providers.dart';
import 'package:storefront_workforce/features/reports/reports_screen.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4, 1, 42);
  const season = Season(2026);

  Future<(DemoWorkforceRepository, AppSession, VenueContext)> signIn(String pin) async {
    final repo = DemoWorkforceRepository(now: now);
    final session = await repo.signInWithPin(pin);
    return (repo, session, await repo.loadVenue(session));
  }

  ReportResult build(ReportData data, VenueContext venue, Season s) => buildReport(
        data: data,
        rules: venue.rules,
        timeZone: venue.venue.timeZone,
        from: s.firstDay,
        to: s.lastDay,
        now: now,
        jobRoles: venue.jobRoles,
      );

  test('the demo season report has events, money, and a season before to compare with', () async {
    final (repo, session, venue) = await signIn('100001');
    final data = await repo.loadReportData(session, season.firstDay, season.lastDay);
    final r = build(data, venue, season);
    expect(r.hasMoney, isTrue);
    expect(r.held.length, greaterThan(10));
    expect(r.upcomingEvents, isNotEmpty);
    final t = r.total;
    expect(t.fillRate, greaterThan(0.9));
    expect(t.onTimeRate, inInclusiveRange(0.7, 1.0));
    expect(t.callOffs, greaterThan(0), reason: 'the sample history has call-offs');
    expect(t.overtimeMinutes, greaterThan(0), reason: 'the preseason tournament week runs past 40 hours');
    expect(t.laborCents, greaterThan(0));
    expect(t.budgets, greaterThan(0));
    expect(t.averageHoursToFill, isNotNull);
    expect(r.npoGroups, hasLength(2));
    expect(r.tips, isNotEmpty);
    // A season is the sum of its events, an event the sum of its storefronts.
    expect(KpiTotals.sum(r.held.map((e) => e.total)).workedMinutes, t.workedMinutes);
    for (final e in r.held) {
      expect(KpiTotals.sum(e.byStorefront.values).planned, e.total.planned);
    }
    // Staffing mix covers all hours.
    expect(r.byWorkerType.values.fold(0, (s, x) => s + x.workedMinutes), t.workedMinutes);

    final last = await repo.loadReportData(session, season.previous.firstDay, season.previous.lastDay);
    final lr = build(last, venue, season.previous);
    expect(lr.held.length, greaterThan(20));
    expect(eventsOfType(lr, 'hockey'), isNotEmpty);
    expect(lr.npoGroups.every((g) => g.owedCents == 0), isTrue, reason: 'last season is paid');
  });

  test('a manager without pay access gets no money at all', () async {
    final (repo, session, venue) = await signIn('200002');
    final noPay = AppSession(
      userId: session.userId,
      displayName: session.displayName,
      venue: session.venue,
      grants: [
        for (final g in session.grants)
          RoleGrant(roleCode: g.roleCode, permissions: {...g.permissions}..remove('view_pay'), scopeType: g.scopeType, scopeId: g.scopeId),
      ],
    );
    final data = await repo.loadReportData(noPay, season.firstDay, season.lastDay);
    expect(data.money, isNull);
    final r = build(data, venue, season);
    expect(r.hasMoney, isFalse);
    expect(r.total.laborCents, 0);
    expect(r.tips, isEmpty);
    final table = eventsTable(SeasonReport(season: season, result: r, workers: data.workers, through: season.lastDay), venue, ReportTargets.defaults);
    expect(table.table.columns, isNot(contains('Labor cost')));
    expect(table.table.toCsv(), isNot(contains(r'$')));
  });

  test('employees cannot load reports', () async {
    final (repo, session, _) = await signIn('400004');
    expect(() => repo.loadReportData(session, season.firstDay, season.lastDay), throwsA(isA<AppFailure>()));
    expect(() => repo.loadWorkerSeasons(session), throwsA(isA<AppFailure>()));
  });

  test('targets: defaults, saved by settings managers only, checked', () async {
    final (repo, admin, _) = await signIn('100001');
    expect((await repo.loadReportTargets(admin)).isDefault, isTrue);
    await repo.saveReportTargets(admin, const ReportTargets(fillGreen: 0.97, fillYellow: 0.9, attendanceGreen: 0.92, attendanceYellow: 0.8));
    expect((await repo.loadReportTargets(admin)).fillGreen, 0.97);
    expect(() => repo.saveReportTargets(admin, const ReportTargets(fillGreen: 0.8, fillYellow: 0.9)), throwsA(isA<AppFailure>()));

    await repo.signOut();
    final manager = await repo.signInWithPin('200002');
    expect(() => repo.saveReportTargets(manager, const ReportTargets()), throwsA(isA<AppFailure>()));
  });

  test('turnover and retention over three seasons', () async {
    final (repo, session, _) = await signIn('100001');
    final seasons = await repo.loadWorkerSeasons(session);
    final rows = retentionBySeason(seasons);
    expect(rows.map((r) => r.season), [2024, 2025, 2026]);
    expect(rows.last.retention, inExclusiveRange(0.5, 1.0));
    expect(rows.last.priorNew, greaterThan(0));
    expect(rows.last.priorNewReturned, lessThan(rows.last.priorNew), reason: 'some of last season\'s new hires did not come back');
  });

  test('live strip numbers use the shared attendance outcomes', () async {
    final (repo, session, venue) = await signIn('200002');
    final live = repo.liveEvent!;
    final board = await repo.loadBoard(live.id);
    final at = DateTime.now().toUtc();
    final cards = evaluateBoard(board, venue.rules, at);
    final m = liveKpis(board: board, cards: cards, rules: venue.rules, now: at, needed: 10, assigned: 12);
    expect(m.fillRate, 1.0, reason: 'never above 100%');
    expect(m.missing, greaterThan(0), reason: 'the sample live game has people not arrived');
    final summary = AttendanceSummary(attendanceOutcomes(
      shifts: board.shifts,
      punches: [for (final p in board.punches) if (p.eventId == live.id) p],
      changes: board.changes,
      rules: venue.rules.attendance,
      now: at,
    ));
    expect(m.onTimeRate, summary.onTimeRate);
    expect(liveKpis(board: board, cards: cards, rules: venue.rules, now: at, needed: 0, assigned: 0).fillRate, isNull);
  });

  testWidgets('the reports screen shows targets, tabs and exports', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = DemoWorkforceRepository();
    final container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo)]);
    addTearDown(container.dispose);
    await tester.runAsync(() => container.read(sessionProvider.notifier).signIn('100001'));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ReportsScreen()),
    ));
    for (var i = 0; i < 40 && find.text('Fill rate').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('Reports'), findsOneWidget);
    expect(find.text('Fill rate'), findsWidgets);
    expect(find.text('Labor cost'), findsWidgets);
    expect(find.text('Targets'), findsOneWidget);
    expect(find.text('CSV'), findsOneWidget);
    expect(find.text('Print / PDF'), findsOneWidget);
    expect(find.textContaining('A season starts each August 1'), findsOneWidget);
    await tester.tap(find.text('People'));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('Staffing mix'), findsOneWidget);
    expect(find.text('NPO groups'), findsOneWidget);
  });
}
