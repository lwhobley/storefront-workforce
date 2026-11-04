/// Which pay rate, differentials, bill rate, or NPO agreement applies.
///
/// Pay rate precedence (most specific wins):
///   worker + role + event type > worker + role > worker > role + event type > role >
///   venue default (all three null).
/// This is implemented as a score: worker match 4, role match 2, event type match 1.
/// That reproduces the order above and also places the shapes it does not name:
/// worker + event type (5) sits between worker + role (6) and worker (4), and event
/// type alone (1) sits between role (2) and the venue default (0).
///
/// A rate row applies only when every field it sets matches, and it is active on the
/// date (effective_from <= date <= effective_to, both inclusive; null effective_to is
/// open-ended). The date is the venue-local date the work happened, so a shift that
/// crosses midnight into a new rate uses the new rate after midnight. Ties at the same
/// score go to the latest effective_from, then the latest created_at, then the
/// greatest id, so the answer never depends on list order.
library;

import 'pay_models.dart';

int _score(String? worker, String? role, String? eventType) =>
    (worker != null ? 4 : 0) + (role != null ? 2 : 0) + (eventType != null ? 1 : 0);

bool _matches(String? field, String? value) => field == null || field == value;

/// Specificity of [rate] (0 venue default to 7 worker + role + event type).
int rateSpecificity(PayRate rate) => _score(rate.workerId, rate.jobRoleCode, rate.eventTypeCode);

int _compareRates(PayRate a, PayRate b) {
  var c = rateSpecificity(a).compareTo(rateSpecificity(b));
  if (c != 0) return c;
  c = a.effectiveFrom.compareTo(b.effectiveFrom);
  if (c != 0) return c;
  final ac = a.createdAt, bc = b.createdAt;
  if (ac != null && bc != null) {
    c = ac.compareTo(bc);
    if (c != 0) return c;
  } else if (ac != null || bc != null) {
    return ac != null ? 1 : -1;
  }
  return a.id.compareTo(b.id);
}

/// The most specific active rate for this work, or null when none applies (the
/// caller reports "no rate").
PayRate? resolveRate({
  required String workerId,
  required String? jobRoleCode,
  required String? eventTypeCode,
  required DateTime date,
  required Iterable<PayRate> rates,
}) {
  PayRate? best;
  for (final r in rates) {
    if (!r.isActiveOn(date)) continue;
    if (!_matches(r.workerId, workerId) ||
        !_matches(r.jobRoleCode, jobRoleCode) ||
        !_matches(r.eventTypeCode, eventTypeCode)) {
      continue;
    }
    if (best == null || _compareRates(r, best) > 0) best = r;
  }
  return best;
}

/// Every active differential that applies to this work. They are all added together
/// (a role-wide LEAD and a worker-specific LEAD both pay). Sorted by pay code, then id.
List<PayDifferential> resolveDifferentials({
  required String workerId,
  required String? jobRoleCode,
  required String? eventTypeCode,
  required DateTime date,
  required Iterable<PayDifferential> differentials,
}) {
  final out = [
    for (final d in differentials)
      if (d.isActiveOn(date) &&
          _matches(d.workerId, workerId) &&
          _matches(d.jobRoleCode, jobRoleCode) &&
          _matches(d.eventTypeCode, eventTypeCode))
        d,
  ]..sort((a, b) {
      final c = a.payCode.compareTo(b.payCode);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
  return out;
}

/// The agency's active bill rate for a role on [date]; latest effective_from wins,
/// then the greatest id.
AgencyBillRate? resolveBillRate({
  required String agencyId,
  required String jobRoleCode,
  required DateTime date,
  required Iterable<AgencyBillRate> billRates,
}) {
  AgencyBillRate? best;
  for (final r in billRates) {
    if (r.agencyId != agencyId || r.jobRoleCode != jobRoleCode || !r.isActiveOn(date)) continue;
    if (best == null) {
      best = r;
      continue;
    }
    final c = r.effectiveFrom.compareTo(best.effectiveFrom);
    if (c > 0 || (c == 0 && r.id.compareTo(best.id) > 0)) best = r;
  }
  return best;
}

/// The NPO agreement for a group on [date]: the group's own active agreement, else
/// the venue default (npo_group_id null). Latest effective_from wins, then greatest id.
NpoAgreement? resolveNpoAgreement({
  required String npoGroupId,
  required DateTime date,
  required Iterable<NpoAgreement> agreements,
}) {
  NpoAgreement? pick(bool Function(NpoAgreement) test) {
    NpoAgreement? best;
    for (final a in agreements) {
      if (!test(a) || !a.isActiveOn(date)) continue;
      if (best == null) {
        best = a;
        continue;
      }
      final c = a.effectiveFrom.compareTo(best.effectiveFrom);
      if (c > 0 || (c == 0 && a.id.compareTo(best.id) > 0)) best = a;
    }
    return best;
  }

  return pick((a) => a.npoGroupId == npoGroupId) ?? pick((a) => a.npoGroupId == null);
}
