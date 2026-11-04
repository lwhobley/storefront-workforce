/// Event performance numbers: fill rate, attendance, labor cost against budget, cost per
/// attendee, and staffing mix. Pure calculations over shifts, punches, and needs, so the
/// same numbers can be shown live, after the event, and in exports.
///
///   fill rate   - assigned positions / positions needed (null when nothing is needed).
///   attendance  - people with a clock-in / assigned positions. Late = first clock-in more
///                 than lateGraceMinutes after call time. No-show = no clock-in at all.
///   labor cost  - from [LaborCostReport] (see labor_cost.dart); null when not supplied.
///   staffing    - assigned positions counted by job role.
library;

import '../model/entities.dart';
import '../pay/labor_cost.dart';
import '../model/enums.dart';
import '../rules/venue_rules.dart';

/// Green, yellow, or red for a number against a target you set.
enum KpiBand { green, yellow, red }

class KpiTarget {
  const KpiTarget({required this.green, required this.yellow, this.higherIsBetter = true})
      : assert(higherIsBetter ? green >= yellow : green <= yellow, 'green must be the better bound');

  /// Reached for green; at or beyond [yellow] (but not green) for yellow; otherwise red.
  final num green;
  final num yellow;
  final bool higherIsBetter;

  /// Null when [value] is unknown.
  KpiBand? band(num? value) {
    if (value == null) return null;
    if (higherIsBetter) {
      if (value >= green) return KpiBand.green;
      if (value >= yellow) return KpiBand.yellow;
      return KpiBand.red;
    }
    if (value <= green) return KpiBand.green;
    if (value <= yellow) return KpiBand.yellow;
    return KpiBand.red;
  }
}

class EventKpis {
  const EventKpis({
    required this.eventId,
    required this.needed,
    required this.assigned,
    required this.attended,
    required this.late,
    required this.noShows,
    required this.staffingMix,
    this.labor,
  });

  final String eventId;

  /// Positions the schedule asked for (sum of staffing needs).
  final int needed;

  /// Positions with a person in them, not released.
  final int assigned;

  /// Assigned people with a clock-in at this event.
  final int attended;

  /// Attended, but the first clock-in was past the late grace.
  final int late;

  /// Assigned people with no clock-in.
  final int noShows;

  /// Assigned positions by job role code, sorted by code.
  final Map<String, int> staffingMix;

  /// Labor cost, when the labor report was supplied.
  final LaborCostReport? labor;

  /// Assigned / needed; can exceed 1 when overstaffed. Null when nothing was needed.
  double? get fillRate => needed == 0 ? null : assigned / needed;

  /// Attended / assigned. Null when nobody was assigned.
  double? get attendanceRate => assigned == 0 ? null : attended / assigned;

  int? get laborCostCents => labor?.total.totalCents;
  int? get budgetCents => labor?.total.budgetCents;
  BudgetStatus? get budgetStatus => labor?.total.status;

  /// Labor cost per attendee; null without a labor report or attendance.
  int? get costPerAttendeeCents => labor?.costPerAttendeeCents;
}

/// KPIs for one event. [shifts], [needs], and [punches] must already be limited to
/// [eventId]; the caller decides which punches belong to it.
EventKpis calculateEventKpis({
  required String eventId,
  required List<Shift> shifts,
  required List<StaffingNeed> needs,
  required List<Punch> punches,
  required AttendanceRules attendance,
  LaborCostReport? labor,
}) {
  final needed = needs.fold(0, (s, n) => s + n.count);
  final filled = [
    for (final s in shifts)
      if (isFilledShift(s)) s,
  ];


  var attended = 0;
  var late = 0;
  for (final s in filled) {
    final inAt = _firstClockIn(s, punches, eventId);
    if (inAt == null) continue;
    attended++;
    if (inAt.difference(s.callTime).inMinutes > attendance.lateGraceMinutes) late++;
  }

  final mix = <String, int>{};
  for (final s in filled) {
    mix[s.jobRoleCode] = (mix[s.jobRoleCode] ?? 0) + 1;
  }

  return EventKpis(
    eventId: eventId,
    needed: needed,
    assigned: filled.length,
    attended: attended,
    late: late,
    noShows: filled.length - attended,
    staffingMix: Map.unmodifiable({for (final k in mix.keys.toList()..sort()) k: mix[k]!}),
    labor: labor,
  );
}

/// A position with a person in it that was not released or cancelled.
bool isFilledShift(Shift s) =>
    s.workerId != null && s.releasedAt == null && s.status != ShiftStatus.released && s.status != ShiftStatus.cancelled;

DateTime? _firstClockIn(Shift shift, List<Punch> punches, String eventId) {
  DateTime? first;
  for (final p in punches) {
    if (p.kind != PunchKind.clockIn || p.status == PunchStatus.voided) continue;
    if (p.workerId != shift.workerId) continue;
    final mine = p.shiftId != null ? p.shiftId == shift.id : p.eventId == eventId;
    if (!mine) continue;
    if (first == null || p.occurredAt.isBefore(first)) first = p.occurredAt;
  }
  return first;
}

/// Event KPIs as CSV: one row per event, numbers only. Percentages have one decimal.
String eventKpisCsv(List<EventKpis> rows) {
  String pct(double? v) => v == null ? '' : (v * 100).toStringAsFixed(1);
  String str(Object? v) => v?.toString() ?? '';
  final out = StringBuffer(
    'event_id,needed,assigned,fill_rate_pct,attended,attendance_rate_pct,late,no_shows,'
    'labor_cost_cents,budget_cents,budget_status,cost_per_attendee_cents\n',
  );
  for (final r in rows) {
    out.write([
      r.eventId,
      r.needed,
      r.assigned,
      pct(r.fillRate),
      r.attended,
      pct(r.attendanceRate),
      r.late,
      r.noShows,
      str(r.laborCostCents),
      str(r.budgetCents),
      r.budgetStatus?.name ?? '',
      str(r.costPerAttendeeCents),
    ].join(','));
    out.write('\n');
  }
  return out.toString();
}
