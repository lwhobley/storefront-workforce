/// Splitting a tip pool among the people who worked it.
///
/// Methods:
///   hours        - share by paid minutes.
///   role_points  - share by paid minutes x the role's points (pool.role_points).
///                  Roles not listed in role_points are not in the pool.
///   equal        - one equal share per eligible person who worked.
/// Eligible: role in PayRules.tipPool.eligibleRoles (and, for role_points, listed in
/// the pool's role_points), worker type in PayRules.tipPool.includeWorkerTypes, more
/// than 0 paid minutes, and not released before arriving.
/// Rounding: largest remainder to the cent, so the allocations add up to the pool
/// exactly; leftover cents go to the largest remainders, ties to the lower worker id.
/// $100.00 among three equal shares is 33.34 / 33.33 / 33.33.
library;

import '../model/entities.dart';
import '../model/enums.dart';
import '../rules/venue_rules.dart';
import 'money.dart';
import 'pay_models.dart';
import 'pay_problem.dart';
import 'pay_rules.dart';
import 'work_time.dart';

/// One person's time in a pool. A person may appear more than once (two shifts);
/// their eligible time is added up.
class TipParticipant {
  const TipParticipant({
    required this.workerId,
    required this.jobRoleCode,
    required this.paidMinutes,
    this.workerType = WorkerType.regular,
    this.releasedBeforeArrival = false,
  });

  final String workerId;
  final String jobRoleCode;
  final int paidMinutes;
  final WorkerType workerType;
  final bool releasedBeforeArrival;
}

enum TipExclusionReason {
  roleNotEligible,
  roleNotInPoolPoints,
  workerTypeNotIncluded,
  noPaidTime,
  releasedBeforeArrival,
}

class TipPoolExclusion {
  const TipPoolExclusion(this.workerId, this.jobRoleCode, this.reason);

  final String workerId;
  final String jobRoleCode;
  final TipExclusionReason reason;

  @override
  String toString() => 'TipPoolExclusion($workerId, $jobRoleCode, ${reason.name})';
}

class TipPoolResult {
  const TipPoolResult({required this.pool, required this.allocations, required this.excluded, required this.problems});

  final TipPool pool;

  /// Sorted by worker id. Sums to the pool amount unless nobody was eligible.
  final List<TipAllocation> allocations;
  final List<TipPoolExclusion> excluded;
  final List<PayProblem> problems;

  int get distributedCents => allocations.fold(0, (s, a) => s + a.amountCents);

  TipAllocation? forWorker(String id) {
    for (final a in allocations) {
      if (a.workerId == id) return a;
    }
    return null;
  }
}

/// Splits [pool] among [participants].
TipPoolResult allocateTipPool({
  required TipPool pool,
  required List<TipParticipant> participants,
  PayRules payRules = PayRules.texasDefaults,
}) {
  const methods = {'hours', 'role_points', 'equal'};
  if (!methods.contains(pool.method)) {
    throw ArgumentError.value(pool.method, 'pool.method', 'must be hours, role_points, or equal');
  }
  final eligibleRoles = payRules.tipPool.eligibleRoles.toSet();
  final types = payRules.tipPool.includeWorkerTypes.toSet();
  final excluded = <TipPoolExclusion>[];
  final minutes = <String, int>{};
  final weight = <String, int>{};
  final roles = <String, Set<String>>{};

  for (final p in participants) {
    TipExclusionReason? reason;
    if (!types.contains(p.workerType.code)) {
      reason = TipExclusionReason.workerTypeNotIncluded;
    } else if (!eligibleRoles.contains(p.jobRoleCode)) {
      reason = TipExclusionReason.roleNotEligible;
    } else if (pool.method == 'role_points' && (pool.rolePointsThousandths[p.jobRoleCode] ?? 0) <= 0) {
      reason = TipExclusionReason.roleNotInPoolPoints;
    } else if (p.releasedBeforeArrival) {
      reason = TipExclusionReason.releasedBeforeArrival;
    } else if (p.paidMinutes <= 0) {
      reason = TipExclusionReason.noPaidTime;
    }
    if (reason != null) {
      excluded.add(TipPoolExclusion(p.workerId, p.jobRoleCode, reason));
      continue;
    }
    minutes[p.workerId] = (minutes[p.workerId] ?? 0) + p.paidMinutes;
    roles.putIfAbsent(p.workerId, () => {}).add(p.jobRoleCode);
    final w = switch (pool.method) {
      'role_points' => p.paidMinutes * pool.rolePointsThousandths[p.jobRoleCode]!,
      'hours' => p.paidMinutes,
      _ => 0,
    };
    weight[p.workerId] = (weight[p.workerId] ?? 0) + w;
  }
  // Someone excluded for one shift but included for another is in the pool.
  excluded.removeWhere((e) => minutes.containsKey(e.workerId));

  final ids = minutes.keys.toList()..sort();
  final problems = <PayProblem>[];
  if (ids.isEmpty) {
    if (pool.amountCents > 0) {
      problems.add(
        PayProblem(
          kind: PayProblemKind.tipPoolNotDistributed,
          severity: PayProblemSeverity.blocking,
          message: 'Nobody eligible worked this pool; ${formatCents(pool.amountCents)} is not distributed.',
          eventId: pool.eventId,
        ),
      );
    }
    return TipPoolResult(pool: pool, allocations: const [], excluded: excluded, problems: problems);
  }

  final weights = [for (final id in ids) pool.method == 'equal' ? 1 : weight[id]!];
  final shares = splitByLargestRemainder(pool.amountCents, weights);
  final allocations = <TipAllocation>[];
  for (var i = 0; i < ids.length; i++) {
    final id = ids[i];
    final m = minutes[id]!;
    final points = switch (pool.method) {
      'role_points' => divRoundHalfUp(weight[id]!, m), // minutes-weighted points of the person's roles
      'equal' => 1000,
      _ => 0,
    };
    allocations.add(
      TipAllocation(
        poolId: pool.id,
        venueId: pool.venueId,
        workerId: id,
        hoursHundredths: minutesToHundredths(m),
        pointsThousandths: points,
        amountCents: shares[i],
      ),
    );
  }
  return TipPoolResult(pool: pool, allocations: List.unmodifiable(allocations), excluded: excluded, problems: problems);
}

/// Participants for [pool] from the event's shifts and punches: every assigned or
/// released shift at the pool's event (and storefront, unless the pool is
/// event-wide), with that shift's paid minutes.
List<TipParticipant> tipParticipantsFromShifts({
  required TipPool pool,
  required Map<String, Worker> workers,
  required List<Shift> shifts,
  required Map<String, List<Punch>> punchesByWorker,
  required String timeZone,
  BreakRules breakRules = const BreakRules(),
}) {
  final out = <TipParticipant>[];
  final relevant = [
    for (final s in shifts)
      if (s.eventId == pool.eventId &&
          s.workerId != null &&
          (pool.storefrontId == null || s.storefrontId == pool.storefrontId) &&
          (s.status == ShiftStatus.assigned || s.status == ShiftStatus.released))
        s,
  ];
  final byWorker = <String, List<Shift>>{};
  for (final s in relevant) {
    byWorker.putIfAbsent(s.workerId!, () => []).add(s);
  }
  for (final wid in byWorker.keys) {
    final work = attributeWork(
      workerId: wid,
      punches: punchesByWorker[wid] ?? const [],
      shifts: [
        for (final s in shifts)
          if (s.workerId == wid) s,
      ],
      events: const {},
      timeZone: timeZone,
      breakRules: breakRules,
    );
    for (final s in byWorker[wid]!) {
      final group = work.groups.where((g) => g.context.shiftId == s.id).firstOrNull;
      out.add(
        TipParticipant(
          workerId: wid,
          jobRoleCode: s.jobRoleCode,
          paidMinutes: work.minutesFor((c) => c.shiftId == s.id),
          workerType: workers[wid]?.type ?? WorkerType.regular,
          releasedBeforeArrival: s.status == ShiftStatus.released && !(group?.clockedIn ?? false),
        ),
      );
    }
  }
  return out;
}
