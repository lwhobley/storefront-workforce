/// Targets for the KPI reports, with green / yellow / red status.
///
/// - Fill rate (staffed out of planned) and on-time rate use the venue's row in
///   `report_targets` (migration 0015): green at or above the green bound, yellow at or
///   above the yellow bound, else red. Without a row the defaults below apply.
/// - Labor cost against budget: at or under budget is green, up to
///   [ReportTargets.budgetYellowOver] over (default 10%) is yellow, more is red. That
///   bound comes from `venues.settings.reports.budget_yellow_over_percent` when set.
library;

/// Green, yellow or red; [none] when there is nothing to measure.
enum Rag { green, yellow, red, none }

class ReportTargets {
  const ReportTargets({
    this.fillGreen = defaultFillGreen,
    this.fillYellow = defaultFillYellow,
    this.attendanceGreen = defaultAttendanceGreen,
    this.attendanceYellow = defaultAttendanceYellow,
    this.budgetYellowOver = defaultBudgetYellowOver,
    this.isDefault = false,
  });

  static const defaultFillGreen = 0.98;
  static const defaultFillYellow = 0.90;
  static const defaultAttendanceGreen = 0.95;
  static const defaultAttendanceYellow = 0.85;

  /// Up to 10% over budget is yellow; more is red.
  static const defaultBudgetYellowOver = 0.10;

  static const defaults = ReportTargets(isDefault: true);

  final double fillGreen;
  final double fillYellow;

  /// Bounds for the on-time rate (on time out of everyone expected).
  final double attendanceGreen;
  final double attendanceYellow;

  /// Fraction over budget that is still yellow.
  final double budgetYellowOver;

  /// True when the venue has no saved targets.
  final bool isDefault;

  /// From a `report_targets` row (null = no row) and the venue settings.
  factory ReportTargets.fromRow(Map<String, dynamic>? row, {Map<String, dynamic> settings = const {}}) {
    double n(Object? v, double d) => v == null ? d : (v is num ? v.toDouble() : double.tryParse('$v') ?? d);
    final reports = (settings['reports'] as Map?)?.cast<String, dynamic>();
    final pct = reports?['budget_yellow_over_percent'];
    final over = pct is num && pct >= 0 && pct <= 100 ? pct / 100 : defaultBudgetYellowOver;
    return ReportTargets(
      fillGreen: n(row?['fill_green'], defaultFillGreen),
      fillYellow: n(row?['fill_yellow'], defaultFillYellow),
      attendanceGreen: n(row?['attendance_green'], defaultAttendanceGreen),
      attendanceYellow: n(row?['attendance_yellow'], defaultAttendanceYellow),
      budgetYellowOver: over.toDouble(),
      isDefault: row == null,
    );
  }

  Map<String, dynamic> toRow(String venueId) => {
        'venue_id': venueId,
        'fill_green': fillGreen,
        'fill_yellow': fillYellow,
        'attendance_green': attendanceGreen,
        'attendance_yellow': attendanceYellow,
      };

  ReportTargets copyWith({double? fillGreen, double? fillYellow, double? attendanceGreen, double? attendanceYellow}) => ReportTargets(
        fillGreen: fillGreen ?? this.fillGreen,
        fillYellow: fillYellow ?? this.fillYellow,
        attendanceGreen: attendanceGreen ?? this.attendanceGreen,
        attendanceYellow: attendanceYellow ?? this.attendanceYellow,
        budgetYellowOver: budgetYellowOver,
      );

  /// A plain message when the targets cannot be saved, else null. Matches the
  /// database checks (0015): yellow at or below green, rates between 0 and 100%.
  String? validate() {
    bool inRange(double v) => v >= 0 && v <= 1;
    if (![fillGreen, fillYellow, attendanceGreen, attendanceYellow].every(inRange)) return 'Targets must be between 0% and 100%.';
    if (fillYellow > fillGreen) return 'The yellow fill target must be at or below the green one.';
    if (attendanceYellow > attendanceGreen) return 'The yellow on-time target must be at or below the green one.';
    return null;
  }

  Rag fill(double? rate) => rateRag(rate, green: fillGreen, yellow: fillYellow);
  Rag attendance(double? rate) => rateRag(rate, green: attendanceGreen, yellow: attendanceYellow);
  Rag budget(int costCents, int? budgetCents) => budgetRag(costCents, budgetCents, yellowOver: budgetYellowOver);
}

/// Higher is better: green at or above [green], yellow at or above [yellow].
Rag rateRag(double? rate, {required double green, required double yellow}) {
  if (rate == null) return Rag.none;
  // A hair of tolerance so 49/50 = 0.98 reads as meeting a 98% target.
  const eps = 1e-9;
  if (rate + eps >= green) return Rag.green;
  if (rate + eps >= yellow) return Rag.yellow;
  return Rag.red;
}

/// At or under budget is green; up to [yellowOver] over is yellow; more is red. No
/// budget: [Rag.none].
Rag budgetRag(int costCents, int? budgetCents, {double yellowOver = ReportTargets.defaultBudgetYellowOver}) {
  if (budgetCents == null) return Rag.none;
  if (costCents <= budgetCents) return Rag.green;
  // Integer math: cost <= budget * (1 + over), with over in basis points.
  final bp = (yellowOver * 10000).round();
  if (costCents * 10000 <= budgetCents * (10000 + bp)) return Rag.yellow;
  return Rag.red;
}
