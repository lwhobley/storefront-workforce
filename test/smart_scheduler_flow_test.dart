import 'package:flutter_test/flutter_test.dart';
import 'package:storefront_workforce/data/demo_repository.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4, 1, 42);

  test('AI Smart Scheduler generates an optimized plan and applies it to the event board', () async {
    final repo = DemoWorkforceRepository(now: now);
    final session = await repo.signInWithPin('200002'); // Concessions Manager

    // Choose the first upcoming event
    final events = await repo.listEvents(session);
    final upcomingEvent = events.firstWhere((e) => e.callTime.isAfter(now));

    // Generate smart schedule plan with strict OT cap
    final plan = await repo.generateSmartSchedule(
      upcomingEvent.id,
      constraints: const SmartSchedulerConstraints(
        strictOvertimeCap: true,
        preferRegularStaff: true,
        rotateStorefronts: true,
        balanceWorkload: true,
      ),
    );

    expect(plan.eventId, upcomingEvent.id);
    expect(plan.totalOpenPositions, greaterThan(0));
    expect(plan.filledCount, greaterThan(0));
    expect(plan.projectedOvertimeHours, 0.0, reason: 'Strict cap must ensure zero overtime hours');
    expect(plan.proposals, isNotEmpty);

    // Verify all proposals have high fit scores and valid reasons
    for (final p in plan.proposals) {
      expect(p.fitScore, greaterThan(0));
      expect(p.reasons, isNotEmpty);
      expect(p.triggersOvertime, isFalse);
    }

    // Apply the smart schedule proposals
    final appliedCount = await repo.applySmartSchedule(upcomingEvent.id, plan.proposals);
    expect(appliedCount, plan.proposals.length);

    // Verify shifts on the board are now populated and no longer open
    final board = await repo.loadBoard(upcomingEvent.id);
    final assignedShifts = board.shifts.where((s) => s.workerId != null).toList();
    expect(assignedShifts, isNotEmpty);

    // Candidate scoring for a single shift
    final openShift = board.shifts.firstWhere((s) => s.isOpen, orElse: () => board.shifts.first);
    final candidates = await repo.candidatesWithAvailability(upcomingEvent.id, openShift.jobRoleCode);
    final scores = await repo.scoreCandidatesForShift(openShift, candidates);
    expect(scores.length, candidates.length);
  });
}
