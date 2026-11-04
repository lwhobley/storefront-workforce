import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  test('defaults are the bounds the reports started with', () {
    expect(ReportTargets.defaults.fill.band(0.98), KpiBand.green);
    expect(ReportTargets.defaults.fill.band(0.90), KpiBand.yellow);
    expect(ReportTargets.defaults.attendance.band(0.84), KpiBand.red);
  });

  test('a yellow bound above the green bound is refused', () {
    expect(
      ReportTargets.tryCreate(fillGreen: 0.9, fillYellow: 0.95, attendanceGreen: 0.95, attendanceYellow: 0.85),
      isNull,
    );
    expect(
      ReportTargets.tryCreate(fillGreen: 0.98, fillYellow: 0.9, attendanceGreen: 0.8, attendanceYellow: 0.85),
      isNull,
    );
  });

  test('out-of-range bounds are refused', () {
    expect(ReportTargets.tryCreate(fillGreen: 2.5, fillYellow: 0.9, attendanceGreen: 0.95, attendanceYellow: 0.85), isNull);
    expect(ReportTargets.tryCreate(fillGreen: 0.98, fillYellow: 0.9, attendanceGreen: 1.2, attendanceYellow: 0.85), isNull);
    expect(ReportTargets.tryCreate(fillGreen: 0.98, fillYellow: -0.1, attendanceGreen: 0.95, attendanceYellow: 0.85), isNull);
  });

  test('a row round-trips, including whole-number bounds', () {
    final t = ReportTargets.tryCreate(fillGreen: 1, fillYellow: 0.92, attendanceGreen: 0.96, attendanceYellow: 0.8)!;
    expect(ReportTargets.fromRow(t.toRow()), t);
    expect(ReportTargets.fromRow(t.toRow()).fill.green, 1);
  });

  test('a stored row that breaks the rules falls back to the defaults', () {
    final bad = ReportTargets.fromRow({
      'fill_green': 0.5,
      'fill_yellow': 0.9,
      'attendance_green': 0.95,
      'attendance_yellow': 0.85,
    });
    expect(bad, ReportTargets.defaults);
  });
}
