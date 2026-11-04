import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  group('targets', () {
    test('defaults when the venue has no row', () {
      final t = ReportTargets.fromRow(null);
      expect((t.fillGreen, t.fillYellow, t.attendanceGreen, t.attendanceYellow), (0.98, 0.90, 0.95, 0.85));
      expect(t.isDefault, isTrue);
      expect(t.budgetYellowOver, 0.10);
    });

    test('a saved row (numbers may arrive as strings) and the budget setting', () {
      final t = ReportTargets.fromRow(
        {'fill_green': '0.9500', 'fill_yellow': 0.8, 'attendance_green': 0.9, 'attendance_yellow': '0.7'},
        settings: {
          'reports': {'budget_yellow_over_percent': 5},
        },
      );
      expect((t.fillGreen, t.fillYellow, t.attendanceGreen, t.attendanceYellow), (0.95, 0.8, 0.9, 0.7));
      expect(t.budgetYellowOver, 0.05);
      expect(t.isDefault, isFalse);
      expect(t.toRow('v')['fill_green'], 0.95);
    });

    test('green at or above green, yellow at or above yellow, else red; none without data', () {
      const t = ReportTargets();
      expect(t.fill(49 / 50), Rag.green);
      expect(t.fill(0.97), Rag.yellow);
      expect(t.fill(0.90), Rag.yellow);
      expect(t.fill(0.899), Rag.red);
      expect(t.attendance(null), Rag.none);
      expect(t.attendance(0.95), Rag.green);
      expect(t.attendance(0.84), Rag.red);
    });

    test('budget: under is green, up to 10% over yellow, more red, no budget none', () {
      expect(budgetRag(1000, 1000), Rag.green);
      expect(budgetRag(1100, 1000), Rag.yellow);
      expect(budgetRag(1101, 1000), Rag.red);
      expect(budgetRag(5, 0), Rag.red, reason: 'any cost against a zero budget is over');
      expect(budgetRag(0, 0), Rag.green);
      expect(budgetRag(500, null), Rag.none);
      expect(budgetRag(1050, 1000, yellowOver: 0.05), Rag.yellow);
      expect(budgetRag(1051, 1000, yellowOver: 0.05), Rag.red);
    });

    test('validation matches the database checks', () {
      expect(const ReportTargets().validate(), isNull);
      expect(const ReportTargets(fillGreen: 0.9, fillYellow: 0.95).validate(), contains('fill'));
      expect(const ReportTargets(attendanceGreen: 0.8, attendanceYellow: 0.9).validate(), contains('on-time'));
      expect(const ReportTargets(fillGreen: 1.2).validate(), contains('between'));
    });
  });

  group('seasons', () {
    test('August start by default; months before August belong to the season before', () {
      expect(Season.of(DateTime.utc(2026, 11, 4)).startYear, 2026);
      expect(Season.of(DateTime.utc(2026, 7, 31)).startYear, 2025);
      expect(Season.of(DateTime.utc(2026, 8, 1)).startYear, 2026);
      const s = Season(2026);
      expect(s.label, '2026–27');
      expect(s.firstDay, DateTime.utc(2026, 8, 1));
      expect(s.lastDay, DateTime.utc(2027, 7, 31));
      expect(s.rangeLabel, 'Aug 1, 2026 – Jul 31, 2027');
      expect(s.previous, const Season(2025));
      expect(s.contains(DateTime.utc(2027, 7, 31)), isTrue);
      expect(s.contains(DateTime.utc(2027, 8, 1)), isFalse);
    });

    test('start month from venue settings; a calendar-year season', () {
      expect(Season.startMonthFrom({}), 8);
      expect(Season.startMonthFrom({'reports': {'season_start_month': 9}}), 9);
      expect(Season.startMonthFrom({'reports': {'season_start_month': 13}}), 8);
      final s = Season.of(DateTime.utc(2026, 3, 1), startMonth: 1);
      expect(s.label, '2026');
      expect(s.lastDay, DateTime.utc(2026, 12, 31));
    });
  });

  group('turnover and retention', () {
    WorkerSeason ws(String w, int s) => WorkerSeason(workerId: w, season: s, eventsWorked: 3);

    test('returning, new, retention, and new hires who came back', () {
      final rows = retentionBySeason([
        ws('a', 2024), ws('b', 2024), ws('c', 2024), ws('d', 2024),
        ws('a', 2025), ws('b', 2025), ws('e', 2025), ws('f', 2025),
        ws('a', 2026), ws('e', 2026), ws('g', 2026), ws('c', 2026),
      ]);
      expect(rows.map((r) => r.season), [2024, 2025, 2026]);
      expect(rows[0].retention, isNull, reason: 'nothing before the first season');
      expect(rows[1].returning, 2);
      expect(rows[1].retention, 0.5);
      expect(rows[1].turnover, 0.5);
      expect(rows[1].newStaff, 2);
      expect(rows[2].returning, 2, reason: 'a and e');
      expect(rows[2].newStaff, 1, reason: 'c came back after a year away, so only g is new');
      expect(rows[2].priorNew, 2);
      expect(rows[2].priorNewReturned, 1);
      expect(rows[2].newHireReturnRate, 0.5);
    });

    test('a season with nobody, and filters', () {
      final rows = retentionBySeason([ws('a', 2023), ws('a', 2025), ws('t', 2025)], onlyWorkers: {'a'});
      expect(rows.map((r) => r.staff), [1, 0, 1]);
      expect(rows[1].retention, 0);
      expect(rows[2].retention, isNull);
      expect(retentionBySeason(const []), isEmpty);
    });

    test('seasons from clock-ins, ignoring voided punches and cancelled events', () {
      Event ev(String id, DateTime start, [EventStatus st = EventStatus.completed]) =>
          Event(id: id, venueId: 'v', name: id, eventTypeCode: 'hockey', startTime: start, callTime: start, doorsTime: start, status: st);
      // 2026-08-01 01:00 UTC is still July 31 in Chicago.
      final events = {
        for (final e in [ev('jul', DateTime.utc(2026, 8, 1, 1)), ev('aug', DateTime.utc(2026, 8, 2, 1)), ev('x', DateTime.utc(2026, 9, 1), EventStatus.cancelled)]) e.id: e,
      };
      Punch p(String id, String e, {PunchStatus status = PunchStatus.accepted}) =>
          Punch(id: id, venueId: 'v', workerId: 'a', eventId: e, kind: PunchKind.clockIn, occurredAt: events[e]!.startTime, status: status);
      final rows = workerSeasonsFromPunches(
        punches: [p('1', 'jul'), p('2', 'aug'), p('3', 'aug'), p('4', 'x'), p('5', 'aug', status: PunchStatus.voided)],
        events: events,
        timeZone: 'America/Chicago',
      );
      expect([for (final r in rows) (r.season, r.eventsWorked)], [(2025, 1), (2026, 1)]);
    });
  });

  group('certifications', () {
    const roles = [
      JobRole(venueId: 'v', code: 'cook', name: 'Cook', requiredCertifications: ['food']),
      JobRole(venueId: 'v', code: 'cashier', name: 'Cashier'),
    ];
    final today = DateTime.utc(2026, 11, 4);
    WorkerCertification cert(String w, DateTime? expires) => WorkerCertification(id: 'c$w', workerId: w, typeCode: 'food', number: '1', expiresOn: expires);
    Worker w(String id, List<String> r, List<WorkerCertification> c, {String status = 'active'}) =>
        Worker(id: id, venueId: 'v', type: WorkerType.regular, employeeNumber: id, firstName: id, lastName: 'X', jobRoles: r, certifications: c, status: status);

    test('compliant for every trained role, expiring within 30 days still counts as compliant', () {
      final c = certificationCompliance(
        workers: [
          w('ok', ['cook'], [cert('ok', DateTime.utc(2027, 6, 1))]),
          w('soon', ['cook'], [cert('soon', DateTime.utc(2026, 11, 30))]),
          w('expired', ['cook'], [cert('expired', DateTime.utc(2026, 11, 3))]),
          w('missing', ['cook', 'cashier'], const []),
          w('cashier', ['cashier'], const []),
          w('gone', ['cook'], const [], status: 'inactive'),
        ],
        jobRoles: roles,
        onDate: today,
      );
      expect(c.people, 4);
      expect(c.compliant, 2);
      expect(c.rate, 0.5);
      expect(c.expiringSoon.map((e) => e.$1), ['soon']);
      expect(c.expiredOrMissing, ['expired', 'missing']);
      expect(c.byType['food'], (4, 2));
    });

    test('nobody needs a certification: no rate', () {
      final c = certificationCompliance(workers: [w('a', ['cashier'], const [])], jobRoles: roles, onDate: today);
      expect(c.rate, isNull);
    });
  });

  group('exports', () {
    test('CSV quotes commas, quotes and line breaks, and defuses formulas', () {
      const t = ReportTable(title: 'T', columns: ['Name', 'Value'], rows: [
        ['Smith, Jo', '-12.5'],
        ['Say "hi"', '=HYPERLINK("x")'],
        ['two\nlines', '-\$1,200.00'],
      ]);
      expect(
        t.toCsv(),
        'Name,Value\r\n"Smith, Jo",-12.5\r\n"Say ""hi""","\'=HYPERLINK(""x"")"\r\n"two\nlines","-\$1,200.00"\r\n',
      );
      expect(tablesToCsv([t, t]).split('\r\n').first, 'T');
    });

    test('print page escapes text and lays out every table', () {
      final html = reportHtml(title: 'A & B', subtitle: '<x>', tables: const [
        ReportTable(title: 'Events', columns: ['Event', 'Fill'], rows: [
          ['<script>', '98%'],
        ]),
        ReportTable(title: 'Empty', columns: ['X'], rows: []),
      ]);
      expect(html, contains('<title>A &amp; B</title>'));
      expect(html, contains('&lt;script&gt;'));
      expect(html, isNot(contains('<td><script>')));
      expect(html, contains('<td class="n">98%</td>'));
      expect(html, contains('Nothing to show.'));
      expect(html, contains('window.print()'));
      expect(reportHtml(title: 't', subtitle: '', tables: const [], autoPrint: false), isNot(contains('addEventListener')));
    });
  });

  group('sample history', () {
    final now = DateTime.utc(2026, 11, 4, 1, 42);
    final arena = SampleArena.generate(now: now);
    final h = SampleHistory.generate(arena);

    test('is deterministic', () {
      final again = SampleHistory.generate(SampleArena.generate(now: now));
      expect(again.events.map((e) => e.id), h.events.map((e) => e.id));
      expect(again.punches.length, h.punches.length);
      expect(again.changes.length, h.changes.length);
      expect(again.eventBudgetsCents, h.eventBudgetsCents);
    });

    test('covers two earlier seasons and preseason games, all before the arena events', () {
      final seasons = {for (final e in h.events) Season.of(localDateOf(e.startTime, arena.venue.timeZone)).startYear};
      expect(seasons, {2024, 2025, 2026});
      final firstArena = arena.events.map((e) => e.startTime).reduce((a, b) => a.isBefore(b) ? a : b);
      expect(h.events.every((e) => e.startTime.isBefore(firstArena)), isTrue);
      expect(h.events.every((e) => e.status == EventStatus.completed), isTrue);
      expect(h.formerWorkers.every((w) => w.status == 'inactive'), isTrue);
      final ids = {for (final w in [...arena.workers, ...h.formerWorkers]) w.id};
      expect(h.shifts.every((s) => s.workerId == null || ids.contains(s.workerId)), isTrue);
      expect(h.changes.any((c) => c.action == 'unassigned'), isTrue, reason: 'some call-offs');
      expect(h.npoPayouts.every((p) => p.status == 'paid'), isTrue);
      for (final e in arena.events) {
        expect(h.eventBudgetsCents.containsKey(e.id), isTrue);
      }
    });
  });
}
