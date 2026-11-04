/// Certification and minimum-age checks for a job role.
library;

import '../model/entities.dart';
import 'venue_rules.dart';

enum CertificationState { ok, expiringSoon, expired, missing }

class CertificationResult {
  const CertificationResult({required this.typeCode, required this.state, this.certification, this.daysUntilExpiry});

  final String typeCode;
  final CertificationState state;

  /// The certificate used for the check, if any.
  final WorkerCertification? certification;

  /// Days from the check date to the last valid day (0 = expires today, negative =
  /// expired). Null when it does not expire or is missing.
  final int? daysUntilExpiry;
}

class CertificationCheck {
  const CertificationCheck({required this.results, required this.enforcement});

  /// One per required certification, in the role's order.
  final List<CertificationResult> results;
  final CertificationEnforcement enforcement;

  /// A required certification is missing or expired and the venue blocks on that.
  bool get blocks =>
      enforcement == CertificationEnforcement.block &&
      results.any((r) => r.state == CertificationState.missing || r.state == CertificationState.expired);

  /// Problems that do not block: anything expiring soon, plus missing or expired
  /// ones when enforcement is warn.
  List<CertificationResult> get warnings => [
        for (final r in results)
          if (r.state == CertificationState.expiringSoon ||
              (enforcement == CertificationEnforcement.warn && r.state != CertificationState.ok))
            r,
      ];

  bool get allOk => results.every((r) => r.state == CertificationState.ok);
}

/// Checks [certs] against what [role] requires on the local calendar date [onDate].
///
/// `expiresOn` is the last valid day. A certificate issued after [onDate] does not
/// count. With several of the same type, one that never expires wins, otherwise
/// the latest expiry. Expiring soon means expiring within
/// [CertificationRules.expiringSoonDays] days after [onDate], including that day.
CertificationCheck checkCertifications({
  required JobRole role,
  required List<WorkerCertification> certs,
  required DateTime onDate,
  required CertificationRules rules,
}) {
  final day = _date(onDate);
  final results = <CertificationResult>[];
  final done = <String>{};
  for (final code in role.requiredCertifications) {
    if (!done.add(code)) continue;
    WorkerCertification? best;
    for (final c in certs) {
      if (c.typeCode != code) continue;
      final issued = c.issuedOn;
      if (issued != null && _date(issued).isAfter(day)) continue;
      if (best == null) {
        best = c;
      } else if (best.expiresOn != null &&
          (c.expiresOn == null || _date(c.expiresOn!).isAfter(_date(best.expiresOn!)))) {
        best = c;
      }
    }
    if (best == null) {
      results.add(CertificationResult(typeCode: code, state: CertificationState.missing));
      continue;
    }
    final expires = best.expiresOn;
    if (expires == null) {
      results.add(CertificationResult(typeCode: code, state: CertificationState.ok, certification: best));
      continue;
    }
    final days = _date(expires).difference(day).inDays;
    final state = days < 0
        ? CertificationState.expired
        : days <= rules.expiringSoonDays
            ? CertificationState.expiringSoon
            : CertificationState.ok;
    results.add(CertificationResult(typeCode: code, state: state, certification: best, daysUntilExpiry: days));
  }
  return CertificationCheck(results: List.unmodifiable(results), enforcement: rules.enforcement);
}

enum MinimumAgeStatus { notRequired, met, notMet, ageUnknown }

class MinimumAgeResult {
  const MinimumAgeResult({required this.status, this.requiredAge, this.age});

  final MinimumAgeStatus status;
  final int? requiredAge;
  final int? age;

  bool get blocks => status == MinimumAgeStatus.notMet;
}

/// Compares [age] with [JobRole.minimumAge].
MinimumAgeResult meetsMinimumAge(JobRole role, int? age) {
  final req = role.minimumAge;
  if (req == null) return MinimumAgeResult(status: MinimumAgeStatus.notRequired, age: age);
  if (age == null) return MinimumAgeResult(status: MinimumAgeStatus.ageUnknown, requiredAge: req);
  return MinimumAgeResult(
    status: age >= req ? MinimumAgeStatus.met : MinimumAgeStatus.notMet,
    requiredAge: req,
    age: age,
  );
}

DateTime _date(DateTime d) => DateTime.utc(d.year, d.month, d.day);
