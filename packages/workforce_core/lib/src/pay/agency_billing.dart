/// What each temp agency bills the venue for a date range.
///
/// Hours are paid minutes counted exactly as for payroll ([attributeWork]). Overtime
/// billing: hours over the weekly threshold (40 by default, from OvertimeRules, which
/// also gives the workweek start) in a workweek at this venue are billed at the
/// overtime bill rate, or the bill rate when that is null. Daily thresholds are not
/// used for billing (agency contracts bill weekly). The overtime minutes are the last
/// minutes of the week, as in payroll. Whole workweeks are figured from the punches
/// given; only minutes dated inside [from, to] are billed.
///
/// Bill rate: the agency's active rate for the shift's role on the local work date
/// (latest effective_from wins). Each invoice line is one worker / event / storefront
/// / role / bill rate; its regular and overtime amounts are each minutes x rate,
/// rounded half-up to the cent. Agency totals are the sum of their lines.
library;

import '../model/entities.dart';
import '../model/enums.dart';
import '../rules/local_time.dart';
import '../rules/venue_rules.dart';
import 'earnings.dart' show WorkerPayInput;
import 'money.dart';
import 'pay_models.dart';
import 'pay_problem.dart';
import 'rates.dart';
import 'work_time.dart';

class AgencyInvoiceLine {
  const AgencyInvoiceLine({
    required this.agencyId,
    required this.workerId,
    required this.firstWorkDate,
    required this.eventId,
    required this.storefrontId,
    required this.jobRoleCode,
    required this.regularMinutes,
    required this.overtimeMinutes,
    required this.billRateCents,
    required this.overtimeBillRateCents,
    required this.regularAmountCents,
    required this.overtimeAmountCents,
  });

  final String agencyId;
  final String workerId;
  final DateTime firstWorkDate;
  final String? eventId;
  final String? storefrontId;
  final String? jobRoleCode;
  final int regularMinutes;
  final int overtimeMinutes;

  /// Null when no bill rate was found (amounts are then 0 and a problem is reported).
  final int? billRateCents;
  final int? overtimeBillRateCents;
  final int regularAmountCents;
  final int overtimeAmountCents;

  int get amountCents => regularAmountCents + overtimeAmountCents;
  int get minutes => regularMinutes + overtimeMinutes;
  int get regularHoursHundredths => minutesToHundredths(regularMinutes);
  int get overtimeHoursHundredths => minutesToHundredths(overtimeMinutes);
}

class AgencyInvoice {
  const AgencyInvoice({required this.agencyId, required this.lines});

  final String agencyId;
  final List<AgencyInvoiceLine> lines;

  int get regularMinutes => lines.fold(0, (s, l) => s + l.regularMinutes);
  int get overtimeMinutes => lines.fold(0, (s, l) => s + l.overtimeMinutes);
  int get totalCents => lines.fold(0, (s, l) => s + l.amountCents);
}

class AgencyBillingResult {
  const AgencyBillingResult({required this.from, required this.to, required this.invoices, required this.problems});

  final DateTime from;
  final DateTime to;

  /// One per agency, sorted by agency id.
  final List<AgencyInvoice> invoices;
  final List<PayProblem> problems;

  int get totalCents => invoices.fold(0, (s, i) => s + i.totalCents);

  AgencyInvoice? invoice(String agencyId) {
    for (final i in invoices) {
      if (i.agencyId == agencyId) return i;
    }
    return null;
  }

  /// All lines of all agencies.
  List<AgencyInvoiceLine> get lines => [for (final i in invoices) ...i.lines];
}

class _Acc {
  _Acc(this.first);
  DateTime first;
  int reg = 0;
  int ot = 0;
}

/// Agency invoices for temps' work dated [from] to [to] (local dates, inclusive).
/// Non-temp workers in [temps] are ignored.
AgencyBillingResult calculateAgencyBilling({
  required String timeZone,
  required OvertimeRules overtimeRules,
  required DateTime from,
  required DateTime to,
  required List<WorkerPayInput> temps,
  required Map<String, Event> events,
  required List<AgencyBillRate> billRates,
  BreakRules breakRules = const BreakRules(),
}) {
  final rules = OvertimeRules(
    weeklyThresholdHours: overtimeRules.weeklyThresholdHours,
    workweekStartDay: overtimeRules.workweekStartDay,
  );
  final problems = <PayProblem>[];
  final byAgency = <String, List<AgencyInvoiceLine>>{};
  bool inRange(DateTime d) => !d.isBefore(from) && !d.isAfter(to);

  for (final input in temps) {
    final w = input.worker;
    if (w.type != WorkerType.temp) continue;
    final agencyId = w.agencyId;
    final work = attributeWork(
      workerId: w.id,
      punches: input.punches,
      shifts: input.shifts,
      events: events,
      timeZone: timeZone,
      breakRules: breakRules,
      defaultJobRoleCode: input.defaultRole,
    );
    problems.addAll(work.problems);
    if (agencyId == null) {
      if (work.pieces.any((p) => inRange(p.date))) {
        problems.add(PayProblem(
          kind: PayProblemKind.missingAgency,
          severity: PayProblemSeverity.blocking,
          message: 'Temp ${w.displayName} has no agency, so their hours cannot be billed.',
          workerId: w.id,
        ));
      }
      continue;
    }
    final weeks = markOvertime(work.pieces, timeZone: timeZone, rules: rules);
    final acc = <String, _Acc>{};
    final keys = <String, (WorkContext, AgencyBillRate?)>{};
    final reported = <String>{};
    for (final week in weeks) {
      for (final p in week.pieces) {
        if (!inRange(p.date)) continue;
        final role = p.context.jobRoleCode;
        final rate = role == null
            ? null
            : resolveBillRate(agencyId: agencyId, jobRoleCode: role, date: p.date, billRates: billRates);
        if (rate == null && reported.add('${role ?? ''}|${formatDate(p.date)}')) {
          problems.add(PayProblem(
            kind: PayProblemKind.missingBillRate,
            severity: PayProblemSeverity.blocking,
            message: 'No bill rate for ${role ?? 'no role'} with agency $agencyId on ${formatDate(p.date)}.',
            workerId: w.id,
            eventId: p.context.eventId,
            workDate: p.date,
          ));
        }
        final key = '${p.context.eventId}|${p.context.storefrontId}|$role|${rate?.id}';
        keys.putIfAbsent(key, () => (p.context, rate));
        final a = acc.putIfAbsent(key, () => _Acc(p.date));
        if (p.date.isBefore(a.first)) a.first = p.date;
        if (p.overtime) {
          a.ot += p.minutes;
        } else {
          a.reg += p.minutes;
        }
      }
    }
    for (final e in acc.entries) {
      final (ctx, rate) = keys[e.key]!;
      final bill = rate?.billRateCents;
      final otBill = rate == null ? null : (rate.overtimeBillRateCents ?? rate.billRateCents);
      byAgency.putIfAbsent(agencyId, () => []).add(AgencyInvoiceLine(
            agencyId: agencyId,
            workerId: w.id,
            firstWorkDate: e.value.first,
            eventId: ctx.eventId,
            storefrontId: ctx.storefrontId,
            jobRoleCode: ctx.jobRoleCode,
            regularMinutes: e.value.reg,
            overtimeMinutes: e.value.ot,
            billRateCents: bill,
            overtimeBillRateCents: otBill,
            regularAmountCents: bill == null ? 0 : amountForMinutes(e.value.reg, bill),
            overtimeAmountCents: otBill == null ? 0 : amountForMinutes(e.value.ot, otBill),
          ));
    }
  }

  final ids = byAgency.keys.toList()..sort();
  return AgencyBillingResult(
    from: from,
    to: to,
    invoices: [
      for (final id in ids)
        AgencyInvoice(
          agencyId: id,
          lines: List.unmodifiable(byAgency[id]!
            ..sort((a, b) {
              var c = a.firstWorkDate.compareTo(b.firstWorkDate);
              if (c != 0) return c;
              c = a.workerId.compareTo(b.workerId);
              if (c != 0) return c;
              return (a.eventId ?? '').compareTo(b.eventId ?? '');
            })),
        ),
    ],
    problems: List.unmodifiable(problems),
  );
}
