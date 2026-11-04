import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4, 12);
  const rules = ReliabilityRules();

  /// One outcome [daysAgo] days before now.
  ShiftOutcome o(AttendanceOutcome outcome, int daysAgo, {String worker = 'w1', int minutesLate = 0, String? event}) => ShiftOutcome(
        workerId: worker,
        eventId: event ?? 'e$daysAgo',
        storefrontId: 'sf1',
        jobRoleCode: 'cashier',
        callTime: now.subtract(Duration(days: daysAgo)),
        outcome: outcome,
        minutesLate: minutesLate,
      );

  group('rules', () {
    test('defaults, and the one-sentence explanation names every weight', () {
      expect(rules.windowEvents, 10);
      expect(rules.windowDays, 365);
      expect(rules.noShowPoints, 25);
      expect(rules.callOffPoints, 10);
      expect(rules.latePoints, 5);
      expect(rules.minEvents, 3);
      expect(rules.explain, 'Starts at 100, minus 25 for each no-show, 10 for each call-off and 5 for each late arrival, '
          'over the last 10 events in the past year.');
    });

    test('read from venue settings; missing or bad values keep the defaults', () {
      final r = ReliabilityRules.fromVenueSettings({
        'reliability': {'no_show_points': 30, 'late_points': 2, 'window_events': 0, 'window_days': 90, 'call_off_points': -1},
      });
      expect(r.noShowPoints, 30);
      expect(r.latePoints, 2);
      expect(r.windowEvents, 10, reason: 'zero events would score nobody');
      expect(r.callOffPoints, 10, reason: 'negative points are ignored');
      expect(r.windowDays, 90);
      expect(r.explain, contains('past 90 days'));
      expect(ReliabilityRules.fromVenueSettings(null).toJson(), const ReliabilityRules().toJson());
      expect(ReliabilityRules.fromVenueSettings({'reliability': r.toJson()}).toJson(), r.toJson());
    });
  });

  group('score', () {
    test('perfect attendance is 100', () {
      final s = reliabilityOf('w1', [for (var i = 1; i <= 5; i++) o(AttendanceOutcome.onTime, i * 7)], rules: rules, now: now);
      expect(s.score, 100);
      expect(s.events, 5);
      expect(s.isNew, isFalse);
      expect(s.breakdown, '100 = 100 over 5 events');
    });

    test('takes off the points for each no-show, call-off and late arrival', () {
      final s = reliabilityOf(
        'w1',
        [
          o(AttendanceOutcome.onTime, 3),
          o(AttendanceOutcome.late, 10, minutesLate: 12),
          o(AttendanceOutcome.late, 17, minutesLate: 40),
          o(AttendanceOutcome.noShow, 24),
          o(AttendanceOutcome.callOff, 31),
          o(AttendanceOutcome.onTime, 38),
        ],
        rules: rules,
        now: now,
      );
      expect(s.score, 100 - 25 - 10 - 2 * 5);
      expect((s.noShows, s.callOffs, s.lates, s.onTime), (1, 1, 2, 2));
      expect((s.noShowPoints, s.callOffPoints, s.latePoints), (25, 10, 10));
      expect(s.breakdown, '100 − 25 (1 no-show) − 10 (1 call-off) − 10 (2 late) = 55 over 6 events');
      expect(s.summary.expected, 6);
      expect(s.summary.attendanceRate, closeTo(4 / 6, 1e-9));
    });

    test('never below 0, and says so', () {
      final s = reliabilityOf('w1', [for (var i = 1; i <= 5; i++) o(AttendanceOutcome.noShow, i)], rules: rules, now: now);
      expect(s.score, 0);
      expect(s.breakdown, '100 − 125 (5 no-shows) = 0 (lowest is 0) over 5 events');
    });

    test('only the last 10 events count; older mistakes drop off', () {
      final s = reliabilityOf(
        'w1',
        [
          for (var i = 1; i <= 10; i++) o(AttendanceOutcome.onTime, i),
          o(AttendanceOutcome.noShow, 11), // the 11th most recent
        ],
        rules: rules,
        now: now,
      );
      expect(s.score, 100);
      expect(s.events, 10);
      expect(s.counted.first.callTime.isAfter(s.counted.last.callTime), isTrue, reason: 'most recent first');
    });

    test('events older than the window do not count, nor future ones', () {
      final s = reliabilityOf('w1', [
        o(AttendanceOutcome.noShow, 366),
        o(AttendanceOutcome.onTime, 365),
        o(AttendanceOutcome.noShow, -1), // a call time after now (bad data) is ignored
      ], rules: rules, now: now);
      expect(s.score, 100);
      expect(s.events, 1);
    });

    test('released and pending never count for or against', () {
      final s = reliabilityOf('w1', [
        o(AttendanceOutcome.released, 2),
        o(AttendanceOutcome.pending, 0),
        o(AttendanceOutcome.onTime, 5),
      ], rules: rules, now: now);
      expect(s.events, 1);
      expect(s.score, 100);
    });

    test('nothing to judge: null score; fewer than 3 events: new', () {
      final none = reliabilityOf('w1', [o(AttendanceOutcome.onTime, 2, worker: 'other')], rules: rules, now: now);
      expect(none.score, isNull);
      expect(none.isNew, isTrue);
      expect(none.breakdown, 'No events in the past year.');
      final two = reliabilityOf('w1', [o(AttendanceOutcome.onTime, 2), o(AttendanceOutcome.late, 9)], rules: rules, now: now);
      expect(two.score, 95);
      expect(two.isNew, isTrue);
    });

    test('custom weights from settings change the result', () {
      final strict = ReliabilityRules.fromJson({'late_points': 15, 'window_events': 3});
      final s = reliabilityOf('w1', [
        o(AttendanceOutcome.late, 1),
        o(AttendanceOutcome.late, 2),
        o(AttendanceOutcome.onTime, 3),
        o(AttendanceOutcome.noShow, 4),
      ], rules: strict, now: now);
      expect(s.score, 70);
      expect(s.events, 3);
    });

    test('same day ties are ordered by event, so results are stable', () {
      final a = reliabilityOf('w1', [
        for (var i = 0; i < 12; i++) o(i.isEven ? AttendanceOutcome.onTime : AttendanceOutcome.late, 1, event: 'e$i'),
      ], rules: rules, now: now);
      final b = reliabilityOf('w1', [
        for (var i = 11; i >= 0; i--) o(i.isEven ? AttendanceOutcome.onTime : AttendanceOutcome.late, 1, event: 'e$i'),
      ], rules: rules, now: now);
      expect(a.counted.map((x) => x.eventId), b.counted.map((x) => x.eventId));
      expect(a.score, b.score);
    });
  });

  test('scores for everyone, including people with no events', () {
    final all = reliabilityScores(
      [o(AttendanceOutcome.onTime, 1), o(AttendanceOutcome.noShow, 1, worker: 'w2')],
      rules: rules,
      now: now,
      workerIds: ['w3'],
    );
    expect(all.keys.toSet(), {'w1', 'w2', 'w3'});
    expect(all['w1']!.score, 100);
    expect(all['w2']!.score, 75);
    expect(all['w3']!.score, isNull);
  });

  test('bands', () {
    expect(reliabilityBand(100), 'Strong');
    expect(reliabilityBand(90), 'Strong');
    expect(reliabilityBand(89), 'OK');
    expect(reliabilityBand(75), 'OK');
    expect(reliabilityBand(74), 'Watch');
    expect(reliabilityBand(50), 'Watch');
    expect(reliabilityBand(49), 'Poor');
  });

  test('end to end with the shared outcomes: no-show, call-off, late and on time', () {
    final call = now.subtract(const Duration(days: 3));
    Shift shift(String id, String? worker) => Shift(
          id: id,
          venueId: 'v',
          eventId: 'e1',
          storefrontId: 'sf1',
          jobRoleCode: 'cashier',
          callTime: call,
          workerId: worker,
          status: ShiftStatus.assigned,
        );
    Punch inAt(String worker, int minutes) => Punch(
          id: 'p$worker',
          venueId: 'v',
          workerId: worker,
          eventId: 'e1',
          kind: PunchKind.clockIn,
          occurredAt: call.add(Duration(minutes: minutes)),
        );
    final outcomes = attendanceOutcomes(
      shifts: [shift('s1', 'a'), shift('s2', 'b'), shift('s3', 'c'), shift('s4', 'x')],
      punches: [inAt('a', 0), inAt('b', 20), inAt('x', 1)],
      changes: [
        AssignmentChange(
          id: '1',
          eventId: 'e1',
          shiftId: 's4',
          action: 'unassigned',
          changedAt: call.subtract(const Duration(hours: 5)),
          workerId: 'd',
          reason: 'Called off',
        ),
      ],
      rules: const AttendanceRules(),
      now: now,
    );
    final scores = reliabilityScores(outcomes, rules: rules, now: now);
    expect(scores['a']!.score, 100);
    expect(scores['b']!.score, 95);
    expect(scores['c']!.score, 75);
    expect(scores['d']!.score, 90);
  });
}
