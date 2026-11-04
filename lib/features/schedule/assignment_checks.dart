import 'package:workforce_core/workforce_core.dart';

import '../../data/models.dart';

/// What the app shows before a person is put in a position. Blocks stop the assignment;
/// warnings can be accepted with a reason, which is logged with the change.
class AssignmentCheck {
  const AssignmentCheck({this.blocks = const [], this.warnings = const []});

  final List<CheckItem> blocks;
  final List<CheckItem> warnings;

  bool get ok => blocks.isEmpty && warnings.isEmpty;
  List<String> get warningCodes => [for (final w in warnings) w.code];
}

class CheckItem {
  const CheckItem(this.code, this.message);

  final String code;
  final String message;
}

/// Mirrors the server's hard checks (the server enforces them again) and adds the
/// rules-engine warnings: minor hours and times, expiring certifications, untrained role.
AssignmentCheck checkAssignment({
  required BoardWorker candidate,
  required JobRole role,
  required Event event,
  required Shift shift,
  required VenueRules rules,
  required String timeZone,
  required String Function(String code) certName,
  /// The reason, when the person is flagged do-not-rehire. Blocks the assignment.
  String? doNotRehireReason,
}) {
  final blocks = <CheckItem>[];
  final warnings = <CheckItem>[];
  final age = candidate.ageOnEvent;
  final day = localDateOf(event.callTime, timeZone);

  if (doNotRehireReason != null) {
    blocks.add(CheckItem('do_not_rehire', 'Flagged do not rehire: $doNotRehireReason'));
  }

  final minAge = meetsMinimumAge(role, age);
  if (minAge.status == MinimumAgeStatus.notMet) {
    blocks.add(CheckItem('minimum_age', '${role.name} must be ${role.minimumAge} or older (age $age).'));
  } else if (minAge.status == MinimumAgeStatus.ageUnknown) {
    blocks.add(CheckItem('age_unknown', '${role.name} needs a birth date on file.'));
  }

  final certs = checkCertifications(role: role, certs: candidate.worker.certifications, onDate: day, rules: rules.certifications);
  for (final r in certs.results) {
    final name = certName(r.typeCode);
    switch (r.state) {
      case CertificationState.missing:
      case CertificationState.expired:
        final text = r.state == CertificationState.missing ? 'No $name on file.' : '$name expired.';
        (certs.blocks ? blocks : warnings).add(CheckItem('cert_${r.typeCode}', text));
      case CertificationState.expiringSoon:
        warnings.add(CheckItem('cert_expiring_${r.typeCode}', '$name expires in ${r.daysUntilExpiry ?? 0} days.'));
      case CertificationState.ok:
        break;
    }
  }

  if (!candidate.worker.jobRoles.contains(role.code)) {
    warnings.add(CheckItem('not_trained', 'Not marked as trained for ${role.name}.'));
  }

  final end = shift.scheduledEnd ?? (event.endTime ?? event.startTime.add(const Duration(hours: 3))).add(const Duration(minutes: 45));
  final minor = checkMinorShift(
    age: age,
    rules: rules.minors,
    jobRoleCode: role.code,
    start: shift.callTime,
    end: end,
    timeZone: timeZone,
    workweekStartDay: rules.overtime.workweekStartDay,
  );
  for (final v in minor.violations) {
    // Minimum working age and prohibited roles are hard limits; hour and time limits are
    // warnings so a manager can plan an early release.
    final hard = v.code == MinorViolationCode.underMinimumAge || v.code == MinorViolationCode.prohibitedRole;
    (hard ? blocks : warnings).add(CheckItem('minor_${v.code.code}', v.message));
  }
  return AssignmentCheck(blocks: blocks, warnings: warnings);
}
