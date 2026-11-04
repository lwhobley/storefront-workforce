import 'package:workforce_core/workforce_core.dart';

import '../../core/time/venue_time.dart';
import '../../data/models.dart';
import '../../data/pay_data.dart';
import '../../data/workforce_repository.dart';
import '../pay/pay_logic.dart';

/// Labor cost for each event, worked out with the same pay and billing calculations as
/// the Pay section, one pay period at a time. Events outside every pay period get no entry.
Future<Map<String, LaborCostReport>> laborCostByEvent({
  required WorkforceRepository repo,
  required AppSession session,
  required VenueContext venue,
  required PaySetup setup,
  required List<Event> events,
}) async {
  final zone = venue.venue.timeZone;
  final payRules = PayRules.fromVenueSettings(venue.venue.settings);
  final out = <String, LaborCostReport>{};
  for (final period in setup.periods) {
    final inPeriod = [
      for (final e in events)
        if (!venueDate(e.startTime, zone).isBefore(period.startsOn) && !venueDate(e.startTime, zone).isAfter(period.endsOn)) e,
    ];
    if (inPeriod.isEmpty) continue;

    final data = await repo.loadPeriodData(session, period);
    final payLines = data.isOpen ? computeEarnings(data, setup, venue).lines : data.approvedLines;
    final partners = await repo.loadPartnerData(session, period.startsOn, period.endsOn);
    final agencyLines = computeAgencyBilling(partners, setup, venue, period.startsOn, period.endsOn).lines;
    final byWorker = punchesByWorker(partners.punches);
    final members = partners.workers.values.toList();

    for (final e in inPeriod) {
      out[e.id] = calculateLaborCost(
        event: e,
        payRules: payRules,
        payLines: payLines,
        agencyLines: agencyLines,
        npoPayouts: partners.payouts,
        npoMinutes: npoMinutesByStorefront(
          event: e,
          members: members,
          shifts: partners.shifts,
          punchesByWorker: byWorker,
          timeZone: zone,
        ),
        payCodes: setup.payCodes,
        eventBudgetCents: e.laborBudgetCents,
      );
    }
  }
  return out;
}
