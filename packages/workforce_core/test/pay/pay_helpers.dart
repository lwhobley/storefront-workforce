import 'package:workforce_core/workforce_core.dart';

const tz = 'America/Chicago';

/// UTC instant of a Chicago wall-clock time.
DateTime ct(int y, int m, int d, [int h = 0, int min = 0]) => localToUtc(tz, y, m, d, h, min);

/// A calendar date.
DateTime day(int y, int m, int d) => DateTime.utc(y, m, d);

Worker worker(
  String id, {
  WorkerType type = WorkerType.regular,
  String first = 'Pat',
  String? last,
  String code = '',
  String? agencyId,
  String? npoGroupId,
  List<String> roles = const ['cashier'],
}) => Worker(
  id: id,
  venueId: 'v1',
  type: type,
  employeeNumber: id,
  firstName: first,
  lastName: last ?? 'Worker-$id',
  paycomEmployeeCode: code,
  agencyId: agencyId,
  npoGroupId: npoGroupId,
  jobRoles: roles,
);

Event event(String id, DateTime start, {String type = 'game', int expected = 0, int? actual}) => Event(
  id: id,
  venueId: 'v1',
  name: 'Event $id',
  eventTypeCode: type,
  startTime: start,
  callTime: start.subtract(const Duration(hours: 3)),
  doorsTime: start.subtract(const Duration(hours: 1)),
  expectedAttendance: expected,
  actualAttendance: actual,
);

Shift shift(
  String id, {
  required String workerId,
  required String eventId,
  required DateTime call,
  String storefrontId = 'sf1',
  String role = 'cashier',
  ShiftStatus status = ShiftStatus.assigned,
}) => Shift(
  id: id,
  venueId: 'v1',
  eventId: eventId,
  storefrontId: storefrontId,
  jobRoleCode: role,
  workerId: workerId,
  callTime: call,
  status: status,
);

var _seq = 0;

Punch punch(
  String workerId,
  PunchKind kind,
  DateTime at, {
  String? eventId,
  String? shiftId,
  BreakKind? breakKind,
  PunchStatus status = PunchStatus.accepted,
  String? id,
}) => Punch(
  id: id ?? 'p${_seq++}',
  venueId: 'v1',
  workerId: workerId,
  eventId: eventId,
  shiftId: shiftId,
  kind: kind,
  breakKind: breakKind,
  occurredAt: at,
  status: status,
);

/// Clock in, optional breaks (start, end, kind), clock out.
List<Punch> worked(
  String workerId,
  DateTime inAt,
  DateTime outAt, {
  String? eventId,
  String? shiftId,
  List<(DateTime, DateTime, BreakKind)> breaks = const [],
}) => [
  punch(workerId, PunchKind.clockIn, inAt, eventId: eventId, shiftId: shiftId),
  for (final b in breaks) ...[
    punch(workerId, PunchKind.breakStart, b.$1, eventId: eventId, shiftId: shiftId, breakKind: b.$3),
    punch(workerId, PunchKind.breakEnd, b.$2, eventId: eventId, shiftId: shiftId),
  ],
  punch(workerId, PunchKind.clockOut, outAt, eventId: eventId, shiftId: shiftId),
];

PayRate rate(
  String id,
  int cents, {
  String? workerId,
  String? role,
  String? eventType,
  DateTime? from,
  DateTime? to,
  DateTime? createdAt,
}) => PayRate(
  id: id,
  venueId: 'v1',
  workerId: workerId,
  jobRoleCode: role,
  eventTypeCode: eventType,
  hourlyRateCents: cents,
  effectiveFrom: from ?? day(2026, 1, 1),
  effectiveTo: to,
  createdAt: createdAt,
);

/// Venue rules with the Texas defaults (40h weekly, Monday workweek, biweekly from
/// Monday 2026-01-05, rest breaks paid and meals unpaid).
const texas = VenueRules.texasDefaults;

/// Biweekly period Mon Nov 9 to Sun Nov 22, 2026 (all CST, no DST change).
final novPeriod = PayPeriod(startsOn: day(2026, 11, 9), endsOn: day(2026, 11, 22), payDate: day(2026, 11, 27));

int sumCents(Iterable<PayLine> lines) => lines.fold(0, (s, l) => s + l.amountCents);

List<PayLine> linesOf(Iterable<PayLine> lines, String code) => [
  for (final l in lines)
    if (l.payCode == code) l,
];
