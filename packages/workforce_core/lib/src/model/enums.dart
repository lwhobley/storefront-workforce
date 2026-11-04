/// Shared enumerations. Each value carries the code stored in the database.
library;

T _byCode<T extends Enum>(List<T> values, String? code, String Function(T) codeOf, T fallback) {
  for (final v in values) {
    if (codeOf(v) == code) return v;
  }
  return fallback;
}

enum WorkerType {
  regular('regular'),
  temp('temp'),
  npo('npo');

  const WorkerType(this.code);
  final String code;

  static WorkerType fromCode(String? code) =>
      _byCode(values, code, (v) => v.code, WorkerType.regular);
}

enum StorefrontKind {
  permanentStand('permanent_stand'),
  portableCart('portable_cart'),
  bar('bar'),
  kiosk('kiosk');

  const StorefrontKind(this.code);
  final String code;

  static StorefrontKind fromCode(String? code) =>
      _byCode(values, code, (v) => v.code, StorefrontKind.permanentStand);
}

enum EventStatus {
  scheduled('scheduled'),
  live('live'),
  completed('completed'),
  cancelled('cancelled');

  const EventStatus(this.code);
  final String code;

  static EventStatus fromCode(String? code) =>
      _byCode(values, code, (v) => v.code, EventStatus.scheduled);
}

enum ShiftStatus {
  open('open'),
  assigned('assigned'),
  released('released'),
  cancelled('cancelled');

  const ShiftStatus(this.code);
  final String code;

  static ShiftStatus fromCode(String? code) =>
      _byCode(values, code, (v) => v.code, ShiftStatus.open);
}

enum PunchKind {
  clockIn('clock_in'),
  clockOut('clock_out'),
  breakStart('break_start'),
  breakEnd('break_end');

  const PunchKind(this.code);
  final String code;

  static PunchKind fromCode(String? code) =>
      _byCode(values, code, (v) => v.code, PunchKind.clockIn);
}

enum BreakKind {
  meal('meal'),
  rest('rest');

  const BreakKind(this.code);
  final String code;

  static BreakKind fromCode(String? code) =>
      _byCode(values, code, (v) => v.code, BreakKind.rest);
}

enum PunchSource {
  phone('phone'),
  kiosk('kiosk'),
  manager('manager');

  const PunchSource(this.code);
  final String code;

  static PunchSource fromCode(String? code) =>
      _byCode(values, code, (v) => v.code, PunchSource.phone);
}

enum PunchStatus {
  accepted('accepted'),
  needsReview('needs_review'),
  voided('voided');

  const PunchStatus(this.code);
  final String code;

  static PunchStatus fromCode(String? code) =>
      _byCode(values, code, (v) => v.code, PunchStatus.accepted);
}
