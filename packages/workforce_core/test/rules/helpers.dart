import 'package:workforce_core/workforce_core.dart';

const chicago = 'America/Chicago';

/// UTC instant of a Chicago wall-clock time.
DateTime ct(int y, int m, int d, [int h = 0, int min = 0, int sec = 0]) =>
    localToUtc(chicago, y, m, d, h, min).add(Duration(seconds: sec));

var _seq = 0;

Punch punch(
  PunchKind kind,
  DateTime at, {
  String? id,
  BreakKind? breakKind,
  PunchStatus status = PunchStatus.accepted,
  String workerId = 'w1',
  String? shiftId,
}) =>
    Punch(
      id: id ?? 'p${_seq++}',
      venueId: 'v1',
      workerId: workerId,
      eventId: 'e1',
      shiftId: shiftId,
      kind: kind,
      breakKind: breakKind,
      occurredAt: at,
      status: status,
    );

Punch clockIn(DateTime at, {String? id, String workerId = 'w1', String? shiftId}) =>
    punch(PunchKind.clockIn, at, id: id, workerId: workerId, shiftId: shiftId);

Punch clockOut(DateTime at, {String? id, String workerId = 'w1', String? shiftId}) =>
    punch(PunchKind.clockOut, at, id: id, workerId: workerId, shiftId: shiftId);

Punch breakStart(DateTime at, [BreakKind? kind = BreakKind.rest, String? id]) =>
    punch(PunchKind.breakStart, at, breakKind: kind, id: id);

Punch breakEnd(DateTime at, {String? id}) => punch(PunchKind.breakEnd, at, id: id);

WorkInterval iv(DateTime start, DateTime end) => WorkInterval(start, end);
