import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

const tz = 'America/Chicago';
const rules = VenueRules.texasDefaults;

DateTime ct(int y, int m, int d, [int h = 0, int min = 0]) => localToUtc(tz, y, m, d, h, min);

Event event(String id, DateTime day, {int hour = 19, EventStatus status = EventStatus.completed, int expected = 4000, int? actual, String type = 'hockey'}) {
  final start = ct(day.year, day.month, day.day, hour);
  return Event(
    id: id,
    venueId: 'v',
    name: 'Event $id',
    eventTypeCode: type,
    startTime: start,
    doorsTime: start.subtract(const Duration(minutes: 60)),
    callTime: start.subtract(const Duration(minutes: 150)),
    endTime: start.add(const Duration(minutes: 165)),
    expectedAttendance: expected,
    actualAttendance: actual,
    status: status,
  );
}

Worker worker(String id, {WorkerType type = WorkerType.regular, String? npo, String? agency, List<String> roles = const ['cashier']}) => Worker(
      id: id,
      venueId: 'v',
      type: type,
      employeeNumber: id,
      firstName: id,
      lastName: 'X',
      npoGroupId: npo,
      agencyId: agency,
      jobRoles: roles,
      dateOfBirth: DateTime.utc(1990, 1, 1),
    );

Shift shift(String id, Event e, String sf, {String? w, String role = 'cashier', ShiftStatus? status}) => Shift(
      id: id,
      venueId: 'v',
      eventId: e.id,
      storefrontId: sf,
      jobRoleCode: role,
      workerId: w,
      callTime: e.callTime,
      scheduledEnd: e.endTime!.add(const Duration(minutes: 45)),
      status: status ?? (w == null ? ShiftStatus.open : ShiftStatus.assigned),
    );

var _p = 0;
Punch punch(String w, Event? e, Shift? s, PunchKind kind, DateTime at, {BreakKind? breakKind}) => Punch(
      id: 'p${_p++}',
      venueId: 'v',
      workerId: w,
      eventId: e?.id,
      shiftId: s?.id,
      kind: kind,
      breakKind: breakKind,
      occurredAt: at,
    );

/// Clock in [late] minutes after call and out [hours] after call.
List<Punch> worked(String w, Event e, Shift s, {int late = -5, double hours = 6}) => [
      punch(w, e, s, PunchKind.clockIn, e.callTime.add(Duration(minutes: late))),
      punch(w, e, s, PunchKind.clockOut, e.callTime.add(Duration(minutes: (hours * 60).round()))),
    ];

ReportResult run(ReportData data, {DateTime? from, DateTime? to, DateTime? now}) => buildReport(
      data: data,
      rules: rules,
      timeZone: tz,
      from: from ?? DateTime.utc(2026, 10, 1),
      to: to ?? DateTime.utc(2026, 10, 31),
      now: now ?? DateTime.utc(2026, 11, 4),
    );

void main() {
  final day = DateTime.utc(2026, 10, 14); // a Wednesday
  final e1 = event('e1', day, actual: 5000);
  final workers = {for (final w in [worker('a'), worker('b'), worker('c')]) w.id: w};

  group('headcount', () {
    test('staffed out of planned, capped at the plan, closed storefronts left out', () {
      final s = [
        shift('s1', e1, 'sf1', w: 'a'),
        shift('s2', e1, 'sf1', w: 'b'),
        shift('s3', e1, 'sf1'),
        shift('s4', e1, 'sf2', w: 'c'), // closed storefront
      ];
      final r = run(ReportData(
        events: [e1],
        workers: workers,
        eventStorefronts: const [
          EventStorefront(eventId: 'e1', storefrontId: 'sf1'),
          EventStorefront(eventId: 'e1', storefrontId: 'sf2', isOpen: false),
        ],
        needs: const [StaffingNeed(eventId: 'e1', storefrontId: 'sf1', jobRoleCode: 'cashier', count: 2)],
        shifts: s,
      ));
      final t = r.event('e1')!.total;
      expect(t.planned, 2);
      expect(t.staffed, 2, reason: 'three positions on the schedule, but the plan is two');
      expect(t.fillRate, 1.0);
      expect(t.open, 0);
      expect(r.event('e1')!.byStorefront['sf2']?.planned ?? 0, 0, reason: 'a closed storefront plans nothing');
    });

    test('no staffing need: the positions on the schedule are the plan', () {
      final r = run(ReportData(events: [e1], workers: workers, shifts: [shift('s1', e1, 'sf1', w: 'a'), shift('s2', e1, 'sf1')]));
      expect(r.event('e1')!.total.planned, 2);
      expect(r.event('e1')!.total.staffed, 1);
      expect(r.event('e1')!.total.fillRate, 0.5);
    });

    test('zero planned gives no fill rate, not 0% or 100%', () {
      final r = run(ReportData(events: [e1], workers: workers));
      expect(r.event('e1')!.total.planned, 0);
      expect(r.event('e1')!.total.fillRate, isNull);
      expect(r.total.fillRate, isNull);
      expect(const ReportTargets().fill(r.total.fillRate), Rag.none);
    });

    test('upcoming events count for headcount only, separately', () {
      final up = event('e2', DateTime.utc(2026, 10, 30), status: EventStatus.scheduled);
      final r = run(
        ReportData(events: [e1, up], workers: workers, shifts: [shift('s1', e1, 'sf1', w: 'a'), shift('u1', up, 'sf1'), shift('u2', up, 'sf1', w: 'b')]),
        now: DateTime.utc(2026, 10, 20),
      );
      expect(r.held.map((e) => e.event.id), ['e1']);
      expect(r.upcoming.planned, 2);
      expect(r.upcoming.open, 1);
      expect(r.total.planned, 1, reason: 'the season total is events held so far');
    });

    test('cancelled events and events outside the range are left out', () {
      final cancelled = event('x', DateTime.utc(2026, 10, 20), status: EventStatus.cancelled);
      final outside = event('y', DateTime.utc(2026, 11, 2));
      final r = run(ReportData(events: [e1, cancelled, outside], workers: workers));
      expect(r.events.map((e) => e.event.id), ['e1']);
    });
  });

  group('time to fill', () {
    AssignmentChange ch(String action, DateTime at, {String w = 'a'}) =>
        AssignmentChange(id: '$action$at', eventId: 'e1', shiftId: 's1', action: action, changedAt: at, workerId: w);

    test('from creation to the first assignment, and from a removal to the next', () {
      final created = ct(2026, 10, 1, 9);
      final list = [
        ch('assigned', created.add(const Duration(hours: 5))),
        ch('unassigned', ct(2026, 10, 13, 10)),
        ch('assigned', ct(2026, 10, 13, 13), w: 'b'),
      ];
      expect(timeToFillMinutes(createdAt: created, changes: list), [300, 180]);
      expect(timeToFillMinutes(changes: list), [180], reason: 'no creation time: only the refill is measured');
      final r = run(ReportData(events: [e1], workers: workers, shifts: [shift('s1', e1, 'sf1', w: 'b')], changes: list, shiftCreatedAt: {'s1': created}));
      expect(r.total.fills, 2);
      expect(r.total.averageHoursToFill, 4.0);
    });
  });

  group('attendance', () {
    test('uses attendanceOutcomes and matches AttendanceSummary', () {
      final s1 = shift('s1', e1, 'sf1', w: 'a'), s2 = shift('s2', e1, 'sf1', w: 'b'), s3 = shift('s3', e1, 'sf1', w: 'c');
      final callOff = AssignmentChange(
        id: 'c1', eventId: 'e1', shiftId: 's3', action: 'unassigned', changedAt: e1.callTime.subtract(const Duration(hours: 20)),
        workerId: 'd', fromStorefrontId: 'sf1', fromJobRoleCode: 'cashier', reason: 'Called off sick');
      final punches = [...worked('a', e1, s1), ...worked('b', e1, s2, late: 20)];
      final data = ReportData(
        events: [e1],
        workers: {...workers, 'd': worker('d')},
        shifts: [s1, s2, s3],
        punches: punches,
        changes: [callOff],
      );
      final t = run(data).total;
      final summary = AttendanceSummary(attendanceOutcomes(
          shifts: data.shifts, punches: punches, changes: data.changes, rules: rules.attendance, now: DateTime.utc(2026, 11, 4)));
      expect((t.onTime, t.late, t.noShows, t.callOffs), (summary.onTime, summary.late, summary.noShows, summary.callOffs));
      expect((t.onTime, t.late, t.noShows, t.callOffs), (1, 1, 1, 1));
      expect(t.onTimeRate, summary.onTimeRate);
      expect(t.attendanceRate, summary.attendanceRate);
      expect(t.averageMinutesLate, 20);
    });

    test('no attendance to measure gives no rate', () {
      final t = run(ReportData(events: [e1], workers: workers, shifts: [shift('s1', e1, 'sf1')])).total;
      expect(t.expected, 0);
      expect(t.onTimeRate, isNull);
      expect(t.attendanceRate, isNull);
      expect(t.averageMinutesLate, isNull);
    });
  });

  group('hours and overtime', () {
    test('overtime across a week: earlier events before the range still count toward 40 hours', () {
      // Monday to Thursday, 10 hours each, then Friday's event (in range) for 6 hours.
      final events = [
        for (var d = 0; d < 4; d++) event('m$d', DateTime.utc(2026, 9, 28 + d)),
      ];
      final fri = event('f', DateTime.utc(2026, 10, 2));
      final shifts = [for (final e in [...events, fri]) shift('s${e.id}', e, 'sf1', w: 'a')];
      final punches = [
        for (var i = 0; i < 4; i++) ...worked('a', events[i], shifts[i], late: 0, hours: 10),
        ...worked('a', fri, shifts[4], late: 0, hours: 6),
      ];
      final r = run(
        ReportData(events: [...events, fri], workers: workers, shifts: shifts, punches: punches),
        from: DateTime.utc(2026, 10, 2),
        to: DateTime.utc(2026, 10, 31),
      );
      final t = r.event('f')!.total;
      expect(t.workedMinutes, 360);
      expect(t.overtimeMinutes, 360, reason: '40 hours were reached before Friday');
      expect(r.events.map((e) => e.event.id), ['f']);
      expect(r.total.overtimeShare, 1.0);
      expect(r.byWorkerType[WorkerType.regular]!.overtimeMinutes, 360);
    });

    test('no overtime under 40 hours; open clock-ins are not counted', () {
      final s1 = shift('s1', e1, 'sf1', w: 'a'), s2 = shift('s2', e1, 'sf1', w: 'b');
      final punches = [...worked('a', e1, s1, late: 0, hours: 6), punch('b', e1, s2, PunchKind.clockIn, e1.callTime)];
      final t = run(ReportData(events: [e1], workers: workers, shifts: [s1, s2], punches: punches)).total;
      expect(t.workedMinutes, 360);
      expect(t.overtimeMinutes, 0);
      expect(t.overtimeShare, 0);
    });
  });

  group('breaks', () {
    test('missed, short, and late breaks against the venue policy', () {
      final s = [for (final w in ['a', 'b', 'c']) shift('s$w', e1, 'sf1', w: w)];
      final inAt = e1.callTime;
      List<Punch> withBreak(String w, Shift sh, int startAfter, int length) => [
            punch(w, e1, sh, PunchKind.clockIn, inAt),
            punch(w, e1, sh, PunchKind.breakStart, inAt.add(Duration(minutes: startAfter)), breakKind: BreakKind.rest),
            punch(w, e1, sh, PunchKind.breakEnd, inAt.add(Duration(minutes: startAfter + length))),
            punch(w, e1, sh, PunchKind.clockOut, inAt.add(const Duration(minutes: 330))),
          ];
      final punches = [
        ...worked('a', e1, s[0], late: 0, hours: 5.5), // rest due at 4h: missed
        ...withBreak('b', s[1], 120, 5), // too short
        ...withBreak('c', s[2], 260, 12), // after it was due
      ];
      final t = run(ReportData(events: [e1], workers: workers, shifts: s, punches: punches)).total;
      expect(t.breaksDue, 3);
      expect(t.breaksMissed, 1);
      expect(t.breaksShort, 1);
      expect(t.breaksLate, 1);
      expect(t.breakComplianceRate, 0);
    });

    test('a short shift needs no break; still on the clock is not judged yet', () {
      final k = breakKpis(punches: worked('a', e1, shift('s', e1, 'sf1', w: 'a'), hours: 3), rules: rules, now: DateTime.utc(2026, 11, 4));
      expect(k!.breaksDue, 0);
      expect(k.breakComplianceRate, isNull);
      final open = breakKpis(punches: [punch('a', e1, null, PunchKind.clockIn, e1.callTime)], rules: rules, now: e1.callTime.add(const Duration(hours: 5)));
      expect(open, isNull);
    });
  });

  group('labor cost', () {
    final rate = PayRate(id: 'r', venueId: 'v', jobRoleCode: 'cashier', hourlyRateCents: 1500, effectiveFrom: DateTime.utc(2026, 1, 1));
    final s1 = shift('s1', e1, 'sf1', w: 'a');
    final data = ReportData(events: [e1], workers: workers, shifts: [s1], punches: worked('a', e1, s1, late: 0, hours: 6));

    ReportData withMoney({Map<String, int> event = const {}, Map<String, Map<String, int>> storefront = const {}}) => ReportData(
          events: data.events,
          workers: data.workers,
          shifts: data.shifts,
          punches: data.punches,
          money: ReportMoney(rates: [rate], eventBudgetsCents: event, storefrontBudgetsCents: storefront),
        );

    test('no view_pay: no money at all', () {
      final r = run(data);
      expect(r.hasMoney, isFalse);
      expect(r.total.laborCents, 0);
      expect(r.event('e1')!.cost, isNull);
    });

    test('cost from the pay engine; no budget means no budget status', () {
      final r = run(withMoney());
      expect(r.total.payrollCents, 9000, reason: '6 hours at \$15');
      expect(r.total.budgetVarianceCents, isNull);
      expect(const ReportTargets().budget(r.total.budgetedCostCents, r.total.budgets == 0 ? null : r.total.budgetCents), Rag.none);
      expect(r.total.costPerAttendeeCents, 2, reason: '\$90 over 5,000 actual attendees, rounded');
    });

    test('the event budget is used for the event total, storefront budgets for storefront rows', () {
      final r = run(withMoney(event: {'e1': 8000}, storefront: {'e1': {'sf1': 10000}}));
      final e = r.event('e1')!;
      expect(e.total.budgetCents, 8000);
      expect(e.total.budgetVarianceCents, -1000);
      expect(const ReportTargets().budget(e.total.budgetedCostCents, e.total.budgetCents), Rag.red, reason: '\$90 against \$80 is 12.5% over');
      expect(e.byStorefront['sf1']!.budgetVarianceCents, 1000);
      expect(const ReportTargets().budget(9000, 8500), Rag.yellow);
    });

    test('cost per attendee uses expected attendance when there is no actual', () {
      final e = event('e9', day, expected: 3000);
      final s = shift('s9', e, 'sf1', w: 'a');
      final r = run(ReportData(events: [e], workers: workers, shifts: [s], punches: worked('a', e, s, late: 0, hours: 6), money: ReportMoney(rates: [rate])));
      expect(r.total.attendees, 3000);
      expect(r.total.costPerAttendeeCents, 3);
    });
  });

  group('tips', () {
    test('per person and per hour from saved splits', () {
      final s1 = shift('s1', e1, 'bar', w: 'a', role: 'bartender');
      const pool = TipPool(id: 'tp', venueId: 'v', eventId: 'e1', storefrontId: 'bar', amountCents: 12000);
      final r = run(ReportData(
        events: [e1],
        workers: workers,
        shifts: [s1],
        punches: worked('a', e1, s1, late: 0, hours: 6),
        money: const ReportMoney(tipPools: [pool], tipAllocations: [TipAllocation(poolId: 'tp', venueId: 'v', workerId: 'a', amountCents: 12000, hoursHundredths: 600)]),
      ));
      expect(r.tips.single.cents, 12000);
      expect(r.tips.single.centsPerHour, 2000);
      expect(r.tipPoolsEstimated, 0);
      expect(r.total.tipsCents, 12000);
      expect(r.total.laborCents, 0, reason: 'tips are not labor cost');
    });

    test('no hours gives no per-hour figure', () {
      expect(const WorkerTips(workerId: 'a', cents: 500, hoursHundredths: 0, events: 1).centsPerHour, isNull);
    });
  });

  test('previous events and same-type events for comparisons', () {
    final evs = [for (var i = 1; i <= 7; i++) event('e$i', DateTime.utc(2026, 10, i * 3), type: i.isEven ? 'concert' : 'hockey')];
    final r = run(ReportData(events: evs, workers: workers));
    expect(previousEvents(r, evs[6]).map((e) => e.event.id), ['e6', 'e5', 'e4', 'e3', 'e2']);
    expect(previousEvents(r, evs[0]), isEmpty);
    expect(eventsOfType(r, 'concert').map((e) => e.event.id), ['e2', 'e4', 'e6']);
  });

  test('KpiTotals add up and rates come from counts', () {
    const a = KpiTotals(planned: 10, staffed: 9, onTime: 8, late: 1, noShows: 1, workedMinutes: 600, overtimeMinutes: 60);
    const b = KpiTotals(planned: 10, staffed: 10, onTime: 10);
    final s = KpiTotals.sum([a, b]);
    expect(s.fillRate, 19 / 20);
    expect(s.onTimeRate, 18 / 20);
    expect(s.attendanceRate, 19 / 20);
    expect(s.overtimeShare, 0.1);
    expect(KpiTotals.zero.onTimeRate, isNull);
    expect(KpiTotals.zero.costPerAttendeeCents, isNull);
  });
}
