import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  final call = DateTime.utc(2026, 11, 1, 0, 0);
  final now = call.add(const Duration(hours: 6));
  const rules = AttendanceRules(lateGraceMinutes: 5, noShowAfterMinutes: 60);

  Shift shift(String id, String? worker, {ShiftStatus status = ShiftStatus.assigned, String event = 'e1'}) => Shift(
        id: id,
        venueId: 'v',
        eventId: event,
        storefrontId: 'sf1',
        jobRoleCode: 'cashier',
        callTime: call,
        workerId: worker,
        status: status,
      );

  Punch clockIn(String worker, Duration after, {PunchStatus status = PunchStatus.accepted}) => Punch(
        id: 'p-$worker-${after.inMinutes}',
        venueId: 'v',
        workerId: worker,
        eventId: 'e1',
        kind: PunchKind.clockIn,
        occurredAt: call.add(after),
        status: status,
      );

  AssignmentChange removed(String worker, String shiftId, Duration before, {String reason = 'Called off sick'}) => AssignmentChange(
        id: 'c-$worker',
        eventId: 'e1',
        shiftId: shiftId,
        action: 'unassigned',
        changedAt: call.subtract(before),
        workerId: worker,
        fromStorefrontId: 'sf1',
        fromJobRoleCode: 'cashier',
        reason: reason,
      );

  AttendanceOutcome outcomeOf(List<ShiftOutcome> all, String worker) => all.singleWhere((o) => o.workerId == worker).outcome;

  test('on time within grace, late after it, with minutes late', () {
    final all = attendanceOutcomes(
      shifts: [shift('s1', 'a'), shift('s2', 'b')],
      punches: [clockIn('a', const Duration(minutes: 5)), clockIn('b', const Duration(minutes: 12))],
      changes: const [],
      rules: rules,
      now: now,
    );
    expect(outcomeOf(all, 'a'), AttendanceOutcome.onTime);
    expect(outcomeOf(all, 'b'), AttendanceOutcome.late);
    expect(all.singleWhere((o) => o.workerId == 'b').minutesLate, 12);
  });

  test('no clock-in: pending until the no-show minutes pass, then no-show', () {
    final early = attendanceOutcomes(
        shifts: [shift('s1', 'a')], punches: const [], changes: const [], rules: rules, now: call.add(const Duration(minutes: 60)));
    expect(outcomeOf(early, 'a'), AttendanceOutcome.pending);
    final later = attendanceOutcomes(
        shifts: [shift('s1', 'a')], punches: const [], changes: const [], rules: rules, now: call.add(const Duration(minutes: 61)));
    expect(outcomeOf(later, 'a'), AttendanceOutcome.noShow);
  });

  test('a voided clock-in does not count', () {
    final all = attendanceOutcomes(
      shifts: [shift('s1', 'a')],
      punches: [clockIn('a', Duration.zero, status: PunchStatus.voided)],
      changes: const [],
      rules: rules,
      now: now,
    );
    expect(outcomeOf(all, 'a'), AttendanceOutcome.noShow);
  });

  test('sent home before arriving is released; sent home after working keeps on time', () {
    final all = attendanceOutcomes(
      shifts: [shift('s1', 'a', status: ShiftStatus.released), shift('s2', 'b', status: ShiftStatus.released)],
      punches: [clockIn('b', Duration.zero)],
      changes: const [],
      rules: rules,
      now: now,
    );
    expect(outcomeOf(all, 'a'), AttendanceOutcome.released);
    expect(outcomeOf(all, 'b'), AttendanceOutcome.onTime);
    expect(AttendanceOutcome.released.counts, isFalse);
  });

  test('call-off: removed by a manager within 48 hours of call', () {
    final all = attendanceOutcomes(
      shifts: [shift('s1', null, status: ShiftStatus.open)],
      punches: const [],
      changes: [removed('a', 's1', const Duration(hours: 3))],
      rules: rules,
      now: now,
    );
    expect(outcomeOf(all, 'a'), AttendanceOutcome.callOff);
  });

  test('not a call-off: removed days ahead, an approved drop or swap, or still working the event', () {
    final all = attendanceOutcomes(
      shifts: [shift('s1', null, status: ShiftStatus.open), shift('s2', 'd')],
      punches: [clockIn('d', Duration.zero)],
      changes: [
        removed('a', 's1', const Duration(days: 5)),
        removed('b', 's1', const Duration(hours: 2), reason: 'Drop approved: family'),
        removed('c', 's1', const Duration(hours: 2), reason: 'Swap approved: C → D'),
        removed('d', 's1', const Duration(hours: 1)),
      ],
      rules: rules,
      now: now,
    );
    expect(all.where((o) => o.outcome == AttendanceOutcome.callOff), isEmpty);
    expect(outcomeOf(all, 'd'), AttendanceOutcome.onTime);
  });

  test('one outcome per person and event', () {
    final all = attendanceOutcomes(
      shifts: [shift('s1', 'a'), shift('s2', 'a')],
      punches: [clockIn('a', Duration.zero)],
      changes: [removed('a', 's1', const Duration(hours: 1)), removed('a', 's2', const Duration(hours: 1))],
      rules: rules,
      now: now,
    );
    expect(all, hasLength(1));
  });

  test('summary rates count on time, late, no-shows and call-offs', () {
    final all = attendanceOutcomes(
      shifts: [shift('s1', 'a'), shift('s2', 'b'), shift('s3', 'c'), shift('s4', null, status: ShiftStatus.open)],
      punches: [clockIn('a', Duration.zero), clockIn('b', const Duration(minutes: 20))],
      changes: [removed('d', 's4', const Duration(hours: 1))],
      rules: rules,
      now: now,
    );
    final s = AttendanceSummary(all);
    expect([s.onTime, s.late, s.noShows, s.callOffs], [1, 1, 1, 1]);
    expect(s.expected, 4);
    expect(s.onTimeRate, 0.25);
    expect(s.attendanceRate, 0.5);
    expect(s.totalMinutesLate, 20);
    expect(AttendanceSummary(const []).onTimeRate, isNull);
  });
}
