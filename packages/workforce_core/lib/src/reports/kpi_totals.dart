/// Additive KPI counts for one slice (an event, a storefront at an event, a worker type,
/// a season). Rates are worked out from the counts, so slices add up exactly: a season
/// is the sum of its events, an event the sum of its storefronts.
library;

/// Counts behind the KPIs. Money is in cents; time in minutes.
class KpiTotals {
  const KpiTotals({
    this.events = 0,
    this.planned = 0,
    this.staffed = 0,
    this.fills = 0,
    this.fillMinutes = 0,
    this.onTime = 0,
    this.late = 0,
    this.noShows = 0,
    this.callOffs = 0,
    this.minutesLate = 0,
    this.workedMinutes = 0,
    this.overtimeMinutes = 0,
    this.breaksDue = 0,
    this.breaksMissed = 0,
    this.breaksLate = 0,
    this.breaksShort = 0,
    this.payrollCents = 0,
    this.burdenCents = 0,
    this.tempCents = 0,
    this.npoCents = 0,
    this.tipsCents = 0,
    this.budgetCents = 0,
    this.budgetedCostCents = 0,
    this.budgets = 0,
    this.attendees = 0,
  });

  static const zero = KpiTotals();

  /// Events counted (event and season totals only).
  final int events;

  // ---- Headcount ----
  /// Positions planned (staffing needs, or positions on the schedule when no need is set).
  final int planned;

  /// Planned positions with someone assigned (capped at the plan per storefront and role).
  final int staffed;

  /// Positions filled after being open, and the minutes they were open in total.
  final int fills;
  final int fillMinutes;

  // ---- Attendance (attendanceOutcomes) ----
  final int onTime;
  final int late;
  final int noShows;
  final int callOffs;
  final int minutesLate;

  // ---- Hours ----
  final int workedMinutes;
  final int overtimeMinutes;

  // ---- Breaks (rules due by the venue's break policy) ----
  final int breaksDue;
  final int breaksMissed;
  final int breaksLate;
  final int breaksShort;

  // ---- Money (view_pay only) ----
  final int payrollCents;
  final int burdenCents;
  final int tempCents;
  final int npoCents;

  /// Not part of labor cost.
  final int tipsCents;

  /// Sum of the budgets that are set, and the cost of the slices that have one.
  final int budgetCents;
  final int budgetedCostCents;

  /// Number of slices with a budget.
  final int budgets;

  /// Attendance used for cost per attendee (actual, else expected).
  final int attendees;

  KpiTotals operator +(KpiTotals o) => KpiTotals(
        events: events + o.events,
        planned: planned + o.planned,
        staffed: staffed + o.staffed,
        fills: fills + o.fills,
        fillMinutes: fillMinutes + o.fillMinutes,
        onTime: onTime + o.onTime,
        late: late + o.late,
        noShows: noShows + o.noShows,
        callOffs: callOffs + o.callOffs,
        minutesLate: minutesLate + o.minutesLate,
        workedMinutes: workedMinutes + o.workedMinutes,
        overtimeMinutes: overtimeMinutes + o.overtimeMinutes,
        breaksDue: breaksDue + o.breaksDue,
        breaksMissed: breaksMissed + o.breaksMissed,
        breaksLate: breaksLate + o.breaksLate,
        breaksShort: breaksShort + o.breaksShort,
        payrollCents: payrollCents + o.payrollCents,
        burdenCents: burdenCents + o.burdenCents,
        tempCents: tempCents + o.tempCents,
        npoCents: npoCents + o.npoCents,
        tipsCents: tipsCents + o.tipsCents,
        budgetCents: budgetCents + o.budgetCents,
        budgetedCostCents: budgetedCostCents + o.budgetedCostCents,
        budgets: budgets + o.budgets,
        attendees: attendees + o.attendees,
      );

  static KpiTotals sum(Iterable<KpiTotals> xs) => xs.fold(zero, (a, b) => a + b);

  // ---- Rates ----

  int get open => planned - staffed;

  /// Staffed out of planned. Null when nothing was planned.
  double? get fillRate => planned == 0 ? null : staffed / planned;

  /// Average hours a position stayed open before it was filled.
  double? get averageHoursToFill => fills == 0 ? null : fillMinutes / fills / 60;

  /// Same as AttendanceSummary.expected: on time + late + no-shows + call-offs.
  int get expected => onTime + late + noShows + callOffs;

  /// On time out of everyone expected (AttendanceSummary.onTimeRate).
  double? get onTimeRate => expected == 0 ? null : onTime / expected;

  /// Showed up at all (AttendanceSummary.attendanceRate).
  double? get attendanceRate => expected == 0 ? null : (onTime + late) / expected;

  double? get averageMinutesLate => late == 0 ? null : minutesLate / late;

  int get regularMinutes => workedMinutes - overtimeMinutes;

  /// Share of hours that were overtime.
  double? get overtimeShare => workedMinutes == 0 ? null : overtimeMinutes / workedMinutes;

  int get breakExceptions => breaksMissed + breaksLate + breaksShort;

  /// Breaks taken on time and long enough, out of breaks due.
  double? get breakComplianceRate => breaksDue == 0 ? null : (breaksDue - breakExceptions) / breaksDue;

  /// payroll + burden + temp + npo (tips are separate).
  int get laborCents => payrollCents + burdenCents + tempCents + npoCents;

  /// Regular staff cost (payroll plus burden).
  int get staffCostCents => payrollCents + burdenCents;

  /// Budget minus cost for the budgeted slices; null with no budget.
  int? get budgetVarianceCents => budgets == 0 ? null : budgetCents - budgetedCostCents;

  int? get costPerAttendeeCents => attendees <= 0 ? null : (laborCents * 2 + attendees) ~/ (attendees * 2);

  bool get hasActivity => planned > 0 || expected > 0 || workedMinutes > 0;
}
