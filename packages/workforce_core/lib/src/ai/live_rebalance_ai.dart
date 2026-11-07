/// Live Rebalancing AI: Real-time concourse dynamic workforce rebalancing and emergency
/// no-show replacement recommendations.
///
/// Solves the live event night problem where one storefront is swamped while another
/// stand or portable cart is overstaffed, recommending instant, compliant transfers.
library;

import '../model/entities.dart';
import '../model/enums.dart';
import '../rules/certifications.dart';
import '../rules/local_time.dart';
import '../rules/venue_rules.dart';

/// A proposed transfer of a worker from one storefront to another during a live event.
class RebalanceRecommendation {
  const RebalanceRecommendation({
    required this.shiftId,
    required this.workerId,
    required this.workerName,
    required this.roleCode,
    required this.roleName,
    required this.fromStorefrontId,
    required this.fromStorefrontName,
    required this.toStorefrontId,
    required this.toStorefrontName,
    required this.reason,
    required this.priorityScore,
    required this.isCertified,
  });

  final String shiftId;
  final String workerId;
  final String workerName;
  final String roleCode;
  final String roleName;
  final String fromStorefrontId;
  final String fromStorefrontName;
  final String toStorefrontId;
  final String toStorefrontName;
  final String reason;

  /// Priority from 1 to 100 (higher means more urgent/impactful transfer).
  final int priorityScore;

  final bool isCertified;

  String get jobRoleCode => roleCode;
}

/// An off-duty worker recommended to fill an emergency no-show or late opening.
class EmergencyReplacementRecommendation {
  const EmergencyReplacementRecommendation({
    required this.workerId,
    required this.workerName,
    required this.workerType,
    required this.phone,
    required this.roleCode,
    required this.roleName,
    required this.currentWeeklyHours,
    required this.projectedWeeklyHours,
    required this.isAvailable,
    required this.reasons,
    required this.score,
  });

  final String workerId;
  final String workerName;
  final WorkerType workerType;
  final String phone;
  final String roleCode;
  final String roleName;
  final double currentWeeklyHours;
  final double projectedWeeklyHours;
  final bool isAvailable;
  final List<String> reasons;
  final int score;

  double get suitabilityScore => score / 100.0;
  double get weeklyHoursBeforeShift => currentWeeklyHours;
  Worker get worker => Worker(
        id: workerId,
        venueId: '',
        type: workerType,
        employeeNumber: '',
        firstName: workerName.split(' ').first,
        lastName: workerName.contains(' ') ? workerName.split(' ').sublist(1).join(' ') : '',
        phone: phone,
      );
}

abstract final class LiveRebalanceAI {
  /// Evaluates an active event board and identifies rebalance recommendations.
  static List<RebalanceRecommendation> recommendMoves({
    required Event event,
    required List<Shift> shifts,
    required List<StaffingNeed> needs,
    required Map<String, Storefront> storefronts,
    required Map<String, JobRole> jobRoles,
    required Map<String, Worker> workers,
    required VenueRules rules,
    required String timeZone,
    Set<String> onBreakWorkerIds = const {},
  }) {
    final recommendations = <RebalanceRecommendation>[];

    // Calculate needed vs staffed per storefront and role
    final neededMap = <String, Map<String, int>>{};
    for (final n in needs) {
      if (n.eventId != null && n.eventId != event.id) continue;
      neededMap.putIfAbsent(n.storefrontId, () => {})[n.jobRoleCode] = n.count;
    }

    final activeShiftsBySf = <String, List<Shift>>{};
    for (final s in shifts) {
      if (s.status == ShiftStatus.assigned && s.workerId != null) {
        activeShiftsBySf.putIfAbsent(s.storefrontId, () => []).add(s);
      }
    }

    // Identify deficit storefronts (where active staff < needed)
    final deficits = <(String sfId, String roleCode, int deficit)>[];
    for (final sfId in storefronts.keys) {
      final sfNeeds = neededMap[sfId] ?? const {};
      final sfShifts = activeShiftsBySf[sfId] ?? const [];
      for (final entry in sfNeeds.entries) {
        final roleCode = entry.key;
        final countNeeded = entry.value;
        final countActive = sfShifts.where((s) => s.jobRoleCode == roleCode).length;
        if (countActive < countNeeded) {
          deficits.add((sfId, roleCode, countNeeded - countActive));
        }
      }
    }

    if (deficits.isEmpty) return const [];

    // Identify surplus storefronts (where active staff > needed, or open storefronts with excess staff)
    final surpluses = <(String sfId, Shift shift, Worker worker)>[];
    for (final sfId in storefronts.keys) {
      final sfNeeds = neededMap[sfId] ?? const {};
      final sfShifts = activeShiftsBySf[sfId] ?? const [];
      for (final s in sfShifts) {
        if (onBreakWorkerIds.contains(s.workerId)) continue;
        final w = workers[s.workerId];
        if (w == null) continue;

        final countNeeded = sfNeeds[s.jobRoleCode] ?? 0;
        final countActive = sfShifts.where((sh) => sh.jobRoleCode == s.jobRoleCode).length;
        if (countActive > countNeeded) {
          surpluses.add((sfId, s, w));
        }
      }
    }

    // Match surplus workers to deficits
    final day = localDateOf(event.callTime, timeZone);
    final usedShiftIds = <String>{};

    for (final (targetSfId, neededRoleCode, _) in deficits) {
      final targetSf = storefronts[targetSfId];
      final targetRole = jobRoles[neededRoleCode] ??
          JobRole(venueId: event.venueId, code: neededRoleCode, name: neededRoleCode, requiredCertifications: const []);

      for (final (sourceSfId, shift, worker) in surpluses) {
        if (sourceSfId == targetSfId) continue;
        if (usedShiftIds.contains(shift.id)) continue;

        // Check training & certifications
        final trained = worker.jobRoles.contains(neededRoleCode) || shift.jobRoleCode == neededRoleCode;
        if (!trained) continue;

        final minAge = meetsMinimumAge(targetRole, worker.ageOn(day));
        if (minAge.status == MinimumAgeStatus.notMet) continue;

        final certs = checkCertifications(
          role: targetRole,
          certs: worker.certifications,
          onDate: day,
          rules: rules.certifications,
        );
        if (certs.blocks) continue;

        final sourceSf = storefronts[sourceSfId];

        usedShiftIds.add(shift.id);
        recommendations.add(RebalanceRecommendation(
          shiftId: shift.id,
          workerId: worker.id,
          workerName: worker.displayName,
          roleCode: neededRoleCode,
          roleName: targetRole.name,
          fromStorefrontId: sourceSfId,
          fromStorefrontName: sourceSf?.name ?? sourceSfId,
          toStorefrontId: targetSfId,
          toStorefrontName: targetSf?.name ?? targetSfId,
          reason: 'Transfers surplus ${targetRole.name} from ${sourceSf?.name ?? "another stand"} to meet target headcount.',
          priorityScore: 85,
          isCertified: true,
        ));
        break;
      }
    }

    return recommendations;
  }

  /// Identifies the best off-duty backup candidates for emergency replacement.
  static List<EmergencyReplacementRecommendation> findEmergencyReplacements({
    required Shift shift,
    required Event event,
    required JobRole role,
    required List<Worker> allActiveWorkers,
    required Set<String> scheduledWorkerIdsForEvent,
    required Map<String, double> currentWorkweekHours,
    required VenueRules rules,
    required String timeZone,
  }) {
    final candidates = <EmergencyReplacementRecommendation>[];
    final day = localDateOf(event.callTime, timeZone);
    final shiftDuration = 4.5; // estimated emergency shift hours

    for (final w in allActiveWorkers) {
      if (scheduledWorkerIdsForEvent.contains(w.id)) continue;

      // Minimum age check
      final minAge = meetsMinimumAge(role, w.ageOn(day));
      if (minAge.status == MinimumAgeStatus.notMet) continue;

      // Certifications
      final certs = checkCertifications(
        role: role,
        certs: w.certifications,
        onDate: day,
        rules: rules.certifications,
      );
      if (certs.blocks) continue;

      // Role training
      final trained = w.jobRoles.contains(role.code);

      // Overtime
      final currentHours = currentWorkweekHours[w.id] ?? 0.0;
      final projectedHours = currentHours + shiftDuration;
      final zeroOt = projectedHours <= 40.0;

      final reasons = <String>[];
      int score = 50;

      if (trained) {
        score += 20;
        reasons.add('Trained ${role.name}');
      }
      if (zeroOt) {
        score += 25;
        reasons.add('Zero OT risk (${projectedHours.toStringAsFixed(1)}h weekly)');
      } else {
        reasons.add('Near or in overtime (${projectedHours.toStringAsFixed(1)}h)');
      }
      if (w.type == WorkerType.regular) {
        score += 10;
        reasons.add('Regular staff');
      }

      candidates.add(EmergencyReplacementRecommendation(
        workerId: w.id,
        workerName: w.displayName,
        workerType: w.type,
        phone: w.phone,
        roleCode: role.code,
        roleName: role.name,
        currentWeeklyHours: currentHours,
        projectedWeeklyHours: projectedHours,
        isAvailable: true,
        reasons: reasons,
        score: score.clamp(1, 100),
      ));
    }

    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates.take(6).toList();
  }

  /// Convenience facade for live view emergency replacement lookup.
  static List<EmergencyReplacementRecommendation> recommendEmergencyReplacements({
    required Shift openShift,
    required Event event,
    required List<Worker> availableWorkers,
    required List<Shift> allWeeklyShifts,
    required VenueRules rules,
    required String timeZone,
    DateTime? onDate,
  }) {
    final scheduledIds = {
      for (final s in allWeeklyShifts)
        if (s.eventId == event.id && s.workerId != null) s.workerId!,
    };
    final hours = <String, double>{};
    for (final s in allWeeklyShifts) {
      if (s.workerId != null) {
        hours[s.workerId!] = (hours[s.workerId!] ?? 0) + 4.0;
      }
    }
    final targetRole = JobRole(
      venueId: event.venueId,
      code: openShift.jobRoleCode,
      name: openShift.jobRoleCode,
      requiredCertifications: const [],
    );

    return findEmergencyReplacements(
      shift: openShift,
      event: event,
      role: targetRole,
      allActiveWorkers: availableWorkers,
      scheduledWorkerIdsForEvent: scheduledIds,
      currentWorkweekHours: hours,
      rules: rules,
      timeZone: timeZone,
    );
  }
}
