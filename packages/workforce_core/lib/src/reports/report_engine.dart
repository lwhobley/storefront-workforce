/// Workforce KPIs for a date range, by event, by storefront, by worker type and NPO
/// group. Built on the shared engines so every screen counts the same way:
///
/// - **Headcount**: per storefront and role, planned = the event's staffing need (or the
///   positions on the schedule when no need is set); staffed = positions with someone
///   assigned or sent home, capped at the plan. Only open storefronts count.
/// - **Time to fill**: from when a position opened (created, or someone was removed) to
///   the next assignment, from `assignment_changes`.
/// - **Attendance**: [attendanceOutcomes] (on time, late, no-show, call-off), the same
///   definitions as the reliability score.
/// - **Hours and overtime**: [attributeWork] and [markOvertime] (the pay engine's paid
///   minutes; overtime is the last minutes of the workweek past the threshold). Punches
///   from the week before the range are loaded so a week that starts before the range
///   is counted right. Hours of a clock-in still open are not counted until clock-out.
/// - **Breaks**: [evaluateBreaks] for each person and finished event: rules that came
///   due, and those missed, taken late, or too short.
/// - **Labor cost** (pay viewers only): [calculateEarnings], [calculateAgencyBilling],
///   NPO payouts (stored, else estimated with [calculateNpoPayout]) and
///   [calculateLaborCost], against `events.labor_budget` (event totals and the season)
///   and `event_storefronts.labor_budget` (storefront rows).
/// - **Tips** (pay viewers only): saved splits, else the split the Pay screen would make.
///
/// Upcoming events (not started yet) count for headcount only, in [ReportResult.upcoming].
library;

import '../model/entities.dart';
import '../model/enums.dart';
import '../pay/agency_billing.dart';
import '../pay/earnings.dart';
import '../pay/labor_cost.dart';
import '../pay/npo_payouts.dart';
import '../pay/pay_models.dart';
import '../pay/tip_pools.dart';
import '../pay/work_time.dart';
import '../rules/attendance_outcomes.dart';
import '../rules/breaks.dart';
import '../rules/local_time.dart';
import '../rules/overtime.dart';
import '../rules/timeline.dart';
import '../rules/venue_rules.dart';
import 'kpi_totals.dart';
import 'report_data.dart';

class EventReport {
  const EventReport({
    required this.event,
    required this.total,
    required this.byStorefront,
    required this.upcoming,
    this.cost,
    this.eventBudgetCents,
  });

  final Event event;
  final KpiTotals total;

  /// Null key: costs with no storefront (an NPO payout with no hours, for example).
  final Map<String?, KpiTotals> byStorefront;

  /// Not started yet: headcount only.
  final bool upcoming;
  final LaborCostReport? cost;
  final int? eventBudgetCents;
}

class WorkerTips {
  const WorkerTips({required this.workerId, required this.cents, required this.hoursHundredths, required this.events});

  final String workerId;
  final int cents;
  final int hoursHundredths;
  final int events;

  /// Cents per hour; null with no hours.
  int? get centsPerHour => hoursHundredths == 0 ? null : (cents * 100 * 2 + hoursHundredths) ~/ (hoursHundredths * 2);
}

class NpoGroupReport {
  const NpoGroupReport({
    required this.groupId,
    required this.totals,
    this.totalCents = 0,
    this.paidCents = 0,
    this.payouts = 0,
    this.estimated = 0,
  });

  final String groupId;

  /// Hours and attendance of the group's members.
  final KpiTotals totals;

  /// Payout totals (stored or estimated), and how much of it is paid.
  final int totalCents;
  final int paidCents;
  final int payouts;

  /// Payouts not created yet, estimated from time records.
  final int estimated;

  int get owedCents => totalCents - paidCents;
}

class ReportResult {
  const ReportResult({
    required this.from,
    required this.to,
    required this.events,
    required this.byWorkerType,
    required this.npoGroups,
    required this.hasMoney,
    this.tips = const [],
    this.tipPoolsEstimated = 0,
    this.npoPayoutsEstimated = 0,
  });

  /// Local dates, inclusive.
  final DateTime from;
  final DateTime to;

  /// Every event in the range (cancelled ones left out), by start time.
  final List<EventReport> events;
  final Map<WorkerType, KpiTotals> byWorkerType;
  final List<NpoGroupReport> npoGroups;
  final bool hasMoney;

  /// Most tips first.
  final List<WorkerTips> tips;
  final int tipPoolsEstimated;
  final int npoPayoutsEstimated;

  /// Events that have started or finished.
  List<EventReport> get held => [for (final e in events) if (!e.upcoming) e];
  List<EventReport> get upcomingEvents => [for (final e in events) if (e.upcoming) e];

  /// Everything about the events held so far.
  KpiTotals get total => KpiTotals.sum(held.map((e) => e.total));

  /// Headcount of upcoming events.
  KpiTotals get upcoming => KpiTotals.sum(upcomingEvents.map((e) => e.total));

  /// Held events, added up by storefront. The null key holds costs with no storefront.
  Map<String?, KpiTotals> get byStorefront {
    final out = <String?, KpiTotals>{};
    for (final e in held) {
      e.byStorefront.forEach((k, v) => out[k] = (out[k] ?? KpiTotals.zero) + v);
    }
    return out;
  }

  EventReport? event(String id) => events.where((e) => e.event.id == id).firstOrNull;
}

/// Up to [count] events held before [event] in [report], newest first.
List<EventReport> previousEvents(ReportResult report, Event event, {int count = 5}) {
  final before = [
    for (final e in report.held)
      if (e.event.id != event.id && e.event.startTime.isBefore(event.startTime)) e,
  ]..sort((a, b) => b.event.startTime.compareTo(a.event.startTime));
  return before.take(count).toList();
}

/// Events of one type in [report] (for "same event type last season").
List<EventReport> eventsOfType(ReportResult report, String eventTypeCode) =>
    [for (final e in report.held) if (e.event.eventTypeCode == eventTypeCode) e];

Map<String, List<Punch>> _byWorker(Iterable<Punch> punches) {
  final out = <String, List<Punch>>{};
  for (final p in punches) {
    out.putIfAbsent(p.workerId, () => []).add(p);
  }
  return out;
}

bool _holds(Shift s) => s.workerId != null && (s.status == ShiftStatus.assigned || s.status == ShiftStatus.released);

/// Builds the report for events whose local start date is [from] to [to] (inclusive).
ReportResult buildReport({
  required ReportData data,
  required VenueRules rules,
  required String timeZone,
  required DateTime from,
  required DateTime to,
  required DateTime now,
  List<JobRole> jobRoles = const [],
}) {
  final tz = timeZone;
  final eventsById = {for (final e in data.events) e.id: e};
  final scope = [
    for (final e in data.events)
      if (e.status != EventStatus.cancelled && _inRange(localDateOf(e.startTime, tz), from, to)) e,
  ]..sort((a, b) => a.startTime.compareTo(b.startTime));
  final scopeIds = {for (final e in scope) e.id};
  bool upcoming(Event e) => e.status == EventStatus.scheduled && e.callTime.isAfter(now);
  final heldIds = {for (final e in scope) if (!upcoming(e)) e.id};

  final cells = <String, Map<String?, KpiTotals>>{for (final e in scope) e.id: {}};
  void add(String eventId, String? storefrontId, KpiTotals t) {
    final m = cells[eventId];
    if (m == null) return;
    m[storefrontId] = (m[storefrontId] ?? KpiTotals.zero) + t;
  }

  final byType = <WorkerType, KpiTotals>{};
  void addType(WorkerType t, KpiTotals k) => byType[t] = (byType[t] ?? KpiTotals.zero) + k;
  final byGroup = <String, KpiTotals>{};
  void addPerson(String? workerId, KpiTotals k) {
    final w = data.workers[workerId];
    if (w == null) return;
    addType(w.type, k);
    final g = w.npoGroupId;
    if (g != null) byGroup[g] = (byGroup[g] ?? KpiTotals.zero) + k;
  }

  final scopeShifts = [for (final s in data.shifts) if (scopeIds.contains(s.eventId)) s];

  // ---- Headcount ----
  for (final e in scope) {
    final rows = [for (final es in data.eventStorefronts) if (es.eventId == e.id) es];
    final evShifts = [for (final s in scopeShifts) if (s.eventId == e.id && s.status != ShiftStatus.cancelled) s];
    final open = rows.isEmpty
        ? {
            for (final n in data.needs) if (n.eventId == e.id) n.storefrontId,
            for (final s in evShifts) s.storefrontId,
          }
        : {for (final r in rows) if (r.isOpen) r.storefrontId};
    final need = <(String, String), int>{};
    for (final n in data.needs) {
      if (n.eventId == e.id && open.contains(n.storefrontId)) need[(n.storefrontId, n.jobRoleCode)] = n.count;
    }
    final positions = <(String, String), int>{};
    final filled = <(String, String), int>{};
    for (final s in evShifts) {
      if (!open.contains(s.storefrontId)) continue;
      final k = (s.storefrontId, s.jobRoleCode);
      positions[k] = (positions[k] ?? 0) + 1;
      if (_holds(s)) filled[k] = (filled[k] ?? 0) + 1;
    }
    for (final k in {...need.keys, ...positions.keys}) {
      final planned = need[k] ?? positions[k] ?? 0;
      final staffed = (filled[k] ?? 0).clamp(0, planned);
      add(e.id, k.$1, KpiTotals(planned: planned, staffed: staffed));
    }
  }

  // ---- Time to fill ----
  final changesByShift = <String, List<AssignmentChange>>{};
  for (final c in data.changes) {
    if (scopeIds.contains(c.eventId)) changesByShift.putIfAbsent(c.shiftId, () => []).add(c);
  }
  for (final s in scopeShifts) {
    final list = changesByShift[s.id];
    if (list == null) continue;
    list.sort((a, b) => a.changedAt.compareTo(b.changedAt));
    final fill = timeToFillMinutes(createdAt: data.shiftCreatedAt[s.id], changes: list);
    for (final m in fill) {
      add(s.eventId, s.storefrontId, KpiTotals(fills: 1, fillMinutes: m));
    }
  }

  // ---- Attendance ----
  final scopePunches = [for (final p in data.punches) if (p.eventId != null && scopeIds.contains(p.eventId)) p];
  final outcomes = attendanceOutcomes(
    shifts: scopeShifts,
    punches: scopePunches,
    changes: [for (final c in data.changes) if (scopeIds.contains(c.eventId)) c],
    rules: rules.attendance,
    now: now,
  );
  for (final o in outcomes) {
    if (!heldIds.contains(o.eventId)) continue;
    final k = switch (o.outcome) {
      AttendanceOutcome.onTime => const KpiTotals(onTime: 1),
      AttendanceOutcome.late => KpiTotals(late: 1, minutesLate: o.minutesLate),
      AttendanceOutcome.noShow => const KpiTotals(noShows: 1),
      AttendanceOutcome.callOff => const KpiTotals(callOffs: 1),
      _ => null,
    };
    if (k == null) continue;
    add(o.eventId, o.storefrontId, k);
    addPerson(o.workerId, k);
  }

  // ---- Hours and overtime ----
  final punchesByWorker = _byWorker(data.punches);
  final shiftsByWorker = <String, List<Shift>>{};
  for (final s in data.shifts) {
    if (s.workerId != null) shiftsByWorker.putIfAbsent(s.workerId!, () => []).add(s);
  }
  for (final entry in punchesByWorker.entries) {
    final w = data.workers[entry.key];
    final work = attributeWork(
      workerId: entry.key,
      punches: entry.value,
      shifts: shiftsByWorker[entry.key] ?? const [],
      events: eventsById,
      timeZone: tz,
      breakRules: rules.breaks,
      defaultJobRoleCode: w == null || w.jobRoles.isEmpty ? null : w.jobRoles.first,
    );
    for (final week in markOvertime(work.pieces, timeZone: tz, rules: rules.overtime)) {
      for (final p in week.pieces) {
        final ev = p.context.eventId;
        if (ev == null || !heldIds.contains(ev)) continue;
        final k = KpiTotals(workedMinutes: p.minutes, overtimeMinutes: p.overtime ? p.minutes : 0);
        add(ev, p.context.storefrontId, k);
        addPerson(entry.key, k);
      }
    }
  }

  // ---- Breaks ----
  final eventPunchesByWorker = <String, Map<String, List<Punch>>>{};
  for (final p in scopePunches) {
    eventPunchesByWorker.putIfAbsent(p.eventId!, () => {}).putIfAbsent(p.workerId, () => []).add(p);
  }
  for (final e in scope) {
    if (!heldIds.contains(e.id)) continue;
    final day = localDateOf(e.callTime, tz);
    (eventPunchesByWorker[e.id] ?? const {}).forEach((workerId, ps) {
      final k = breakKpis(punches: ps, rules: rules, age: data.workers[workerId]?.ageOn(day), now: now);
      if (k == null) return;
      final shift = scopeShifts.where((s) => s.eventId == e.id && s.workerId == workerId && _holds(s)).firstOrNull;
      add(e.id, shift?.storefrontId, k);
      addPerson(workerId, k);
    });
  }

  // ---- Money ----
  final money = data.money;
  final costs = <String, LaborCostReport>{};
  final groupPay = <String, (int total, int paid, int payouts, int estimated)>{};
  var npoEstimated = 0;
  var poolsEstimated = 0;
  final tips = <String, (int cents, int hundredths, Set<String> events)>{};
  if (money != null) {
    final jobRoleMap = {for (final r in jobRoles) r.code: r};
    final inputs = [
      for (final w in data.workers.values)
        if (punchesByWorker.containsKey(w.id) || shiftsByWorker.containsKey(w.id))
          WorkerPayInput(worker: w, punches: punchesByWorker[w.id] ?? const [], shifts: shiftsByWorker[w.id] ?? const []),
    ];

    // Tips: saved splits, else the split the Pay screen would make.
    final pools = [for (final t in money.tipPools) if (heldIds.contains(t.eventId)) t];
    final allocations = <TipAllocation>[];
    for (final pool in pools) {
      final saved = [for (final a in money.tipAllocations) if (a.poolId == pool.id) a];
      if (saved.isNotEmpty) {
        allocations.addAll(saved);
        continue;
      }
      if (pool.amountCents == 0) continue;
      poolsEstimated++;
      final participants = tipParticipantsFromShifts(
        pool: pool,
        workers: data.workers,
        shifts: [for (final s in scopeShifts) if (s.eventId == pool.eventId) s],
        punchesByWorker: (eventPunchesByWorker[pool.eventId] ?? const {}),
        timeZone: tz,
        breakRules: rules.breaks,
      );
      allocations.addAll(allocateTipPool(pool: pool, participants: participants, payRules: money.payRules).allocations);
    }
    final poolById = {for (final p in pools) p.id: p};
    for (final a in allocations) {
      final pool = poolById[a.poolId];
      if (pool == null) continue;
      add(pool.eventId, pool.storefrontId, KpiTotals(tipsCents: a.amountCents));
      addPerson(a.workerId, KpiTotals(tipsCents: a.amountCents));
      final t = tips[a.workerId] ?? (0, 0, <String>{});
      tips[a.workerId] = (t.$1 + a.amountCents, t.$2 + a.hoursHundredths, t.$3..add(pool.eventId));
    }

    // Payroll for whole workweeks around the range; lines carry their event.
    final ot = rules.overtime;
    final firstWeek = localDateOf(workweekStart(startOfLocalDay(from, tz), tz, ot.workweekStartDay), tz);
    final lastWeek = localDateOf(workweekStart(startOfLocalDay(to, tz), tz, ot.workweekStartDay), tz);
    final period = PayPeriod(startsOn: firstWeek, endsOn: addCalendarDays(lastWeek, 6), payDate: addCalendarDays(lastWeek, 6));
    final earnings = calculateEarnings(
      timeZone: tz,
      venueRules: rules,
      payRules: money.payRules,
      period: period,
      workers: inputs,
      events: eventsById,
      rates: money.rates,
      differentials: money.differentials,
      tipPools: pools,
      tipAllocations: allocations,
      jobRoles: jobRoleMap,
    );
    final agency = calculateAgencyBilling(
      timeZone: tz,
      overtimeRules: ot,
      from: firstWeek,
      to: addCalendarDays(lastWeek, 6),
      temps: [for (final i in inputs) if (i.worker.type == WorkerType.temp) i],
      events: eventsById,
      billRates: money.billRates,
      breakRules: rules.breaks,
    );
    final linesByEvent = <String, List<PayLine>>{};
    for (final l in earnings.lines) {
      if (l.eventId != null) linesByEvent.putIfAbsent(l.eventId!, () => []).add(l);
    }
    final agencyByEvent = <String, List<AgencyInvoiceLine>>{};
    for (final l in agency.lines) {
      if (l.eventId != null) agencyByEvent.putIfAbsent(l.eventId!, () => []).add(l);
    }
    final npoMembers = [for (final w in data.workers.values) if (w.type == WorkerType.npo && w.npoGroupId != null) w];
    final storedPayouts = {for (final p in money.npoPayouts) '${p.eventId}|${p.npoGroupId}': p};

    for (final e in scope) {
      if (!heldIds.contains(e.id)) continue;
      final evShifts = [for (final s in scopeShifts) if (s.eventId == e.id) s];
      final evPunches = eventPunchesByWorker[e.id] ?? const <String, List<Punch>>{};
      final groups = {
        for (final s in evShifts)
          if (_holds(s)) ?data.workers[s.workerId]?.npoGroupId,
        for (final p in money.npoPayouts) if (p.eventId == e.id) p.npoGroupId,
      };
      final payouts = <NpoPayout>[];
      for (final g in groups) {
        var payout = storedPayouts['${e.id}|$g'];
        var estimated = false;
        if (payout == null) {
          payout = calculateNpoPayout(
            event: e,
            npoGroupId: g,
            members: npoMembers,
            shifts: evShifts,
            punchesByWorker: evPunches,
            agreements: money.npoAgreements,
            timeZone: tz,
            breakRules: rules.breaks,
          ).payout;
          estimated = true;
          npoEstimated++;
        }
        payouts.add(payout);
        final prev = groupPay[g] ?? (0, 0, 0, 0);
        groupPay[g] = (
          prev.$1 + payout.totalCents,
          prev.$2 + (payout.status == 'paid' ? payout.totalCents : 0),
          prev.$3 + 1,
          prev.$4 + (estimated ? 1 : 0),
        );
      }
      final report = calculateLaborCost(
        event: e,
        payRules: money.payRules,
        payLines: linesByEvent[e.id] ?? const [],
        agencyLines: agencyByEvent[e.id] ?? const [],
        npoPayouts: payouts,
        npoMinutes: npoMinutesByStorefront(
          event: e,
          members: npoMembers,
          shifts: evShifts,
          punchesByWorker: evPunches,
          timeZone: tz,
          breakRules: rules.breaks,
        ),
        payCodes: money.payCodes,
        eventBudgetCents: money.eventBudgetsCents[e.id],
        storefrontBudgetsCents: money.storefrontBudgetsCents[e.id] ?? const {},
      );
      costs[e.id] = report;
      for (final r in report.storefronts) {
        final budget = r.budgetCents;
        add(
          e.id,
          r.storefrontId,
          KpiTotals(
            payrollCents: r.payrollCents,
            burdenCents: r.burdenCents,
            tempCents: r.tempCents,
            npoCents: r.npoCents,
            budgetCents: budget ?? 0,
            budgetedCostCents: budget == null ? 0 : r.totalCents,
            budgets: budget == null ? 0 : 1,
          ),
        );
      }
      final t = report.total;
      addType(WorkerType.regular, KpiTotals(payrollCents: t.payrollCents, burdenCents: t.burdenCents));
      addType(WorkerType.temp, KpiTotals(tempCents: t.tempCents));
      addType(WorkerType.npo, KpiTotals(npoCents: t.npoCents));
    }
    for (final p in money.npoPayouts) {
      // Groups paid for events in range whose members are no longer in the data.
      if (heldIds.contains(p.eventId)) groupPay.putIfAbsent(p.npoGroupId, () => (0, 0, 0, 0));
    }
  }

  final reports = <EventReport>[];
  for (final e in scope) {
    final m = cells[e.id]!;
    var total = KpiTotals.sum(m.values) + KpiTotals(events: 1, attendees: e.actualAttendance ?? e.expectedAttendance);
    final eventBudget = money?.eventBudgetsCents[e.id];
    if (money != null && !upcoming(e)) {
      // The event's own budget, when set, replaces the storefront budgets in its total.
      if (eventBudget != null) {
        total = KpiTotals.sum([
          total,
          KpiTotals(
            budgetCents: eventBudget - total.budgetCents,
            budgetedCostCents: total.laborCents - total.budgetedCostCents,
            budgets: 1 - total.budgets,
          ),
        ]);
      }
    }
    reports.add(EventReport(
      event: e,
      total: total,
      byStorefront: Map.unmodifiable(m),
      upcoming: upcoming(e),
      cost: costs[e.id],
      eventBudgetCents: eventBudget,
    ));
  }

  final groupIds = {...byGroup.keys, ...groupPay.keys}.toList()..sort();
  return ReportResult(
    from: from,
    to: to,
    events: List.unmodifiable(reports),
    byWorkerType: Map.unmodifiable(byType),
    npoGroups: [
      for (final g in groupIds)
        NpoGroupReport(
          groupId: g,
          totals: byGroup[g] ?? KpiTotals.zero,
          totalCents: groupPay[g]?.$1 ?? 0,
          paidCents: groupPay[g]?.$2 ?? 0,
          payouts: groupPay[g]?.$3 ?? 0,
          estimated: groupPay[g]?.$4 ?? 0,
        ),
    ],
    hasMoney: money != null,
    tips: [
      for (final e in tips.entries) WorkerTips(workerId: e.key, cents: e.value.$1, hoursHundredths: e.value.$2, events: e.value.$3.length),
    ]..sort((a, b) {
        final c = b.cents.compareTo(a.cents);
        return c != 0 ? c : a.workerId.compareTo(b.workerId);
      }),
    tipPoolsEstimated: poolsEstimated,
    npoPayoutsEstimated: npoEstimated,
  );
}

bool _inRange(DateTime d, DateTime from, DateTime to) => !d.isBefore(from) && !d.isAfter(to);

/// Minutes each fill of one position took: from when it opened (created at
/// [createdAt], or the last time someone was removed) to the next assignment.
/// [changes] are the position's changes, oldest first. A first assignment with no
/// known creation time is not measured.
List<int> timeToFillMinutes({DateTime? createdAt, required List<AssignmentChange> changes}) {
  final out = <int>[];
  var openedAt = createdAt;
  for (final c in changes) {
    switch (c.action) {
      case 'assigned':
        if (openedAt != null) {
          final m = c.changedAt.difference(openedAt).inMinutes;
          out.add(m < 0 ? 0 : m);
        }
        openedAt = null;
      case 'unassigned':
        openedAt = c.changedAt;
      default:
        break;
    }
  }
  return out;
}

/// Break results for one person at one finished event; null while they are still on
/// the clock (or never clocked in).
KpiTotals? breakKpis({required List<Punch> punches, required VenueRules rules, int? age, required DateTime now}) {
  final tl = WorkTimeline.fromPunches(punches, now: now);
  if (tl.firstClockIn == null || tl.state != TimelineState.clockedOut) return null;
  final eval = evaluateBreaks(timeline: tl, rules: rules.breaks, age: age, adultAge: rules.minors.adultAge, now: now);
  var due = 0, missed = 0, late = 0, short = 0;
  for (final s in eval.statuses) {
    switch (s.status) {
      case BreakStatus.taken:
        due++;
      case BreakStatus.takenLate:
        due++;
        late++;
      case BreakStatus.short:
        due++;
        short++;
      case BreakStatus.missed:
        due++;
        missed++;
      default:
        break;
    }
  }
  return KpiTotals(breaksDue: due, breaksMissed: missed, breaksLate: late, breaksShort: short);
}
