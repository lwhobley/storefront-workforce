/// Problems found while calculating pay, for the manager to fix before approving.
library;

import '../rules/local_time.dart';

enum PayProblemSeverity {
  /// The numbers are known to be wrong or incomplete. Do not approve until fixed.
  blocking,

  /// Worth a look; the numbers follow the documented rule.
  warning,
}

enum PayProblemKind {
  /// No pay rate applies (the time is shown at rate null and $0.00).
  missingRate,

  /// A clock-in (or break) with no clock-out. The open stretch is not paid until a
  /// time correction closes it; closed stretches before it are paid.
  openClockIn,

  /// A punch still marked needs_review. It is counted as recorded.
  punchNeedsReview,

  /// A punch the timeline ignored (for example a clock-out while not clocked in).
  punchIgnored,

  /// Punches for an event where the person has no shift. Paid at their default role.
  noShiftForEvent,

  /// Punches with no event and no default role.
  noJobRole,

  /// The event of a shift or punch was not supplied, so its event type is unknown.
  unknownEvent,

  /// The same minutes were clocked under two shifts. They are paid once, under the
  /// shift that started first.
  overlappingTime,

  /// The pay period does not start on the workweek start day or is not whole weeks.
  periodNotAlignedToWorkweeks,

  /// A rate below the minimum wage for someone not on the tip credit.
  belowMinimumWage,

  /// A tip pool or its event was not supplied, so tips cannot be dated.
  tipPoolUnknown,

  /// Tips allocated to a temp or NPO member; they are not paid through payroll.
  tipsForNonPayrollWorker,

  /// No eligible people for a tip pool; the pool is not distributed.
  tipPoolNotDistributed,

  /// A temp with no agency.
  missingAgency,

  /// No bill rate for a temp's role.
  missingBillRate,

  /// No NPO agreement (group or venue default) for the event date.
  missingNpoAgreement,
}

class PayProblem {
  const PayProblem({
    required this.kind,
    required this.severity,
    required this.message,
    this.workerId,
    this.eventId,
    this.shiftId,
    this.punchId,
    this.workDate,
  });

  final PayProblemKind kind;
  final PayProblemSeverity severity;
  final String message;
  final String? workerId;
  final String? eventId;
  final String? shiftId;
  final String? punchId;
  final DateTime? workDate;

  bool get isBlocking => severity == PayProblemSeverity.blocking;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'severity': severity.name,
    'message': message,
    'worker_id': workerId,
    'event_id': eventId,
    'shift_id': shiftId,
    'punch_id': punchId,
    'work_date': workDate == null ? null : formatDate(workDate!),
  };

  @override
  String toString() => 'PayProblem(${kind.name}, ${severity.name}, $workerId: $message)';
}
