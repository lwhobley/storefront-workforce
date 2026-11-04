import 'event_kpis.dart';

/// The green and yellow bounds the Reports screen colours fill rate and attendance by.
/// Green is reached at [fillGreen] (or better); yellow at [fillYellow]; anything lower is red.
class ReportTargets {
  const ReportTargets._({
    required this.fillGreen,
    required this.fillYellow,
    required this.attendanceGreen,
    required this.attendanceYellow,
  });

  static const defaults = ReportTargets._(fillGreen: 0.98, fillYellow: 0.90, attendanceGreen: 0.95, attendanceYellow: 0.85);

  final double fillGreen;
  final double fillYellow;
  final double attendanceGreen;
  final double attendanceYellow;

  KpiTarget get fill => KpiTarget(green: fillGreen, yellow: fillYellow);
  KpiTarget get attendance => KpiTarget(green: attendanceGreen, yellow: attendanceYellow);

  /// Null when a bound is out of range or yellow is set above green.
  static ReportTargets? tryCreate({
    required double fillGreen,
    required double fillYellow,
    required double attendanceGreen,
    required double attendanceYellow,
  }) {
    bool inRange(double v, double max) => v >= 0 && v <= max;
    if (!inRange(fillGreen, 2) || !inRange(fillYellow, 2)) return null;
    if (!inRange(attendanceGreen, 1) || !inRange(attendanceYellow, 1)) return null;
    if (fillYellow > fillGreen || attendanceYellow > attendanceGreen) return null;
    return ReportTargets._(
      fillGreen: fillGreen,
      fillYellow: fillYellow,
      attendanceGreen: attendanceGreen,
      attendanceYellow: attendanceYellow,
    );
  }

  factory ReportTargets.fromRow(Map<String, dynamic> j) => tryCreate(
            fillGreen: (j['fill_green'] as num).toDouble(),
            fillYellow: (j['fill_yellow'] as num).toDouble(),
            attendanceGreen: (j['attendance_green'] as num).toDouble(),
            attendanceYellow: (j['attendance_yellow'] as num).toDouble(),
          ) ??
          defaults;

  Map<String, dynamic> toRow() => {
        'fill_green': fillGreen,
        'fill_yellow': fillYellow,
        'attendance_green': attendanceGreen,
        'attendance_yellow': attendanceYellow,
      };

  @override
  bool operator ==(Object other) =>
      other is ReportTargets &&
      other.fillGreen == fillGreen &&
      other.fillYellow == fillYellow &&
      other.attendanceGreen == attendanceGreen &&
      other.attendanceYellow == attendanceYellow;

  @override
  int get hashCode => Object.hash(fillGreen, fillYellow, attendanceGreen, attendanceYellow);
}
