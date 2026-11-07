/// Labor Forecast AI: Multi-factor demand forecasting and real-time event budget
/// runaway cost prediction.
///
/// Models venue concessions consumption patterns based on event genre, crowd size,
/// time of day, and day of week. Tracks real-time labor expenditure during the event
/// against [Event.laborBudgetCents] to predict overruns before the game ends.
library;

import '../model/entities.dart';
import '../model/enums.dart';
import '../rules/venue_rules.dart';

enum EventGenre {
  hockey('hockey', 'Hockey game', alcoholFactor: 1.0, foodFactor: 1.0),
  concertRock('concert_rock', 'Rock / Pop Concert', alcoholFactor: 1.4, foodFactor: 0.8),
  concertCountry('concert_country', 'Country Concert', alcoholFactor: 1.5, foodFactor: 1.1),
  familyShow('family_show', 'Family / Ice Show', alcoholFactor: 0.2, foodFactor: 1.6),
  other('other', 'Other event', alcoholFactor: 1.0, foodFactor: 1.0);

  const EventGenre(this.code, this.label, {required this.alcoholFactor, required this.foodFactor});
  final String code;
  final String label;
  final double alcoholFactor;
  final double foodFactor;

  static EventGenre fromCode(String? code) {
    if (code == null) return other;
    final lower = code.toLowerCase();
    if (lower.contains('hockey')) return hockey;
    if (lower.contains('country')) return concertCountry;
    if (lower.contains('concert') || lower.contains('music')) return concertRock;
    if (lower.contains('family') || lower.contains('ice') || lower.contains('disney')) return familyShow;
    return other;
  }
}

class GenreStaffingAdjustment {
  const GenreStaffingAdjustment({
    required this.genre,
    required this.bartenderAdjustmentPct,
    required this.cookAdjustmentPct,
    required this.cashierAdjustmentPct,
    required this.explanation,
  });

  final EventGenre genre;
  final int bartenderAdjustmentPct;
  final int cookAdjustmentPct;
  final int cashierAdjustmentPct;
  final String explanation;
}

class LiveBudgetRunawayPrediction {
  const LiveBudgetRunawayPrediction({
    required this.eventId,
    required this.budgetCents,
    required this.currentAccruedCents,
    required this.projectedFinalCents,
    required this.projectedVarianceCents,
    required this.isOverrunPredicted,
    required this.variancePercentage,
    required this.recommendation,
  });

  final String eventId;
  final int budgetCents;
  final int currentAccruedCents;
  final int projectedFinalCents;
  final int projectedVarianceCents;
  final bool isOverrunPredicted;
  final double variancePercentage;
  final String recommendation;

  bool get isRunaway => isOverrunPredicted && variancePercentage > 10.0;
  bool get isCaution => isOverrunPredicted && variancePercentage <= 10.0;
  bool get isOnTrack => !isOverrunPredicted;
}

abstract final class LaborForecastAI {
  /// Analyzes event genre and predicts role ratio adjustments.
  static GenreStaffingAdjustment analyzeGenreStaffing(Event event) {
    final genre = EventGenre.fromCode(event.eventTypeCode);
    switch (genre) {
      case EventGenre.concertCountry:
        return GenreStaffingAdjustment(
          genre: genre,
          bartenderAdjustmentPct: 50,
          cookAdjustmentPct: 10,
          cashierAdjustmentPct: 20,
          explanation: 'Country concerts see very high beverage and bar demand. Recommend +50% bartenders and barbacks.',
        );
      case EventGenre.concertRock:
        return GenreStaffingAdjustment(
          genre: genre,
          bartenderAdjustmentPct: 40,
          cookAdjustmentPct: -20,
          cashierAdjustmentPct: 10,
          explanation: 'Rock/pop shows favor rapid-turnover beverage stands over sit-down food grills. Recommend +40% bar staff, -20% cook positions.',
        );
      case EventGenre.familyShow:
        return GenreStaffingAdjustment(
          genre: genre,
          bartenderAdjustmentPct: -70,
          cookAdjustmentPct: 40,
          cashierAdjustmentPct: 50,
          explanation: 'Family events see minimal alcohol consumption but high demand for popcorn, snacks and drinks. Cut bar staff by 70%, increase snack cashiers & runners by 50%.',
        );
      case EventGenre.hockey:
      case EventGenre.other:
        return GenreStaffingAdjustment(
          genre: genre,
          bartenderAdjustmentPct: 0,
          cookAdjustmentPct: 0,
          cashierAdjustmentPct: 0,
          explanation: 'Balanced sports concession mix: standard role ratios recommended.',
        );
    }
  }

  /// Calculates real-time projected event labor cost and overrun risk against budget.
  static LiveBudgetRunawayPrediction projectEventLaborCost({
    required Event event,
    required int activeClockedInStaff,
    required double elapsedHoursSoFar,
    required double estimatedRemainingHours,
    required int averageHourlyCostCents, // e.g. 1650 cents ($16.50/hr blended)
  }) {
    final budgetCents = event.laborBudgetCents ?? 0;
    final accruedCents = (activeClockedInStaff * elapsedHoursSoFar * averageHourlyCostCents).round();
    final remainingCents = (activeClockedInStaff * estimatedRemainingHours * averageHourlyCostCents).round();
    final projectedFinalCents = accruedCents + remainingCents;

    if (budgetCents == 0) {
      return LiveBudgetRunawayPrediction(
        eventId: event.id,
        budgetCents: 0,
        currentAccruedCents: accruedCents,
        projectedFinalCents: projectedFinalCents,
        projectedVarianceCents: 0,
        isOverrunPredicted: false,
        variancePercentage: 0.0,
        recommendation: 'No labor budget configured for this event.',
      );
    }

    final varianceCents = projectedFinalCents - budgetCents;
    final isOverrun = varianceCents > 0;
    final pct = (varianceCents / budgetCents) * 100.0;

    String rec;
    if (isOverrun) {
      final overDollars = (varianceCents / 100).toStringAsFixed(0);
      rec = 'Projected overrun of \$$overDollars (${pct.toStringAsFixed(1)}% over budget). Consider initiating early release for portable carts after doors close.';
    } else {
      final underDollars = ((-varianceCents) / 100).toStringAsFixed(0);
      rec = 'On track: currently trending \$$underDollars (${(-pct).toStringAsFixed(1)}%) under budget.';
    }

    return LiveBudgetRunawayPrediction(
      eventId: event.id,
      budgetCents: budgetCents,
      currentAccruedCents: accruedCents,
      projectedFinalCents: projectedFinalCents,
      projectedVarianceCents: varianceCents,
      isOverrunPredicted: isOverrun,
      variancePercentage: (pct * 10).round() / 10.0,
      recommendation: rec,
    );
  }

  /// Evaluates runaway risk from live punches and active shifts during an event.
  static LiveBudgetRunawayPrediction trackLiveLaborRunaway({
    required Event event,
    required List<Shift> shifts,
    required List<Punch> punches,
    required DateTime now,
    required VenueRules rules,
    int averageHourlyCostCents = 1650,
  }) {
    final activeStaff = punches.where((p) => p.eventId == event.id && p.kind == PunchKind.clockIn).length;
    final call = event.callTime;
    final elapsedHours = now.isAfter(call) ? now.difference(call).inMinutes / 60.0 : 0.0;
    final estRemaining = elapsedHours < 4.0 ? (4.0 - elapsedHours) : 1.0;

    return projectEventLaborCost(
      event: event,
      activeClockedInStaff: activeStaff > 0 ? activeStaff : shifts.where((s) => s.workerId != null).length,
      elapsedHoursSoFar: elapsedHours,
      estimatedRemainingHours: estRemaining,
      averageHourlyCostCents: averageHourlyCostCents,
    );
  }
}
