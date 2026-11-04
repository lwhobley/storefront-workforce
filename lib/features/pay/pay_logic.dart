import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../data/models.dart';
import '../../data/pay_data.dart';

Map<String, List<Punch>> punchesByWorker(Iterable<Punch> punches) {
  final out = <String, List<Punch>>{};
  for (final p in punches) {
    out.putIfAbsent(p.workerId, () => []).add(p);
  }
  return out;
}

Map<String, List<Shift>> shiftsByWorker(Iterable<Shift> shifts) {
  final out = <String, List<Shift>>{};
  for (final s in shifts) {
    if (s.workerId != null) out.putIfAbsent(s.workerId!, () => []).add(s);
  }
  return out;
}

List<WorkerPayInput> payInputs(Map<String, Worker> workers, List<Punch> punches, List<Shift> shifts) {
  final p = punchesByWorker(punches);
  final s = shiftsByWorker(shifts);
  return [
    for (final w in workers.values)
      if (p.containsKey(w.id) || s.containsKey(w.id)) WorkerPayInput(worker: w, punches: p[w.id] ?? const [], shifts: s[w.id] ?? const []),
  ];
}

/// Calculates the period's payroll lines with the shared pay engine.
EarningsResult computeEarnings(PeriodData d, PaySetup setup, VenueContext venue) {
  return calculateEarnings(
    timeZone: venue.venue.timeZone,
    venueRules: venue.rules,
    payRules: PayRules.fromVenueSettings(venue.venue.settings),
    period: d.period,
    workers: payInputs(d.workers, d.punches, d.shifts),
    events: d.events,
    rates: setup.rates,
    differentials: setup.differentials,
    tipPools: d.tipPools,
    tipAllocations: d.tipAllocations,
    jobRoles: {for (final r in venue.jobRoles) r.code: r},
  );
}

/// Tip pools for events that start inside the period (the loaded data reaches a week past
/// each end, for overtime).
List<TipPool> poolsInPeriod(PeriodData d, String timeZone) {
  final start = startOfLocalDay(d.period.startsOn, timeZone);
  final end = startOfLocalDay(addCalendarDays(d.period.endsOn, 1), timeZone);
  return [
    for (final t in d.tipPools)
      if (d.events[t.eventId] case final e? when !e.startTime.isBefore(start) && e.startTime.isBefore(end)) t,
  ];
}

/// Pools in the period that have not been split among the people who worked.
List<TipPool> unsplitPools(PeriodData d, String timeZone) =>
    [for (final t in poolsInPeriod(d, timeZone)) if (!d.tipAllocations.any((a) => a.poolId == t.id)) t];

/// Temp agency invoices for a date range.
AgencyBillingResult computeAgencyBilling(PartnerData d, PaySetup setup, VenueContext venue, DateTime from, DateTime to) {
  return calculateAgencyBilling(
    timeZone: venue.venue.timeZone,
    overtimeRules: venue.rules.overtime,
    from: from,
    to: to,
    temps: payInputs({for (final w in d.workers.values) if (w.type == WorkerType.temp) w.id: w}, d.punches, d.shifts),
    events: d.events,
    billRates: setup.billRates,
    breakRules: venue.rules.breaks,
  );
}

/// One NPO group's payout for one event, calculated fresh from time records.
NpoPayoutResult computeNpoPayout(PartnerData d, PaySetup setup, VenueContext venue, Event event, String groupId,
    {int adjustmentCents = 0, String adjustmentReason = ''}) {
  return calculateNpoPayout(
    event: event,
    npoGroupId: groupId,
    members: [for (final w in d.workers.values) if (w.npoGroupId == groupId) w],
    shifts: [for (final s in d.shifts) if (s.eventId == event.id) s],
    punchesByWorker: punchesByWorker(d.punches.where((p) => p.eventId == event.id)),
    agreements: setup.npoAgreements,
    timeZone: venue.venue.timeZone,
    breakRules: venue.rules.breaks,
    adjustmentCents: adjustmentCents,
    adjustmentReason: adjustmentReason,
  );
}

/// Splits a tip pool among the eligible people who worked that storefront at that event.
TipPoolResult computeTipSplit(TipPool pool, PeriodData d, VenueContext venue) {
  final eventShifts = [for (final s in d.shifts) if (s.eventId == pool.eventId) s];
  final participants = tipParticipantsFromShifts(
    pool: pool,
    workers: d.workers,
    shifts: eventShifts,
    punchesByWorker: punchesByWorker(d.punches.where((p) => p.eventId == pool.eventId)),
    timeZone: venue.venue.timeZone,
    breakRules: venue.rules.breaks,
  );
  return allocateTipPool(pool: pool, participants: participants, payRules: PayRules.fromVenueSettings(venue.venue.settings));
}

final _currency = NumberFormat.currency(locale: 'en_US', symbol: r'$');

/// Display only; stored and exported amounts use exact cents.
String money(int cents) => _currency.format(cents / 100);
String hours(int hundredths) => formatHundredths(hundredths);
