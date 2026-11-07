import 'package:workforce_core/workforce_core.dart';

import 'shift_market_models.dart';

export 'package:workforce_core/workforce_core.dart';
export 'shift_market_models.dart';

/// Phase 3: Open shifts, pickups, drops, swaps, availability, and their approvals.
///
/// Employee calls act for the signed-in person's own staff record; manager calls are
/// limited to storefronts where they can schedule. Every change is checked and logged
/// on the server (0012_shift_market.sql).
abstract interface class ShiftMarketRepository {
  // ---- Employee ----

  /// Open positions the signed-in person is trained for, at events they do not already
  /// work, with the reason when one is blocked.
  Future<List<OpenShift>> openShiftsForMe();

  /// Asks for an open position. Returns the request: pending, or approved when the venue
  /// lets pickups through without approval.
  Future<ShiftRequest> requestPickup(String shiftId, {String note = ''});

  /// Asks to give back one of your positions.
  Future<void> requestDrop(String shiftId, {String reason = ''});

  /// Coworkers who could take one of your positions (names only).
  Future<List<SwapCandidate>> swapCandidates(String shiftId);

  /// Offers one of your positions to a coworker; they accept, then a manager approves.
  Future<void> offerSwap(String shiftId, String toWorkerId, {String note = ''});

  /// The coworker accepts or declines an offer made to them.
  Future<void> respondSwap(String requestId, {required bool accept});

  /// Withdraws your own request while it is still open.
  Future<void> cancelShiftRequest(String requestId);

  /// Your requests and offers made to you, newest first.
  Future<List<ShiftRequest>> myShiftRequests();

  Future<MyAvailability> myAvailability();

  /// Sets your answer for an upcoming event; null clears it.
  Future<void> setEventAvailability(String eventId, AvailabilityStatus? status, {String note = ''});

  /// Adds dates you cannot work (or changes them, with [id]).
  Future<Blackout> setBlackout(DateTime startsOn, DateTime endsOn, {String note = '', String? id});
  Future<void> deleteBlackout(String id);

  // ---- Manager ----

  /// Requests at storefronts you schedule: open ones, or with [history] recent decided ones.
  Future<List<ShiftRequest>> reviewShiftRequests({bool history = false});

  /// Approves or denies a pending request. Accepted [warnings] need a [note].
  Future<void> decideShiftRequest(String requestId, {required bool approve, String note = '', List<String> warnings = const []});

  /// Assignment candidates with what each said about the event (available, unavailable,
  /// blackout).
  Future<List<MarketCandidate>> candidatesWithAvailability(String eventId, String jobRole);

  // ---- AI Smart Scheduling ----

  /// Generates an AI-optimized schedule plan for the given event, balancing availability,
  /// rotation of employees, and overtime prevention.
  Future<ScheduleOptimizationPlan> generateSmartSchedule(
    String eventId, {
    SmartSchedulerConstraints constraints = const SmartSchedulerConstraints(),
  });

  /// Evaluates an AI fit score for each candidate for an individual shift.
  Future<List<CandidateFitScore>> scoreCandidatesForShift(
    Shift shift,
    List<MarketCandidate> candidates, {
    SmartSchedulerConstraints constraints = const SmartSchedulerConstraints(),
  });

  /// Applies the proposed assignments from an optimization plan in batch.
  Future<int> applySmartSchedule(
    String eventId,
    List<ShiftAssignmentProposal> proposals,
  );
}
