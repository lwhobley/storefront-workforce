/// The raw records the KPI reports are calculated from. Loaded by the app (Supabase or
/// demo) for a date range plus a week before it, so workweek overtime is complete.
library;

import '../model/entities.dart';
import '../pay/pay_models.dart';
import '../pay/pay_rules.dart';

class ReportData {
  const ReportData({
    required this.events,
    required this.workers,
    this.eventStorefronts = const [],
    this.needs = const [],
    this.shifts = const [],
    this.punches = const [],
    this.changes = const [],
    this.shiftCreatedAt = const {},
    this.money,
  });

  /// Events in the range and the week around it.
  final List<Event> events;

  /// Everyone who could appear (current and former staff), with certifications.
  final Map<String, Worker> workers;
  final List<EventStorefront> eventStorefronts;

  /// Event staffing needs (StaffingNeed.eventId set).
  final List<StaffingNeed> needs;

  /// Every shift of those events, any status.
  final List<Shift> shifts;

  /// Punches in the range and the week before (any status; voided are ignored).
  final List<Punch> punches;

  /// Assignment changes of those events.
  final List<AssignmentChange> changes;

  /// When each position was created, for time to fill. Missing ids are skipped.
  final Map<String, DateTime> shiftCreatedAt;

  /// Pay information, only for people who may see pay (view_pay, venue-wide).
  final ReportMoney? money;
}

/// Pay setup and pay records for labor cost, tips, and NPO amounts.
class ReportMoney {
  const ReportMoney({
    this.payRules = PayRules.texasDefaults,
    this.payCodes = const [],
    this.rates = const [],
    this.differentials = const [],
    this.billRates = const [],
    this.npoAgreements = const [],
    this.npoPayouts = const [],
    this.tipPools = const [],
    this.tipAllocations = const [],
    this.eventBudgetsCents = const {},
    this.storefrontBudgetsCents = const {},
  });

  final PayRules payRules;
  final List<PayCode> payCodes;
  final List<PayRate> rates;
  final List<PayDifferential> differentials;
  final List<AgencyBillRate> billRates;
  final List<NpoAgreement> npoAgreements;

  /// Stored payouts; events without one are estimated from time records.
  final List<NpoPayout> npoPayouts;
  final List<TipPool> tipPools;

  /// Saved splits; pools without a split are estimated the way the Pay screen splits them.
  final List<TipAllocation> tipAllocations;

  /// events.labor_budget by event id (cents).
  final Map<String, int> eventBudgetsCents;

  /// event_storefronts.labor_budget: event id -> storefront id -> cents.
  final Map<String, Map<String, int>> storefrontBudgetsCents;
}

/// How many events one person worked (clocked in at) in one season, for turnover and
/// retention. [season] is the season's start year.
class WorkerSeason {
  const WorkerSeason({required this.workerId, required this.season, required this.eventsWorked});

  final String workerId;
  final int season;
  final int eventsWorked;

  factory WorkerSeason.fromJson(Map<String, dynamic> j) => WorkerSeason(
        workerId: j['worker_id'] as String,
        season: (j['season'] as num).toInt(),
        eventsWorked: (j['events_worked'] as num).toInt(),
      );
}
