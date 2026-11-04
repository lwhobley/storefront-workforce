/// Season-over-season turnover and retention, and certification compliance.
library;

import '../model/entities.dart';
import '../model/enums.dart';
import '../rules/certifications.dart';
import '../rules/local_time.dart';
import '../rules/venue_rules.dart';
import 'report_data.dart';
import 'seasons.dart';

/// One season's staff movement.
///
/// - **Staff**: people who clocked in at one or more events in the season.
/// - **Returning**: also worked the season before.
/// - **New**: never worked any earlier season in the records.
/// - **Retention**: share of last season's staff who worked this season; turnover is
///   the rest. Null for the first season on record.
/// - **New hires who came back**: of last season's new people, the share who worked
///   again this season (became repeat staff).
class RetentionRow {
  const RetentionRow({
    required this.season,
    required this.staff,
    required this.returning,
    required this.newStaff,
    required this.priorStaff,
    required this.priorNew,
    required this.priorNewReturned,
  });

  final int season;
  final int staff;
  final int returning;
  final int newStaff;

  /// Staff of the season before (0 when there is none on record).
  final int priorStaff;
  final int priorNew;
  final int priorNewReturned;

  double? get retention => priorStaff == 0 ? null : returning / priorStaff;
  double? get turnover => retention == null ? null : 1 - retention!;
  double? get newHireReturnRate => priorNew == 0 ? null : priorNewReturned / priorNew;
}

/// Rows oldest first, one per season from the earliest on record to the latest.
/// [onlyWorkers] limits the count (for example, to regular staff).
List<RetentionRow> retentionBySeason(List<WorkerSeason> rows, {Set<String>? onlyWorkers}) {
  final bySeason = <int, Set<String>>{};
  for (final r in rows) {
    if (r.eventsWorked <= 0) continue;
    if (onlyWorkers != null && !onlyWorkers.contains(r.workerId)) continue;
    bySeason.putIfAbsent(r.season, () => {}).add(r.workerId);
  }
  if (bySeason.isEmpty) return const [];
  final first = bySeason.keys.reduce((a, b) => a < b ? a : b);
  final last = bySeason.keys.reduce((a, b) => a > b ? a : b);
  final seenBefore = <String>{};
  final out = <RetentionRow>[];
  Set<String> priorNewSet = {};
  for (var s = first; s <= last; s++) {
    final staff = bySeason[s] ?? const <String>{};
    final prior = bySeason[s - 1] ?? const <String>{};
    final newSet = staff.difference(seenBefore);
    out.add(RetentionRow(
      season: s,
      staff: staff.length,
      returning: staff.intersection(prior).length,
      newStaff: s == first ? 0 : newSet.length,
      priorStaff: prior.length,
      priorNew: s - 1 == first ? 0 : priorNewSet.length,
      priorNewReturned: s - 1 == first ? 0 : priorNewSet.intersection(staff).length,
    ));
    priorNewSet = newSet;
    seenBefore.addAll(staff);
  }
  return out;
}

/// Seasons each person clocked in, from punches (the demo; the database has
/// report_worker_seasons() with the same rule). Voided punches do not count.
List<WorkerSeason> workerSeasonsFromPunches({
  required List<Punch> punches,
  required Map<String, Event> events,
  required String timeZone,
  int startMonth = Season.defaultStartMonth,
}) {
  final worked = <(String, int), Set<String>>{};
  for (final p in punches) {
    if (p.kind != PunchKind.clockIn || p.status == PunchStatus.voided || p.eventId == null) continue;
    final e = events[p.eventId];
    if (e == null || e.status == EventStatus.cancelled) continue;
    final season = Season.of(localDateOf(e.startTime, timeZone), startMonth: startMonth).startYear;
    worked.putIfAbsent((p.workerId, season), () => {}).add(e.id);
  }
  return [
    for (final e in worked.entries) WorkerSeason(workerId: e.key.$1, season: e.key.$2, eventsWorked: e.value.length),
  ]..sort((a, b) {
      final c = a.season.compareTo(b.season);
      return c != 0 ? c : a.workerId.compareTo(b.workerId);
    });
}

/// Certification compliance of active staff on [onDate].
class CertificationCompliance {
  const CertificationCompliance({
    required this.people,
    required this.compliant,
    required this.expiringSoon,
    required this.expiredOrMissing,
    required this.byType,
  });

  /// Active people trained for at least one role that needs a certification.
  final int people;

  /// Of those, people with every required certification current.
  final int compliant;

  /// Certifications of those people that expire within the window (still current).
  final List<(String workerId, WorkerCertification cert)> expiringSoon;

  /// People with a required certification expired or missing.
  final List<String> expiredOrMissing;

  /// Certification type -> (people who need it, people current).
  final Map<String, (int need, int current)> byType;

  double? get rate => people == 0 ? null : compliant / people;
}

CertificationCompliance certificationCompliance({
  required Iterable<Worker> workers,
  required List<JobRole> jobRoles,
  required DateTime onDate,
  CertificationRules rules = const CertificationRules(),
  int expiringWithinDays = 30,
}) {
  final roles = {for (final r in jobRoles) r.code: r};
  final day = DateTime.utc(onDate.year, onDate.month, onDate.day);
  final window = CertificationRules(enforcement: rules.enforcement, expiringSoonDays: expiringWithinDays);
  var people = 0, compliant = 0;
  final expiring = <(String, WorkerCertification)>[];
  final bad = <String>[];
  final byType = <String, (int, int)>{};
  for (final w in workers) {
    if (w.status != 'active') continue;
    final needed = <String>{
      for (final code in w.jobRoles) ...?roles[code]?.requiredCertifications,
    };
    if (needed.isEmpty) continue;
    people++;
    final check = checkCertifications(
      role: JobRole(venueId: '', code: '_', name: '', requiredCertifications: needed.toList()..sort()),
      certs: w.certifications,
      onDate: day,
      rules: window,
    );
    var ok = true;
    for (final r in check.results) {
      final current = r.state == CertificationState.ok || r.state == CertificationState.expiringSoon;
      if (!current) ok = false;
      final t = byType[r.typeCode] ?? (0, 0);
      byType[r.typeCode] = (t.$1 + 1, t.$2 + (current ? 1 : 0));
      if (r.state == CertificationState.expiringSoon && r.certification != null) expiring.add((w.id, r.certification!));
    }
    if (ok) {
      compliant++;
    } else {
      bad.add(w.id);
    }
  }
  expiring.sort((a, b) => a.$2.expiresOn!.compareTo(b.$2.expiresOn!));
  return CertificationCompliance(people: people, compliant: compliant, expiringSoon: expiring, expiredOrMissing: bad, byType: byType);
}
