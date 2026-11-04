/// Payroll earnings for a pay period: REG, OT, differential, BONUS, TIPS and TIPMU
/// lines in the shape of `pay_period_lines`, ready for the Paycom entry sheet.
///
/// Who: only regular workers produce lines. Temps (agency billing) and NPO members
/// (NPO payouts) are listed in [EarningsResult.excludedWorkerIds].
///
/// Hours worked: paid minutes from [WorkTimeline.paidIntervals] (work plus paid short
/// breaks; unpaid meals excluded), attributed to shifts and split at local midnight
/// by [attributeWork]. work_date is the venue-local date the minutes happened.
///
/// Workweeks follow [OvertimeRules.workweekStartDay] at local midnight. Overtime is
/// computed per workweek with [overtimeForWeek] (weekly threshold, plus the daily
/// threshold when configured). Every workweek that overlaps the period is calculated
/// in full from the punches given, and only lines dated inside the period are
/// returned; so a workweek that straddles two periods (which should not happen with
/// periods aligned to workweeks, and is reported) is paid correctly across the two
/// runs as long as both see the same punches.
///
/// FLSA regular rate, per workweek (29 CFR 778.109, 778.115):
///   regular rate = (straight-time pay for all hours at each hour's own rate
///                  + per-hour differentials + per-shift amounts) / total hours.
///   All differentials and per-shift amounts here come from fixed rules, so they are
///   non-discretionary and always included. Tips are never included.
///   OT premium = OT hours x (multiplier - 1) x regular rate.
///   Week gross = straight-time pay for all hours + differentials + per-shift amounts
///                + OT premium.
///
/// Lines (Paycom manual entry):
///   REG  - non-OT minutes x their own rate, per date / event / storefront / role / rate.
///   OT   - the OT minutes (the LAST minutes worked in the week, chronologically; see
///          [markOvertime]), per date / event / storefront / role. Amount = those
///          minutes at their own straight-time rate + their share of the OT premium.
///          The line rate is amount / hours (4 decimals). When every hour of the week
///          has the same rate this is exactly multiplier x regular rate; when the OT
///          minutes were worked at a rate different from the weighted regular rate it
///          is not, and paying "OT hours x 1.5 x regular rate" instead would underpay
///          (or overpay) against the FLSA total. The total always equals the FLSA week
///          gross above. Enter the OT AMOUNT in Paycom, not hours x Paycom's rate.
///   LEAD etc. - per-hour differentials on ALL minutes (REG and OT) at straight time,
///          under the differential's pay code; their OT half-time is in the OT premium.
///   BONUS - per-shift amounts of every differential that applies to a shift, one
///          line per shift, dated the local date of the shift's first paid minute and
///          counted in that date's workweek. Hours 0.
///   TIPS - one line per worker per local date of the tip pool's event start, from
///          tip allocations. Amount only; not in the regular rate or the week gross.
///   TIPMU - tip credit make-up, per workweek (see below).
///
/// Rounding (all integer cents and minutes, see money.dart):
///   - Each line amount is its exact value (minutes x cents per hour, or the exact OT
///     fraction) rounded half-up to the cent.
///   - The week gross is the exact week value rounded half-up once. Any difference
///     between it and the sum of the week's lines (a few cents at most) is added to
///     the week's chronologically last OT line, or, with no OT, its last REG line.
///     That line carries [PayLine.roundingAdjustmentCents]. So the lines of every
///     worker-week add up exactly to the week gross.
///   - Hours are display only: for each worker and pay code, line hours are rounded to
///     hundredths so they add up to the code's total minutes rounded half-up (largest
///     remainder, earlier lines first on ties). Amounts never use rounded hours.
///
/// Tip credit (29 U.S.C. 203(m)): taken only when PayRules.tipCredit.enabled, the
/// worker is in `tipCreditWorkers`, the cash wage is below minimum wage, and the
/// role is tipped (when [JobRole]s are supplied; a role not supplied is assumed
/// tipped). For those minutes the cash wage replaces the resolved rate on REG and
/// they count toward the regular rate at the full minimum wage (cash wage + tip
/// credit), so an OT hour pays cash wage + 0.5 x minimum wage = 1.5 x minimum wage -
/// tip credit ($5.755 federally). Make-up per workweek: if cash wages + tips <
/// minimum wage x tip-credit hours, i.e. tips < tip credit taken, TIPMU pays the
/// difference. Differentials, bonuses and OT premium are NOT counted toward covering
/// the credit (conservative; CONFIRM with counsel).
library;

import '../model/entities.dart';
import '../model/enums.dart';
import '../rules/local_time.dart';
import '../rules/overtime.dart';
import '../rules/venue_rules.dart';
import 'money.dart';
import 'pay_models.dart';
import 'pay_problem.dart';
import 'pay_rules.dart';
import 'rates.dart';
import 'work_time.dart';

/// One person's inputs for a payroll run.
class WorkerPayInput {
  const WorkerPayInput({
    required this.worker,
    this.punches = const [],
    this.shifts = const [],
    this.defaultJobRoleCode,
  });

  final Worker worker;

  /// All of the person's punches around the period (any status). Include the whole
  /// of every workweek that overlaps the period so overtime is right.
  final List<Punch> punches;
  final List<Shift> shifts;

  /// Role for punches with no event (or no shift); defaults to the first of
  /// [Worker.jobRoles].
  final String? defaultJobRoleCode;

  String? get defaultRole => defaultJobRoleCode ?? (worker.jobRoles.isEmpty ? null : worker.jobRoles.first);
}

/// Totals for one pay code.
class PayCodeTotal {
  const PayCodeTotal({required this.hoursHundredths, required this.amountCents});

  final int hoursHundredths;
  final int amountCents;
}

/// One workweek's pay for one worker (the full week, even if part is outside the period).
class WeekPay {
  const WeekPay({
    required this.firstDate,
    required this.lastDate,
    required this.totalMinutes,
    required this.overtimeMinutes,
    required this.dailyOvertimeMinutes,
    required this.weeklyOvertimeMinutes,
    required this.straightTimeCents,
    required this.regularRateE4,
    required this.overtimePremiumCents,
    required this.grossCents,
    required this.roundingAdjustmentCents,
    required this.tipCreditMinutes,
    required this.tipCreditTakenCents,
    required this.tipsCents,
    required this.tipMakeupCents,
    required this.withinPeriod,
  });

  final DateTime firstDate;
  final DateTime lastDate;
  final int totalMinutes;
  final int overtimeMinutes;
  final int dailyOvertimeMinutes;
  final int weeklyOvertimeMinutes;

  /// Cash straight-time pay for all hours incl. differentials and per-shift amounts
  /// (rounded for display; the gross is computed from the exact value).
  final int straightTimeCents;

  /// FLSA regular rate in ten-thousandths of a dollar (display, rounded).
  final int regularRateE4;

  /// OT premium (display, rounded).
  final int overtimePremiumCents;

  /// Authoritative week wages: the REG, OT, differential and BONUS lines of the week
  /// add up to exactly this.
  final int grossCents;
  final int roundingAdjustmentCents;
  final int tipCreditMinutes;
  final int tipCreditTakenCents;
  final int tipsCents;
  final int tipMakeupCents;

  /// False when the week straddles the period edge (the period is not aligned).
  final bool withinPeriod;
}

class WorkerPaySummary {
  const WorkerPaySummary({
    required this.workerId,
    required this.lines,
    required this.regularMinutes,
    required this.overtimeMinutes,
    required this.byPayCode,
    required this.weeks,
    required this.problems,
  });

  final String workerId;

  /// Lines dated inside the period.
  final List<PayLine> lines;

  /// Paid minutes inside the period, split into straight time and overtime.
  final int regularMinutes;
  final int overtimeMinutes;
  final Map<String, PayCodeTotal> byPayCode;
  final List<WeekPay> weeks;
  final List<PayProblem> problems;

  int get totalMinutes => regularMinutes + overtimeMinutes;
  int get regularHoursHundredths => minutesToHundredths(regularMinutes);
  int get overtimeHoursHundredths => minutesToHundredths(overtimeMinutes);

  /// Sum of all line amounts, tips included.
  int get grossCents => lines.fold(0, (s, l) => s + l.amountCents);
  int get tipsCents => lines.where((l) => l.payCode == PayCodes.tips).fold(0, (s, l) => s + l.amountCents);

  /// Gross minus tips.
  int get wagesCents => grossCents - tipsCents;
}

class EarningsResult {
  const EarningsResult({
    required this.period,
    required this.lines,
    required this.workers,
    required this.problems,
    required this.excludedWorkerIds,
  });

  final PayPeriod period;
  final List<PayLine> lines;
  final List<WorkerPaySummary> workers;
  final List<PayProblem> problems;

  /// Temps and NPO members (not paid through payroll).
  final List<String> excludedWorkerIds;

  int get totalCents => lines.fold(0, (s, l) => s + l.amountCents);
  bool get hasBlockingProblems => problems.any((p) => p.isBlocking);

  WorkerPaySummary? worker(String id) {
    for (final w in workers) {
      if (w.workerId == id) return w;
    }
    return null;
  }
}

/// Order of pay codes within a day.
int _codeRank(String code) => switch (code) {
      PayCodes.regular => 0,
      PayCodes.overtime => 1,
      PayCodes.bonus => 3,
      PayCodes.tipCreditMakeup => 4,
      PayCodes.tips => 5,
      _ => 2,
    };

/// A line being built, with its exact parts.
class _Draft {
  _Draft({
    required this.workerId,
    required this.date,
    required this.context,
    required this.payCode,
    this.rateE4,
  });

  final String workerId;
  final DateTime date;
  final WorkContext context;
  final String payCode;
  int? rateE4;
  int minutes = 0;
  int amountCents = 0;
  int adjustment = 0;
  DateTime? lastEnd;
  DateTime? firstStart;

  // OT only: exact numerator parts.
  int stMinuteCents = 0;

  void touch(DateTime start, DateTime end) {
    if (firstStart == null || start.isBefore(firstStart!)) firstStart = start;
    if (lastEnd == null || end.isAfter(lastEnd!)) lastEnd = end;
  }

  PayLine toLine(String? venueId, String? periodId) => PayLine(
        venueId: venueId,
        payPeriodId: periodId,
        workerId: workerId,
        workDate: date,
        eventId: context.eventId,
        storefrontId: context.storefrontId,
        jobRoleCode: context.jobRoleCode,
        payCode: payCode,
        rateE4: rateE4,
        amountCents: amountCents + adjustment,
        minutes: minutes,
        roundingAdjustmentCents: adjustment,
      );
}

/// Calculates payroll lines for [period].
EarningsResult calculateEarnings({
  required String timeZone,
  required VenueRules venueRules,
  required PayRules payRules,
  required PayPeriod period,
  required List<WorkerPayInput> workers,
  required Map<String, Event> events,
  required List<PayRate> rates,
  List<PayDifferential> differentials = const [],
  List<TipPool> tipPools = const [],
  List<TipAllocation> tipAllocations = const [],
  Set<String> tipCreditWorkers = const {},
  Map<String, JobRole> jobRoles = const {},
}) {
  final ot = venueRules.overtime;
  final problems = <PayProblem>[];
  final excluded = <String>[];
  final summaries = <WorkerPaySummary>[];
  final allLines = <PayLine>[];

  final aligned = period.startsOn.weekday == ot.workweekStartDay && period.days % 7 == 0;
  if (!aligned) {
    problems.add(PayProblem(
      kind: PayProblemKind.periodNotAlignedToWorkweeks,
      severity: PayProblemSeverity.warning,
      message: 'Pay period ${formatDate(period.startsOn)} to ${formatDate(period.endsOn)} does not line up with '
          'workweeks. Overtime is still figured per full workweek, and lines for days outside this period '
          'are paid in the neighboring period; include punches for the whole workweeks and calculate both.',
      workDate: period.startsOn,
    ));
  }

  final windowStart = localDateOf(
      workweekStart(startOfLocalDay(period.startsOn, timeZone), timeZone, ot.workweekStartDay), timeZone);
  final windowEnd = addCalendarDays(
      localDateOf(workweekStart(startOfLocalDay(period.endsOn, timeZone), timeZone, ot.workweekStartDay), timeZone),
      6);
  bool inWindow(DateTime d) => !d.isBefore(windowStart) && !d.isAfter(windowEnd);

  // Tips by worker and date.
  final poolsById = {for (final p in tipPools) p.id: p};
  final inputIds = {for (final w in workers) w.worker.id};
  final regularIds = {
    for (final w in workers)
      if (w.worker.type == WorkerType.regular) w.worker.id,
  };
  final tipsByWorker = <String, Map<DateTime, List<(TipAllocation, TipPool)>>>{};
  for (final a in tipAllocations) {
    final pool = poolsById[a.poolId];
    final ev = pool == null ? null : events[pool.eventId];
    if (pool == null || ev == null) {
      problems.add(PayProblem(
        kind: PayProblemKind.tipPoolUnknown,
        severity: PayProblemSeverity.blocking,
        message: 'Tip allocation for pool ${a.poolId} cannot be dated: the pool or its event was not supplied.',
        workerId: a.workerId,
        eventId: pool?.eventId,
      ));
      continue;
    }
    final date = localDateOf(ev.startTime, timeZone);
    if (!regularIds.contains(a.workerId)) {
      if (period.contains(date) && a.amountCents != 0) {
        problems.add(PayProblem(
          kind: PayProblemKind.tipsForNonPayrollWorker,
          severity: PayProblemSeverity.warning,
          message: inputIds.contains(a.workerId)
              ? 'Tips of ${formatCents(a.amountCents)} allocated to a temp or NPO member are not paid through payroll.'
              : 'Tips of ${formatCents(a.amountCents)} allocated to someone not in this payroll run.',
          workerId: a.workerId,
          eventId: pool.eventId,
          workDate: date,
        ));
      }
      continue;
    }
    tipsByWorker.putIfAbsent(a.workerId, () => {}).putIfAbsent(date, () => []).add((a, pool));
  }

  final tipCreditOn = payRules.tipCredit.enabled && payRules.tipCredit.cashWageCents < payRules.minimumWageCents;
  final mult = payRules.overtimeMultiplierThousandths;

  for (final input in workers) {
    final w = input.worker;
    if (w.type != WorkerType.regular) {
      excluded.add(w.id);
      continue;
    }
    final wProblems = <PayProblem>[];
    final work = attributeWork(
      workerId: w.id,
      punches: input.punches,
      shifts: input.shifts,
      events: events,
      timeZone: timeZone,
      breakRules: venueRules.breaks,
      defaultJobRoleCode: input.defaultRole,
    );
    wProblems.addAll(work.problems);
    final pieces = [
      for (final p in work.pieces)
        if (inWindow(p.date)) p,
    ];
    final weeks = markOvertime(pieces, timeZone: timeZone, rules: ot);

    // Rates and differentials per (role, event type, date), resolved once.
    final rateCache = <String, PayRate?>{};
    final diffCache = <String, List<PayDifferential>>{};
    final reported = <String>{};
    String cacheKey(WorkContext c, DateTime d) => '${c.jobRoleCode}|${c.eventTypeCode}|${formatDate(d)}';
    PayRate? rateFor(WorkContext c, DateTime d) => rateCache.putIfAbsent(
        cacheKey(c, d),
        () => resolveRate(
            workerId: w.id, jobRoleCode: c.jobRoleCode, eventTypeCode: c.eventTypeCode, date: d, rates: rates));
    List<PayDifferential> diffsFor(WorkContext c, DateTime d) => diffCache.putIfAbsent(
        cacheKey(c, d),
        () => resolveDifferentials(
            workerId: w.id,
            jobRoleCode: c.jobRoleCode,
            eventTypeCode: c.eventTypeCode,
            date: d,
            differentials: differentials));
    final workerTipCredit = tipCreditOn && tipCreditWorkers.contains(w.id);
    bool tipCreditFor(WorkContext c) {
      if (!workerTipCredit) return false;
      final role = c.jobRoleCode == null ? null : jobRoles[c.jobRoleCode];
      return role == null || role.tipped;
    }

    /// (straight-time cash rate, regular-rate rate) in cents per hour; null when no
    /// rate applies (the time is then paid at 0 and reported).
    (int, int)? ratesFor(WorkPiece p) {
      if (tipCreditFor(p.context)) {
        return (payRules.tipCredit.cashWageCents, payRules.minimumWageCents);
      }
      final r = rateFor(p.context, p.date);
      final key = cacheKey(p.context, p.date);
      if (r == null) {
        if (reported.add('rate|$key')) {
          wProblems.add(PayProblem(
            kind: PayProblemKind.missingRate,
            severity: PayProblemSeverity.blocking,
            message: 'No pay rate for ${p.context.jobRoleCode ?? 'no role'}'
                '${p.context.eventTypeCode == null ? '' : ' at ${p.context.eventTypeCode}'} on ${formatDate(p.date)}.',
            workerId: w.id,
            eventId: p.context.eventId,
            shiftId: p.context.shiftId,
            workDate: p.date,
          ));
        }
        return null;
      }
      if (r.hourlyRateCents < payRules.minimumWageCents && reported.add('min|$key')) {
        wProblems.add(PayProblem(
          kind: PayProblemKind.belowMinimumWage,
          severity: PayProblemSeverity.blocking,
          message: 'Rate ${formatCents(r.hourlyRateCents)} is below minimum wage '
              '${formatCents(payRules.minimumWageCents)} on ${formatDate(p.date)}.',
          workerId: w.id,
          eventId: p.context.eventId,
          workDate: p.date,
        ));
      }
      return (r.hourlyRateCents, r.hourlyRateCents);
    }

    // Per-shift amounts: one per attribution group with an event, dated by its first
    // paid minute (over all of the person's time, so a shift is never counted twice).
    final firstPieceByGroup = <String, WorkPiece>{};
    for (final p in work.pieces) {
      if (p.context.eventId == null) continue;
      firstPieceByGroup.putIfAbsent(p.context.key, () => p);
    }

    final tips = tipsByWorker[w.id] ?? const {};
    final weekPays = <WeekPay>[];
    final drafts = <_Draft>[];

    for (final week in weeks) {
      final t = week.totalMinutes;
      if (t == 0) continue;
      final otMin = week.overtimeMinutes;
      var eCash60 = 0; // cash straight time, in minute-cents-per-hour (divide by 60 for cents)
      var eRr60 = 0; // the same, counted toward the regular rate
      var tcMinutes = 0;
      WorkPiece? lastTcPiece;
      final reg = <String, _Draft>{};
      final otDrafts = <String, _Draft>{};
      final diffDrafts = <String, _Draft>{};
      final bonusDrafts = <_Draft>[];

      for (final p in week.pieces) {
        final resolved = ratesFor(p);
        final (st, rr) = resolved ?? (0, 0);
        final m = p.minutes;
        final c = p.context;
        final ds = diffsFor(c, p.date);
        var perHour = 0;
        for (final d in ds) {
          if (d.perHourCents == 0) continue;
          perHour += d.perHourCents;
          final k = '${formatDate(p.date)}|${c.key}|${d.payCode}|${d.perHourCents}';
          final dd = diffDrafts.putIfAbsent(
              k,
              () => _Draft(
                  workerId: w.id, date: p.date, context: c, payCode: d.payCode, rateE4: d.perHourCents * 100));
          dd.minutes += m;
          dd.touch(p.start, p.end);
        }
        eCash60 += m * st + m * perHour;
        eRr60 += m * rr + m * perHour;
        if (tipCreditFor(c)) {
          tcMinutes += m;
          lastTcPiece = p;
        }
        if (p.overtime) {
          final k = '${formatDate(p.date)}|${c.key}';
          final d = otDrafts.putIfAbsent(
              k, () => _Draft(workerId: w.id, date: p.date, context: c, payCode: PayCodes.overtime));
          d.minutes += m;
          d.stMinuteCents += m * st;
          d.touch(p.start, p.end);
        } else {
          final k = '${formatDate(p.date)}|${c.key}|${resolved == null ? 'none' : st}';
          final d = reg.putIfAbsent(
              k,
              () => _Draft(
                  workerId: w.id,
                  date: p.date,
                  context: c,
                  payCode: PayCodes.regular,
                  rateE4: resolved == null ? null : st * 100));
          d.minutes += m;
          d.touch(p.start, p.end);
        }
      }

      for (final first in firstPieceByGroup.values) {
        if (first.date.isBefore(week.firstDate) || first.date.isAfter(week.lastDate)) continue;
        if (!week.pieces.any((p) => p.context.key == first.context.key)) continue;
        final perShift = diffsFor(first.context, first.date).fold(0, (s, d) => s + d.perShiftCents);
        if (perShift == 0) continue;
        eCash60 += perShift * 60;
        eRr60 += perShift * 60;
        bonusDrafts.add(
            _Draft(workerId: w.id, date: first.date, context: first.context, payCode: PayCodes.bonus)
              ..amountCents = perShift
              ..touch(first.start, first.end));
      }

      // Exact week gross = (eCash60 * 1000 * T + OT * eRr60 * (mult - 1000)) / (60000 * T).
      final bigT = BigInt.from(t);
      final den = BigInt.from(60000) * bigT;
      final premiumNum = BigInt.from(otMin) * BigInt.from(eRr60) * BigInt.from(mult - 1000);
      final grossNum = BigInt.from(eCash60) * BigInt.from(1000) * bigT + premiumNum;
      final weekGross = bigDivRoundHalfUp(grossNum, den);

      for (final d in reg.values) {
        d.amountCents = d.rateE4 == null ? 0 : amountForMinutes(d.minutes, d.rateE4! ~/ 100);
      }
      for (final d in otDrafts.values) {
        final n = BigInt.from(d.stMinuteCents) * BigInt.from(1000) * bigT +
            BigInt.from(d.minutes) * BigInt.from(eRr60) * BigInt.from(mult - 1000);
        d.amountCents = bigDivRoundHalfUp(n, den);
        d.rateE4 = bigDivRoundHalfUp(n * BigInt.from(6000), den * BigInt.from(d.minutes));
      }
      for (final d in diffDrafts.values) {
        d.amountCents = amountForMinutes(d.minutes, d.rateE4! ~/ 100);
      }
      final weekDrafts = [...reg.values, ...otDrafts.values, ...diffDrafts.values, ...bonusDrafts];
      final sum = weekDrafts.fold(0, (s, d) => s + d.amountCents);
      final remainder = weekGross - sum;
      if (remainder.abs() > weekDrafts.length) {
        throw StateError('Week rounding remainder $remainder is larger than expected');
      }
      if (remainder != 0) {
        final candidates = otDrafts.isNotEmpty ? otDrafts.values : reg.values;
        final target = candidates.reduce((a, b) => b.lastEnd!.isAfter(a.lastEnd!) ? b : a);
        target.adjustment += remainder;
      }

      // Tip credit make-up.
      var tipsWeek = 0;
      for (final e in tips.entries) {
        if (!e.key.isBefore(week.firstDate) && !e.key.isAfter(week.lastDate)) {
          tipsWeek += e.value.fold(0, (s, x) => s + x.$1.amountCents);
        }
      }
      final creditTaken = amountForMinutes(tcMinutes, payRules.tipCreditCents);
      final makeup = tcMinutes == 0 ? 0 : (creditTaken > tipsWeek ? creditTaken - tipsWeek : 0);
      if (makeup > 0) {
        final p = lastTcPiece!;
        weekDrafts.add(
            _Draft(workerId: w.id, date: p.date, context: p.context, payCode: PayCodes.tipCreditMakeup)
              ..amountCents = makeup
              ..touch(p.start, p.end));
      }
      drafts.addAll(weekDrafts);

      weekPays.add(WeekPay(
        firstDate: week.firstDate,
        lastDate: week.lastDate,
        totalMinutes: t,
        overtimeMinutes: otMin,
        dailyOvertimeMinutes: week.overtime.dailyOvertimeMinutes,
        weeklyOvertimeMinutes: week.overtime.weeklyOvertimeMinutes,
        straightTimeCents: divRoundHalfUp(eCash60, 60),
        regularRateE4: divRoundHalfUp(eRr60 * 100, t),
        overtimePremiumCents: bigDivRoundHalfUp(premiumNum, den),
        grossCents: weekGross,
        roundingAdjustmentCents: remainder,
        tipCreditMinutes: tcMinutes,
        tipCreditTakenCents: creditTaken,
        tipsCents: tipsWeek,
        tipMakeupCents: makeup,
        withinPeriod: period.contains(week.firstDate) && period.contains(week.lastDate),
      ));
    }

    // TIPS: one line per worker per date in the period.
    for (final e in tips.entries) {
      if (!period.contains(e.key)) continue;
      final amount = e.value.fold(0, (s, x) => s + x.$1.amountCents);
      final eventIds = {for (final x in e.value) x.$2.eventId};
      final storefrontIds = {for (final x in e.value) x.$2.storefrontId};
      drafts.add(_Draft(
        workerId: w.id,
        date: e.key,
        context: WorkContext(
          eventId: eventIds.length == 1 ? eventIds.first : null,
          storefrontId: storefrontIds.length == 1 ? storefrontIds.first : null,
        ),
        payCode: PayCodes.tips,
      )..amountCents = amount);
    }

    final inPeriod = [
      for (final d in drafts)
        if (period.contains(d.date)) d,
    ]..sort((a, b) {
        var c = a.date.compareTo(b.date);
        if (c != 0) return c;
        c = _codeRank(a.payCode).compareTo(_codeRank(b.payCode));
        if (c != 0) return c;
        c = a.payCode.compareTo(b.payCode);
        if (c != 0) return c;
        final fa = a.firstStart, fb = b.firstStart;
        if (fa != null && fb != null) {
          c = fa.compareTo(fb);
          if (c != 0) return c;
        }
        c = (a.context.eventId ?? '').compareTo(b.context.eventId ?? '');
        if (c != 0) return c;
        c = (a.context.storefrontId ?? '').compareTo(b.context.storefrontId ?? '');
        if (c != 0) return c;
        c = (a.context.jobRoleCode ?? '').compareTo(b.context.jobRoleCode ?? '');
        return c != 0 ? c : (a.rateE4 ?? 0).compareTo(b.rateE4 ?? 0);
      });
    var lines = [for (final d in inPeriod) d.toLine(period.venueId, period.id)];

    // Hours: per pay code, rounded so the code's line hours add up to its total.
    final byCodeIdx = <String, List<int>>{};
    for (var i = 0; i < lines.length; i++) {
      if ((lines[i].minutes ?? 0) > 0) byCodeIdx.putIfAbsent(lines[i].payCode, () => []).add(i);
    }
    for (final idx in byCodeIdx.values) {
      final hs = roundPreservingTotal([for (final i in idx) lines[i].minutes! * 100], 60);
      for (var k = 0; k < idx.length; k++) {
        lines[idx[k]] = lines[idx[k]].copyWith(hoursHundredths: hs[k]);
      }
    }
    lines = List.unmodifiable(lines);

    final byPayCode = <String, PayCodeTotal>{};
    for (final l in lines) {
      final prev = byPayCode[l.payCode];
      byPayCode[l.payCode] = PayCodeTotal(
        hoursHundredths: (prev?.hoursHundredths ?? 0) + l.hoursHundredths,
        amountCents: (prev?.amountCents ?? 0) + l.amountCents,
      );
    }
    var regMin = 0, otMinTotal = 0;
    for (final week in weeks) {
      for (final p in week.pieces) {
        if (!period.contains(p.date)) continue;
        if (p.overtime) {
          otMinTotal += p.minutes;
        } else {
          regMin += p.minutes;
        }
      }
    }

    summaries.add(WorkerPaySummary(
      workerId: w.id,
      lines: lines,
      regularMinutes: regMin,
      overtimeMinutes: otMinTotal,
      byPayCode: Map.unmodifiable(byPayCode),
      weeks: List.unmodifiable(weekPays),
      problems: List.unmodifiable(wProblems),
    ));
    allLines.addAll(lines);
    problems.addAll(wProblems);
  }

  return EarningsResult(
    period: period,
    lines: List.unmodifiable(allLines),
    workers: List.unmodifiable(summaries),
    problems: List.unmodifiable(problems),
    excludedWorkerIds: List.unmodifiable(excluded),
  );
}
