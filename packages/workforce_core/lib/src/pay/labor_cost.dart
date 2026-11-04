/// Labor cost of an event, per storefront and in total, against the labor budget.
///
///   payroll  - regular staff pay lines for the event (approved or calculated), every
///              code except tips (REG, OT, differentials, BONUS, TIPMU). The OT premium
///              sits on the event where the week's last hours were worked.
///   burden   - payroll x PayRules.laborBurdenBasisPoints, rounded half-up per storefront
///              row; the event's burden is the sum of the rows.
///   temp     - agency invoice lines for the event, at bill rates.
///   npo      - each group's payout total, split across storefronts by the members'
///              paid minutes there (largest remainder, so it adds up exactly). A payout
///              with no minutes (all no-shows, an adjustment only) is unassigned.
///   tips     - shown separately; not labor cost.
///   total    - payroll + burden + temp + npo.
/// Lines with no storefront are on the unassigned row (storefrontId null).
/// Cost per attendee = total / actual attendance (expected when no actual), half-up.
/// Budget status: over when cost > budget; near when cost >= 95% of budget; else under.
library;

import '../model/entities.dart';
import '../rules/venue_rules.dart';
import 'agency_billing.dart';
import 'money.dart';
import 'pay_models.dart';
import 'pay_rules.dart';
import 'work_time.dart';

enum BudgetStatus { under, near, over }

/// Status of [costCents] against [budgetCents] (null with no budget).
BudgetStatus? budgetStatus(int costCents, int? budgetCents) {
  if (budgetCents == null) return null;
  if (costCents > budgetCents) return BudgetStatus.over;
  if (budgetCents > 0 && costCents * 100 >= budgetCents * 95) return BudgetStatus.near;
  return BudgetStatus.under;
}

class LaborCostRow {
  const LaborCostRow({
    required this.storefrontId,
    required this.payrollCents,
    required this.burdenCents,
    required this.tempCents,
    required this.npoCents,
    required this.tipsCents,
    this.budgetCents,
  });

  /// Null for the unassigned row and for the event total.
  final String? storefrontId;
  final int payrollCents;
  final int burdenCents;
  final int tempCents;
  final int npoCents;

  /// Not part of [totalCents].
  final int tipsCents;
  final int? budgetCents;

  int get totalCents => payrollCents + burdenCents + tempCents + npoCents;
  BudgetStatus? get status => budgetStatus(totalCents, budgetCents);

  /// Budget minus cost (negative when over); null with no budget.
  int? get varianceCents => budgetCents == null ? null : budgetCents! - totalCents;
}

class LaborCostReport {
  const LaborCostReport({
    required this.eventId,
    required this.attendance,
    required this.attendanceIsActual,
    required this.storefronts,
    required this.total,
  });

  final String eventId;
  final int attendance;
  final bool attendanceIsActual;

  /// Sorted by storefront id; the unassigned row (if any) last.
  final List<LaborCostRow> storefronts;
  final LaborCostRow total;

  int? get costPerAttendeeCents => attendance <= 0 ? null : divRoundHalfUp(total.totalCents, attendance);

  LaborCostRow? storefront(String? id) {
    for (final r in storefronts) {
      if (r.storefrontId == id) return r;
    }
    return null;
  }
}

/// Paid minutes of each NPO group's members at [event], by storefront (null when the
/// work has no shift). Feed this to [calculateLaborCost].
Map<String, Map<String?, int>> npoMinutesByStorefront({
  required Event event,
  required List<Worker> members,
  required List<Shift> shifts,
  required Map<String, List<Punch>> punchesByWorker,
  required String timeZone,
  BreakRules breakRules = const BreakRules(),
}) {
  final out = <String, Map<String?, int>>{};
  for (final m in members) {
    final group = m.npoGroupId;
    if (group == null) continue;
    final mine = [
      for (final s in shifts)
        if (s.eventId == event.id && s.workerId == m.id) s,
    ];
    final ids = {for (final s in mine) s.id};
    final work = attributeWork(
      workerId: m.id,
      punches: [
        for (final p in punchesByWorker[m.id] ?? const <Punch>[])
          if (p.eventId == event.id || ids.contains(p.shiftId)) p,
      ],
      shifts: mine,
      events: {event.id: event},
      timeZone: timeZone,
      breakRules: breakRules,
    );
    for (final p in work.pieces) {
      final byStore = out.putIfAbsent(group, () => {});
      byStore[p.context.storefrontId] = (byStore[p.context.storefrontId] ?? 0) + p.minutes;
    }
  }
  return out;
}

int _compareStorefront(String? a, String? b) {
  if (a == b) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return a.compareTo(b);
}

/// Labor cost for [event].
LaborCostReport calculateLaborCost({
  required Event event,
  required PayRules payRules,
  List<PayLine> payLines = const [],
  List<AgencyInvoiceLine> agencyLines = const [],
  List<NpoPayout> npoPayouts = const [],
  Map<String, Map<String?, int>> npoMinutes = const {},
  List<PayCode> payCodes = const [],
  int? eventBudgetCents,
  Map<String, int> storefrontBudgetsCents = const {},
}) {
  final kinds = {for (final c in payCodes) c.code: c.kind};
  bool isTips(String code) => (kinds[code] ?? PayCodes.defaultKind(code)) == PayCodeKind.tips;

  final payroll = <String?, int>{};
  final tips = <String?, int>{};
  final temp = <String?, int>{};
  final npo = <String?, int>{};
  void add(Map<String?, int> m, String? k, int v) => m[k] = (m[k] ?? 0) + v;

  for (final l in payLines) {
    if (l.eventId != event.id) continue;
    add(isTips(l.payCode) ? tips : payroll, l.storefrontId, l.amountCents);
  }
  for (final l in agencyLines) {
    if (l.eventId != event.id) continue;
    add(temp, l.storefrontId, l.amountCents);
  }
  for (final p in npoPayouts) {
    if (p.eventId != event.id || p.totalCents == 0) continue;
    final mins = npoMinutes[p.npoGroupId] ?? const {};
    final keys = [
      for (final e in mins.entries)
        if (e.value > 0) e.key,
    ]..sort(_compareStorefront);
    if (keys.isEmpty) {
      add(npo, null, p.totalCents);
      continue;
    }
    final shares = splitByLargestRemainder(p.totalCents, [for (final k in keys) mins[k]!]);
    for (var i = 0; i < keys.length; i++) {
      add(npo, keys[i], shares[i]);
    }
  }

  final ids = <String?>{
    ...payroll.keys,
    ...tips.keys,
    ...temp.keys,
    ...npo.keys,
    ...storefrontBudgetsCents.keys,
  }.toList()..sort(_compareStorefront);
  final rows = [
    for (final id in ids)
      LaborCostRow(
        storefrontId: id,
        payrollCents: payroll[id] ?? 0,
        burdenCents: divRoundHalfUp((payroll[id] ?? 0) * payRules.laborBurdenBasisPoints, 10000),
        tempCents: temp[id] ?? 0,
        npoCents: npo[id] ?? 0,
        tipsCents: tips[id] ?? 0,
        budgetCents: id == null ? null : storefrontBudgetsCents[id],
      ),
  ];
  int sum(int Function(LaborCostRow) f) => rows.fold(0, (s, r) => s + f(r));
  final actual = event.actualAttendance;
  return LaborCostReport(
    eventId: event.id,
    attendance: actual ?? event.expectedAttendance,
    attendanceIsActual: actual != null,
    storefronts: List.unmodifiable(rows),
    total: LaborCostRow(
      storefrontId: null,
      payrollCents: sum((r) => r.payrollCents),
      burdenCents: sum((r) => r.burdenCents),
      tempCents: sum((r) => r.tempCents),
      npoCents: sum((r) => r.npoCents),
      tipsCents: sum((r) => r.tipsCents),
      budgetCents: eventBudgetCents,
    ),
  );
}
