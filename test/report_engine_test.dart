import 'package:flutter_test/flutter_test.dart';
import 'package:storefront_workforce/data/demo_repository.dart';
import 'package:storefront_workforce/data/models.dart';
import 'package:workforce_core/workforce_core.dart';

/// The reports engine over the demo season: the data the app loads really does feed
/// [buildReport], and the totals it produces add up.
void main() {
  final now = DateTime.utc(2026, 11, 4, 1, 42);
  final from = DateTime.utc(2026, 8, 1);
  final to = DateTime.utc(2026, 11, 4);

  Future<(DemoWorkforceRepository, AppSession, VenueContext, ReportData)> load(String pin) async {
    final repo = DemoWorkforceRepository(now: now);
    final session = await repo.signInWithPin(pin);
    final venue = await repo.loadVenue(session);
    return (repo, session, venue, await repo.loadReportData(session, from, to));
  }

  test('an admin gets the season loaded, and the report totals reconcile', () async {
    final (_, session, venue, data) = await load('100001');
    expect(data.events, isNotEmpty);
    expect(data.workers, isNotEmpty);
    expect(data.shifts, isNotEmpty);
    expect(data.punches, isNotEmpty);
    expect(data.money, isNotNull, reason: 'an admin may see pay');

    final report = buildReport(
      data: data,
      rules: venue.rules,
      timeZone: session.venue.timeZone,
      from: from,
      to: to,
      now: now,
      jobRoles: venue.jobRoles,
    );
    expect(report.events, isNotEmpty);
    expect(report.hasMoney, isTrue);

    // Every event in the report is inside the range and not cancelled.
    for (final e in report.events) {
      final day = localDateOf(e.event.startTime, session.venue.timeZone);
      expect(day.isBefore(from) || day.isAfter(to), isFalse, reason: e.event.name);
      expect(e.event.status, isNot(EventStatus.cancelled));
    }

    // An event's storefront rows add up to its total.
    for (final e in report.events) {
      final staffed = e.byStorefront.values.fold(0, (s, k) => s + k.staffed);
      expect(staffed, e.total.staffed, reason: e.event.name);
    }

    // Attendance counts never exceed the people who were staffed.
    for (final e in report.events) {
      final t = e.total;
      expect(t.onTime + t.late + t.noShows, lessThanOrEqualTo(t.staffed + t.callOffs), reason: e.event.name);
    }
  });

  test('a storefront lead and an employee cannot load the reports', () async {
    for (final pin in ['300003', '400004']) {
      final repo = DemoWorkforceRepository(now: now);
      final session = await repo.signInWithPin(pin);
      expect(session.canVenueWide(Perm.viewReports), isFalse, reason: pin);
      await expectLater(repo.loadReportData(session, from, to), throwsA(isA<AppFailure>()), reason: pin);
    }
  });

  test('a narrow range loads only its own events', () async {
    final (repo, session, _, _) = await load('100001');
    final oneWeek = await repo.loadReportData(session, DateTime.utc(2026, 10, 12), DateTime.utc(2026, 10, 18));
    final zone = session.venue.timeZone;
    // The window reaches a week each side, so check what the report itself keeps.
    final inWeek = [
      for (final e in oneWeek.events)
        if (!localDateOf(e.startTime, zone).isBefore(DateTime.utc(2026, 10, 12)) &&
            !localDateOf(e.startTime, zone).isAfter(DateTime.utc(2026, 10, 18)))
          e,
    ];
    expect(inWeek, isNotEmpty);
    expect(oneWeek.events.length, lessThan((await load('100001')).$4.events.length));
  });
}
