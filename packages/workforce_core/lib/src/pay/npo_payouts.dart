/// What a non-profit group earns for working an event (npo_payouts).
///
/// Per event per group:
///   members_scheduled - distinct group members with an assigned or released shift at
///                       the event (released people still count as scheduled).
///   members_worked    - distinct group members with any paid minutes at the event
///                       (including a member who worked without a shift).
///   no_shows          - scheduled members with an assigned (not released) shift who
///                       never clocked in. Released-before-arrival is not a no-show.
///   hours             - all members' paid minutes, shown to 2 decimals.
///   hourly_rate       - the group's own agreement active on the event's local date,
///                       else the venue default (npo_group_id null).
///   gross             - total minutes x rate, rounded half-up once (not per member).
///   deductions        - see [npoDeductionsCents]: no double penalty.
///   total             - max(0, gross - deductions + adjustment).
library;

import '../model/entities.dart';
import '../model/enums.dart';
import '../rules/local_time.dart';
import '../rules/venue_rules.dart';
import 'money.dart';
import 'pay_models.dart';
import 'pay_problem.dart';
import 'rates.dart';
import 'work_time.dart';

/// Deductions with no double penalty.
///
/// shortfall = max(0, min_headcount - members_worked) people; each no-show is also a
/// missing person. The first min(shortfall, no_shows) missing people are both a
/// shortfall and a no-show: each of them is charged once, at the larger of the two
/// deductions. Remaining shortfall people are charged the shortfall deduction and
/// remaining no-shows the no-show deduction.
int npoDeductionsCents({
  required int shortfall,
  required int noShows,
  required int shortfallDeductionCents,
  required int noShowDeductionCents,
}) {
  final both = shortfall < noShows ? shortfall : noShows;
  final larger = shortfallDeductionCents > noShowDeductionCents ? shortfallDeductionCents : noShowDeductionCents;
  return both * larger + (shortfall - both) * shortfallDeductionCents + (noShows - both) * noShowDeductionCents;
}

class NpoPayoutResult {
  const NpoPayoutResult({
    required this.payout,
    required this.agreement,
    required this.shortfall,
    required this.problems,
  });

  final NpoPayout payout;
  final NpoAgreement? agreement;

  /// Members short of the agreement's minimum headcount.
  final int shortfall;
  final List<PayProblem> problems;
}

/// Calculates one group's payout for one event. [members] may include other people;
/// only workers whose npoGroupId is [npoGroupId] are used. [shifts] are the event's
/// shifts; [punchesByWorker] each member's punches (any status).
NpoPayoutResult calculateNpoPayout({
  required Event event,
  required String npoGroupId,
  required List<Worker> members,
  required List<Shift> shifts,
  required Map<String, List<Punch>> punchesByWorker,
  required List<NpoAgreement> agreements,
  required String timeZone,
  BreakRules breakRules = const BreakRules(),
  int adjustmentCents = 0,
  String adjustmentReason = '',
}) {
  if (adjustmentCents != 0 && adjustmentReason.trim().isEmpty) {
    throw ArgumentError.value(adjustmentReason, 'adjustmentReason', 'is required with an adjustment');
  }
  final problems = <PayProblem>[];
  final group = [
    for (final m in members)
      if (m.npoGroupId == npoGroupId) m,
  ];
  final eventShifts = [
    for (final s in shifts)
      if (s.eventId == event.id) s,
  ];

  final date = localDateOf(event.startTime, timeZone);
  final agreement = resolveNpoAgreement(npoGroupId: npoGroupId, date: date, agreements: agreements);
  if (agreement == null) {
    problems.add(PayProblem(
      kind: PayProblemKind.missingNpoAgreement,
      severity: PayProblemSeverity.blocking,
      message: 'No NPO agreement (group or venue default) on ${formatDate(date)}.',
      eventId: event.id,
      workDate: date,
    ));
  }

  var scheduled = 0, worked = 0, noShows = 0, totalMinutes = 0;
  final detail = <NpoPayoutMember>[];
  for (final m in group) {
    final mine = [
      for (final s in eventShifts)
        if (s.workerId == m.id) s,
    ];
    final shiftIds = {for (final s in mine) s.id};
    final punches = [
      for (final p in punchesByWorker[m.id] ?? const <Punch>[])
        if (p.eventId == event.id || (p.shiftId != null && shiftIds.contains(p.shiftId))) p,
    ];
    final work = attributeWork(
      workerId: m.id,
      punches: punches,
      shifts: mine,
      events: {event.id: event},
      timeZone: timeZone,
      breakRules: breakRules,
    );
    problems.addAll(work.problems.where((p) => p.kind != PayProblemKind.noJobRole));
    final minutes = work.totalMinutes;
    final clockedIn = work.groups.any((g) => g.clockedIn);
    final isScheduled = mine.any((s) => s.status == ShiftStatus.assigned || s.status == ShiftStatus.released);
    final hasAssigned = mine.any((s) => s.status == ShiftStatus.assigned);

    String status;
    if (minutes > 0) {
      status = 'worked';
    } else if (clockedIn) {
      status = 'open_punch';
    } else if (hasAssigned) {
      status = 'no_show';
    } else if (isScheduled) {
      status = 'released';
    } else {
      continue; // Not scheduled and did not work: not part of this event.
    }
    if (isScheduled) scheduled++;
    if (minutes > 0) worked++;
    if (status == 'no_show') noShows++;
    totalMinutes += minutes;
    detail.add(NpoPayoutMember(workerId: m.id, name: '${m.firstName} ${m.lastName}', minutes: minutes, status: status));
  }
  detail.sort((a, b) {
    final c = a.name.compareTo(b.name);
    return c != 0 ? c : a.workerId.compareTo(b.workerId);
  });

  final rate = agreement?.hourlyRateCents ?? 0;
  final gross = amountForMinutes(totalMinutes, rate);
  final minHeadcount = agreement?.minHeadcount ?? 0;
  final shortfall = minHeadcount > worked ? minHeadcount - worked : 0;
  final deductions = npoDeductionsCents(
    shortfall: shortfall,
    noShows: noShows,
    shortfallDeductionCents: agreement?.shortfallDeductionCents ?? 0,
    noShowDeductionCents: agreement?.noShowDeductionCents ?? 0,
  );
  final net = gross - deductions + adjustmentCents;

  return NpoPayoutResult(
    payout: NpoPayout(
      venueId: event.venueId,
      eventId: event.id,
      npoGroupId: npoGroupId,
      membersScheduled: scheduled,
      membersWorked: worked,
      noShows: noShows,
      hoursHundredths: minutesToHundredths(totalMinutes),
      hourlyRateCents: rate,
      grossCents: gross,
      deductionsCents: deductions,
      adjustmentCents: adjustmentCents,
      adjustmentReason: adjustmentReason.trim(),
      totalCents: net > 0 ? net : 0,
      detail: List.unmodifiable(detail),
      minutes: totalMinutes,
    ),
    agreement: agreement,
    shortfall: shortfall,
    problems: List.unmodifiable(problems),
  );
}

class NpoStatusTotal {
  const NpoStatusTotal({required this.count, required this.totalCents});

  final int count;
  final int totalCents;
}

/// A group's season: every payout added up, with a breakdown by status.
class NpoSeasonStatement {
  const NpoSeasonStatement({
    required this.npoGroupId,
    required this.payouts,
    required this.hoursHundredths,
    required this.grossCents,
    required this.deductionsCents,
    required this.adjustmentCents,
    required this.totalCents,
    required this.byStatus,
  });

  final String npoGroupId;
  final List<NpoPayout> payouts;
  final int hoursHundredths;
  final int grossCents;
  final int deductionsCents;
  final int adjustmentCents;
  final int totalCents;

  /// pending / approved / paid -> count and total.
  final Map<String, NpoStatusTotal> byStatus;

  int get events => payouts.length;
  int get paidCents => byStatus['paid']?.totalCents ?? 0;

  /// Approved or pending, not yet paid.
  int get outstandingCents => totalCents - paidCents;
}

/// Adds up [payouts] for [npoGroupId] (others are ignored).
NpoSeasonStatement npoSeasonStatement(String npoGroupId, Iterable<NpoPayout> payouts) {
  final mine = [
    for (final p in payouts)
      if (p.npoGroupId == npoGroupId) p,
  ];
  int sum(int Function(NpoPayout) f) => mine.fold(0, (s, p) => s + f(p));
  final byStatus = <String, NpoStatusTotal>{};
  for (final p in mine) {
    final prev = byStatus[p.status];
    byStatus[p.status] =
        NpoStatusTotal(count: (prev?.count ?? 0) + 1, totalCents: (prev?.totalCents ?? 0) + p.totalCents);
  }
  return NpoSeasonStatement(
    npoGroupId: npoGroupId,
    payouts: List.unmodifiable(mine),
    hoursHundredths: sum((p) => p.hoursHundredths),
    grossCents: sum((p) => p.grossCents),
    deductionsCents: sum((p) => p.deductionsCents),
    adjustmentCents: sum((p) => p.adjustmentCents),
    totalCents: sum((p) => p.totalCents),
    byStatus: Map.unmodifiable(byStatus),
  );
}
