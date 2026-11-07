/// Smart Scheduler: AI-assisted schedule optimization based on worker availability,
/// employee rotation, and overtime prevention.
///
/// Balances three core goals:
///   1. Overtime prevention: keeps workers strictly below the weekly overtime threshold
///      (40 hours, or a configurable safety buffer like 36 hours).
///   2. Availability: respects worker self-service availability declarations and blackout
///      dates, preferring workers who marked "preferred" or "available".
///   3. Rotation & Fairness: balances workload across staff so hours are shared equitably,
///      and provides storefront variety so workers rotate across different posts.
///
/// Hard constraints (enforced by the rules engine) always apply: minimum age, active
/// certifications, minor curfew hours, do-not-rehire flags, and one position per event.
library;

import 'dart:math' as math;

import '../model/entities.dart';
import '../model/enums.dart';
import '../rules/certifications.dart';
import '../rules/local_time.dart';
import '../rules/minors.dart';
import '../rules/venue_rules.dart';

/// Availability status of a candidate for an event.
enum CandidateAvailabilityStatus {
  preferred(0, 'Preferred'),
  available(1, 'Available'),
  noAnswer(2, 'No answer'),
  unavailable(3, 'Unavailable'),
  blackout(4, 'Blackout');

  const CandidateAvailabilityStatus(this.rank, this.label);
  final int rank;
  final String label;
}

/// Profile of a worker for scheduling, aggregating their availability, weekly hours,
/// and past rotation history.
class WorkerScheduleProfile {
  const WorkerScheduleProfile({
    required this.worker,
    this.ageOnEvent,
    this.availability = CandidateAvailabilityStatus.noAnswer,
    this.availabilityNote = '',
    this.currentWeekHours = 0.0,
    this.recentShiftsCount = 0,
    this.recentStorefrontIds = const [],
    this.lastShiftEndTime,
    this.reliabilityScore,
    this.doNotRehire = false,
    this.doNotRehireReason,
  });

  final Worker worker;
  final int? ageOnEvent;
  final CandidateAvailabilityStatus availability;
  final String availabilityNote;

  /// Paid + scheduled hours already accumulated in this workweek prior to this event.
  final double currentWeekHours;

  /// Shifts worked in the recent rolling period (e.g., past 14 or 30 days).
  final int recentShiftsCount;

  /// Storefront IDs worked in the most recent events (newest first).
  final List<String> recentStorefrontIds;

  /// Instant the worker's previous shift ended, for rest period checks.
  final DateTime? lastShiftEndTime;

  /// Reliability rating (0–100), when available.
  final int? reliabilityScore;

  /// Flagged do-not-rehire.
  final bool doNotRehire;
  final String? doNotRehireReason;

  String get workerId => worker.id;
  String get displayName => worker.displayName;
  WorkerType get workerType => worker.type;
}

/// Settings and constraint weights for schedule optimization.
class SmartSchedulerConstraints {
  const SmartSchedulerConstraints({
    this.maxWeeklyHours = 40.0,
    this.strictOvertimeCap = true,
    this.overtimeThresholdBuffer = 34.0,
    this.preferRegularStaff = true,
    this.balanceWorkload = true,
    this.rotateStorefronts = true,
    this.minRestHoursBetweenShifts = 10.0,
    this.considerReliability = true,
  });

  /// Hard or soft weekly cap (usually 40.0 hours).
  final double maxWeeklyHours;

  /// When true, rejects assigning someone if it would push them past [maxWeeklyHours].
  /// When false, penalizes overtime heavily but allows it if no one else is eligible.
  final bool strictOvertimeCap;

  /// Hours before overtime at which scores begin diminishing (e.g. 34.0 hours).
  final double overtimeThresholdBuffer;

  /// Prioritizes regular venue employees over temp agency or NPO workers.
  final bool preferRegularStaff;

  /// Prioritizes workers with fewer shifts in recent history to balance hours equitably.
  final bool balanceWorkload;

  /// Rewards placing workers at storefronts they have not worked at recently.
  final bool rotateStorefronts;

  /// Minimum rest hours between the end of a previous shift and this shift's call time.
  final double minRestHoursBetweenShifts;

  /// Factor in worker reliability rating for critical assignments.
  final bool considerReliability;
}

/// Evaluation result of how well a single worker fits a specific shift.
class CandidateFitScore {
  const CandidateFitScore({
    required this.workerId,
    required this.score,
    required this.eligible,
    required this.reasons,
    required this.warnings,
    required this.projectedWeeklyHours,
    required this.triggersOvertime,
    this.hardBlockReason,
  });

  final String workerId;

  /// Fit score from 0 (poor fit / ineligible) to 100 (ideal fit).
  final int score;

  /// Whether the candidate meets all hard compliance requirements and strict caps.
  final bool eligible;

  /// Positive reasons supporting the assignment.
  final List<String> reasons;

  /// Warnings or cautions (e.g. near overtime, minor hours, repeated stand).
  final List<String> warnings;

  /// Worker's projected weekly hours after completing this shift.
  final double projectedWeeklyHours;

  /// Whether this shift pushes the worker over 40.0 hours.
  final bool triggersOvertime;

  /// Detailed reason if hard-blocked.
  final String? hardBlockReason;
}

/// A proposed assignment for an open shift generated by the optimizer.
class ShiftAssignmentProposal {
  const ShiftAssignmentProposal({
    required this.shiftId,
    required this.storefrontId,
    required this.storefrontName,
    required this.jobRoleCode,
    required this.jobRoleName,
    required this.workerId,
    required this.workerName,
    required this.workerType,
    required this.fitScore,
    required this.reasons,
    required this.warnings,
    required this.projectedWeeklyHours,
    required this.triggersOvertime,
  });

  final String shiftId;
  final String storefrontId;
  final String storefrontName;
  final String jobRoleCode;
  final String jobRoleName;
  final String workerId;
  final String workerName;
  final WorkerType workerType;
  final int fitScore;
  final List<String> reasons;
  final List<String> warnings;
  final double projectedWeeklyHours;
  final bool triggersOvertime;
}

/// Complete optimization plan for an event with metrics.
class ScheduleOptimizationPlan {
  const ScheduleOptimizationPlan({
    required this.eventId,
    required this.proposals,
    required this.unfilledShiftIds,
    required this.totalOpenPositions,
    required this.filledCount,
    required this.overtimeHoursAvoided,
    required this.projectedOvertimeHours,
    required this.rotationScorePercentage,
  });

  final String eventId;
  final List<ShiftAssignmentProposal> proposals;
  final List<String> unfilledShiftIds;
  final int totalOpenPositions;
  final int filledCount;

  /// Estimated overtime hours avoided compared to naive scheduling.
  final double overtimeHoursAvoided;

  /// Overtime hours resulting from these proposals (should be 0.0 with strict cap).
  final double projectedOvertimeHours;

  /// Percentage of filled positions achieving good rotation (0–100%).
  final int rotationScorePercentage;

  bool get isFullyStaffed => unfilledShiftIds.isEmpty;
}

/// The core Smart Scheduler algorithm.
abstract final class SmartScheduler {
  /// Estimates shift duration in hours.
  static double estimateShiftHours(Event event, Shift shift) {
    if (shift.scheduledEnd != null) {
      final mins = shift.scheduledEnd!.difference(shift.callTime).inMinutes;
      if (mins > 0) return mins / 60.0;
    }
    final end = event.endTime ?? event.startTime.add(const Duration(hours: 3));
    final cleanUpEnd = end.add(const Duration(minutes: 45));
    final mins = cleanUpEnd.difference(shift.callTime).inMinutes;
    return math.max(1.0, mins / 60.0);
  }

  /// Evaluates how well a candidate worker fits a specific shift.
  static CandidateFitScore evaluateFit({
    required WorkerScheduleProfile profile,
    required Shift shift,
    required JobRole role,
    required Event event,
    required VenueRules rules,
    required String timeZone,
    SmartSchedulerConstraints constraints = const SmartSchedulerConstraints(),
    double? shiftHours,
  }) {
    final estimatedHours = shiftHours ?? estimateShiftHours(event, shift);
    final projectedHours = profile.currentWeekHours + estimatedHours;
    final triggersOt = projectedHours > constraints.maxWeeklyHours;

    // 1. Hard Compliance Checks
    if (profile.doNotRehire) {
      return CandidateFitScore(
        workerId: profile.workerId,
        score: 0,
        eligible: false,
        reasons: const [],
        warnings: const ['Do not rehire'],
        projectedWeeklyHours: projectedHours,
        triggersOvertime: triggersOt,
        hardBlockReason: 'Flagged do not rehire: ${profile.doNotRehireReason ?? ""}',
      );
    }

    final minAge = meetsMinimumAge(role, profile.ageOnEvent);
    if (minAge.status == MinimumAgeStatus.notMet) {
      return CandidateFitScore(
        workerId: profile.workerId,
        score: 0,
        eligible: false,
        reasons: const [],
        warnings: ['Age under ${role.minimumAge}'],
        projectedWeeklyHours: projectedHours,
        triggersOvertime: triggersOt,
        hardBlockReason: '${role.name} requires minimum age of ${role.minimumAge}',
      );
    }

    // Availability hard checks
    if (profile.availability == CandidateAvailabilityStatus.unavailable ||
        profile.availability == CandidateAvailabilityStatus.blackout) {
      return CandidateFitScore(
        workerId: profile.workerId,
        score: 0,
        eligible: false,
        reasons: const [],
        warnings: [profile.availability.label],
        projectedWeeklyHours: projectedHours,
        triggersOvertime: triggersOt,
        hardBlockReason: 'Worker marked ${profile.availability.label}',
      );
    }

    // Certifications
    final day = localDateOf(event.callTime, timeZone);
    final certs = checkCertifications(
      role: role,
      certs: profile.worker.certifications,
      onDate: day,
      rules: rules.certifications,
    );
    if (certs.blocks) {
      return CandidateFitScore(
        workerId: profile.workerId,
        score: 0,
        eligible: false,
        reasons: const [],
        warnings: const ['Missing required certifications'],
        projectedWeeklyHours: projectedHours,
        triggersOvertime: triggersOt,
        hardBlockReason: 'Missing required certifications for ${role.name}',
      );
    }

    // Minor laws (minimum age & prohibited roles are hard blocks)
    final minor = checkMinorShift(
      age: profile.ageOnEvent,
      rules: rules.minors,
      jobRoleCode: role.code,
      start: shift.callTime,
      end: shift.scheduledEnd ?? event.startTime.add(const Duration(hours: 3)),
      timeZone: timeZone,
      workweekStartDay: rules.overtime.workweekStartDay,
    );
    final hardMinor = minor.violations.any((v) =>
        v.code == MinorViolationCode.underMinimumAge || v.code == MinorViolationCode.prohibitedRole);
    if (hardMinor) {
      return CandidateFitScore(
        workerId: profile.workerId,
        score: 0,
        eligible: false,
        reasons: const [],
        warnings: const ['Minor prohibited role / hours'],
        projectedWeeklyHours: projectedHours,
        triggersOvertime: triggersOt,
        hardBlockReason: 'Minor working regulations block this assignment',
      );
    }

    // Overtime strict cap
    if (constraints.strictOvertimeCap && triggersOt) {
      return CandidateFitScore(
        workerId: profile.workerId,
        score: 0,
        eligible: false,
        reasons: const [],
        warnings: ['Exceeds weekly cap (${projectedHours.toStringAsFixed(1)}h > ${constraints.maxWeeklyHours.toStringAsFixed(0)}h)'],
        projectedWeeklyHours: projectedHours,
        triggersOvertime: true,
        hardBlockReason: 'Strict overtime cap: shift pushes worker to ${projectedHours.toStringAsFixed(1)}h',
      );
    }

    // 2. Soft Scoring Matrix (Total 100 points)
    final reasons = <String>[];
    final warnings = <String>[];
    double totalScore = 0.0;

    // A. Overtime & Hours Management (35 points max)
    if (projectedHours <= constraints.overtimeThresholdBuffer) {
      totalScore += 35.0;
      reasons.add('Zero OT risk (${projectedHours.toStringAsFixed(1)}h weekly)');
    } else if (projectedHours <= constraints.maxWeeklyHours) {
      // Linear scale from 35 down to 15 as it approaches 40h
      final diff = constraints.maxWeeklyHours - constraints.overtimeThresholdBuffer;
      final pos = (constraints.maxWeeklyHours - projectedHours) / (diff <= 0 ? 1 : diff);
      final pts = 15.0 + 20.0 * pos.clamp(0.0, 1.0);
      totalScore += pts;
      warnings.add('Near overtime (${projectedHours.toStringAsFixed(1)}h weekly)');
    } else {
      // Overtime occurred (only reached if strictOvertimeCap is false)
      totalScore += 2.0;
      warnings.add('Triggers overtime (+${(projectedHours - constraints.maxWeeklyHours).toStringAsFixed(1)}h OT)');
    }

    // B. Availability (25 points max)
    switch (profile.availability) {
      case CandidateAvailabilityStatus.preferred:
        totalScore += 25.0;
        reasons.add('Shift preferred');
      case CandidateAvailabilityStatus.available:
        totalScore += 22.0;
        reasons.add('Available');
      case CandidateAvailabilityStatus.noAnswer:
        totalScore += 12.0;
      case CandidateAvailabilityStatus.unavailable:
      case CandidateAvailabilityStatus.blackout:
        // Already caught above
        break;
    }

    // C. Rotation & Workload Fairness (25 points max)
    if (constraints.balanceWorkload) {
      // Prioritize workers who have worked fewer shifts recently (0–15 pts)
      final recentShifts = profile.recentShiftsCount;
      if (recentShifts == 0) {
        totalScore += 15.0;
        reasons.add('Fresh rotation (0 recent shifts)');
      } else if (recentShifts <= 2) {
        totalScore += 12.0;
        reasons.add('Balanced workload ($recentShifts recent shifts)');
      } else if (recentShifts <= 5) {
        totalScore += 7.0;
      } else {
        totalScore += 2.0;
        warnings.add('High recent workload ($recentShifts shifts)');
      }
    } else {
      totalScore += 15.0;
    }

    // Storefront Variety (0–10 pts)
    if (constraints.rotateStorefronts) {
      final wasAtSameStorefront = profile.recentStorefrontIds.isNotEmpty &&
          profile.recentStorefrontIds.first == shift.storefrontId;
      if (wasAtSameStorefront) {
        totalScore += 2.0;
        warnings.add('Worked same stand last event');
      } else {
        totalScore += 10.0;
        reasons.add('Rotates storefront');
      }
    } else {
      totalScore += 10.0;
    }

    // D. Qualifications & Rest (15 points max)
    // Trained for role (10 pts)
    if (profile.worker.jobRoles.contains(role.code)) {
      totalScore += 10.0;
      reasons.add('Trained ${role.name}');
    } else {
      totalScore += 2.0;
      warnings.add('Untrained for role');
    }

    // Rest turnaround between shifts (5 pts)
    if (profile.lastShiftEndTime != null) {
      final restHours = shift.callTime.difference(profile.lastShiftEndTime!).inMinutes / 60.0;
      if (restHours >= constraints.minRestHoursBetweenShifts) {
        totalScore += 5.0;
      } else {
        warnings.add('Short rest turnaround (${restHours.toStringAsFixed(1)}h < ${constraints.minRestHoursBetweenShifts.toStringAsFixed(0)}h)');
      }
    } else {
      totalScore += 5.0;
    }

    // Bonus / Adjustment for Regular Staff
    if (constraints.preferRegularStaff && profile.workerType == WorkerType.regular) {
      totalScore = math.min(100.0, totalScore + 3.0);
    }

    // Optional Reliability factor
    if (constraints.considerReliability && profile.reliabilityScore != null) {
      if (profile.reliabilityScore! >= 90) {
        totalScore = math.min(100.0, totalScore + 2.0);
      } else if (profile.reliabilityScore! < 70) {
        totalScore = math.max(0.0, totalScore - 5.0);
        warnings.add('Low reliability rating (${profile.reliabilityScore}%)');
      }
    }

    final finalScore = totalScore.round().clamp(1, 100);

    return CandidateFitScore(
      workerId: profile.workerId,
      score: finalScore,
      eligible: true,
      reasons: reasons,
      warnings: warnings,
      projectedWeeklyHours: projectedHours,
      triggersOvertime: triggersOt,
    );
  }

  /// Solves the multi-shift assignment problem for an entire event.
  static ScheduleOptimizationPlan optimize({
    required Event event,
    required List<Shift> shifts,
    required List<WorkerScheduleProfile> candidateProfiles,
    required Map<String, Storefront> storefronts,
    required Map<String, JobRole> jobRoles,
    required VenueRules rules,
    required String timeZone,
    SmartSchedulerConstraints constraints = const SmartSchedulerConstraints(),
  }) {
    final openShifts = shifts.where((s) => s.isOpen).toList();
    if (openShifts.isEmpty) {
      return ScheduleOptimizationPlan(
        eventId: event.id,
        proposals: const [],
        unfilledShiftIds: const [],
        totalOpenPositions: 0,
        filledCount: 0,
        overtimeHoursAvoided: 0.0,
        projectedOvertimeHours: 0.0,
        rotationScorePercentage: 100,
      );
    }

    // Pre-track workers already assigned to this event
    final assignedWorkerIds = <String>{
      for (final s in shifts)
        if (s.workerId != null && s.workerId!.isNotEmpty) s.workerId!,
    };

    // Dynamic state tracker for candidate profiles during assignment
    final dynamicHours = <String, double>{
      for (final p in candidateProfiles) p.workerId: p.currentWeekHours,
    };

    // Sort open shifts by Minimum Remaining Values (MRV) / scarcity:
    // Roles with specific certs (Bartender) or senior posts (Lead) go first.
    openShifts.sort((a, b) {
      final roleA = jobRoles[a.jobRoleCode];
      final roleB = jobRoles[b.jobRoleCode];
      final certsA = roleA?.requiredCertifications.length ?? 0;
      final certsB = roleB?.requiredCertifications.length ?? 0;
      if (certsA != certsB) return certsB.compareTo(certsA);
      final ageA = roleA?.minimumAge ?? 0;
      final ageB = roleB?.minimumAge ?? 0;
      return ageB.compareTo(ageA);
    });

    final proposals = <ShiftAssignmentProposal>[];
    final unfilledShiftIds = <String>[];
    double baselineOvertimeRiskHours = 0.0;
    double actualOvertimeHours = 0.0;
    int rotatedCount = 0;

    for (final shift in openShifts) {
      final sf = storefronts[shift.storefrontId];
      final role = jobRoles[shift.jobRoleCode] ??
          JobRole(venueId: event.venueId, code: shift.jobRoleCode, name: shift.jobRoleCode, requiredCertifications: const []);
      final shiftHours = estimateShiftHours(event, shift);

      CandidateFitScore? bestFit;
      WorkerScheduleProfile? bestCandidate;

      for (final profile in candidateProfiles) {
        if (assignedWorkerIds.contains(profile.workerId)) continue;

        // Current profile with dynamically updated weekly hours
        final updatedProfile = WorkerScheduleProfile(
          worker: profile.worker,
          ageOnEvent: profile.ageOnEvent,
          availability: profile.availability,
          availabilityNote: profile.availabilityNote,
          currentWeekHours: dynamicHours[profile.workerId] ?? profile.currentWeekHours,
          recentShiftsCount: profile.recentShiftsCount,
          recentStorefrontIds: profile.recentStorefrontIds,
          lastShiftEndTime: profile.lastShiftEndTime,
          reliabilityScore: profile.reliabilityScore,
          doNotRehire: profile.doNotRehire,
          doNotRehireReason: profile.doNotRehireReason,
        );

        final fit = evaluateFit(
          profile: updatedProfile,
          shift: shift,
          role: role,
          event: event,
          rules: rules,
          timeZone: timeZone,
          constraints: constraints,
          shiftHours: shiftHours,
        );

        if (!fit.eligible) continue;

        if (bestFit == null || fit.score > bestFit.score) {
          bestFit = fit;
          bestCandidate = profile;
        }
      }

      if (bestFit != null && bestCandidate != null) {
        // Record assignment
        assignedWorkerIds.add(bestCandidate.workerId);
        final current = dynamicHours[bestCandidate.workerId] ?? 0.0;
        dynamicHours[bestCandidate.workerId] = current + shiftHours;

        if (bestFit.triggersOvertime) {
          actualOvertimeHours += math.max(0.0, bestFit.projectedWeeklyHours - constraints.maxWeeklyHours);
        }

        final wasAtSameStorefront = bestCandidate.recentStorefrontIds.isNotEmpty &&
            bestCandidate.recentStorefrontIds.first == shift.storefrontId;
        if (!wasAtSameStorefront || bestCandidate.recentShiftsCount <= 2) {
          rotatedCount++;
        }

        proposals.add(ShiftAssignmentProposal(
          shiftId: shift.id,
          storefrontId: shift.storefrontId,
          storefrontName: sf?.name ?? shift.storefrontId,
          jobRoleCode: shift.jobRoleCode,
          jobRoleName: role.name,
          workerId: bestCandidate.workerId,
          workerName: bestCandidate.displayName,
          workerType: bestCandidate.workerType,
          fitScore: bestFit.score,
          reasons: bestFit.reasons,
          warnings: bestFit.warnings,
          projectedWeeklyHours: bestFit.projectedWeeklyHours,
          triggersOvertime: bestFit.triggersOvertime,
        ));
      } else {
        unfilledShiftIds.add(shift.id);
      }
    }

    // Estimate baseline overtime avoided: calculate how many candidates would have breached 40h
    // under naive assignment
    for (final p in candidateProfiles) {
      if (p.currentWeekHours > 32.0 && p.currentWeekHours <= 40.0) {
        baselineOvertimeRiskHours += math.max(0.0, (p.currentWeekHours + 4.5) - 40.0);
      }
    }

    final overtimeAvoided = math.max(0.0, baselineOvertimeRiskHours - actualOvertimeHours);
    final rotationPct = proposals.isEmpty ? 100 : ((rotatedCount / proposals.length) * 100).round();

    return ScheduleOptimizationPlan(
      eventId: event.id,
      proposals: proposals,
      unfilledShiftIds: unfilledShiftIds,
      totalOpenPositions: openShifts.length,
      filledCount: proposals.length,
      overtimeHoursAvoided: (overtimeAvoided * 10).round() / 10.0,
      projectedOvertimeHours: (actualOvertimeHours * 10).round() / 10.0,
      rotationScorePercentage: rotationPct,
    );
  }
}
