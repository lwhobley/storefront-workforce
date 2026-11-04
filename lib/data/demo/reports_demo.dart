part of '../demo_repository.dart';

/// Demo (in-memory) implementation of [ReportsRepository]. Loads the same records the
/// Supabase version does: the range plus a week on each side, so workweek overtime is
/// complete, and pay information only for people who may see pay.
mixin _DemoReports on _DemoCore implements ReportsRepository {
  @override
  Future<ReportData> loadReportData(AppSession session, DateTime from, DateTime to) => _delay(() {
        _requirePerm(Perm.viewReports);
        final zone = _arena.venue.timeZone;
        final firstDay = startOfLocalDay(addCalendarDays(from, -7), zone);
        final lastDay = startOfLocalDay(addCalendarDays(to, 8), zone);
        bool inRange(DateTime instant) => !instant.isBefore(firstDay) && instant.isBefore(lastDay);

        final events = [for (final e in _events.values) if (inRange(e.startTime)) e];
        final eventIds = {for (final e in events) e.id};
        final shifts = [for (final s in _shifts.values) if (eventIds.contains(s.eventId)) s];

        return ReportData(
          events: events,
          workers: Map.of(_workers),
          eventStorefronts: [
            for (final e in events)
              for (final id in _openStorefronts[e.id] ?? const <String>{}) EventStorefront(eventId: e.id, storefrontId: id),
          ],
          needs: [for (final n in _needs) if (n.eventId != null && eventIds.contains(n.eventId)) n],
          shifts: shifts,
          punches: [for (final p in _punches) if (inRange(p.occurredAt)) p],
          changes: [for (final c in _changes) if (eventIds.contains(c.eventId)) c],
          // The sample data has no creation times for positions, so time to fill is skipped.
          shiftCreatedAt: const {},
          money: session.canVenueWide('view_pay') ? _reportMoney(events, eventIds) : null,
        );
      });

  ReportMoney _reportMoney(List<Event> events, Set<String> eventIds) {
    final pools = [for (final t in _tipPools.values) if (eventIds.contains(t.eventId)) t];
    return ReportMoney(
      payRules: PayRules.fromVenueSettings(_arena.venue.settings),
      payCodes: _pay.payCodes,
      rates: _pay.rates,
      differentials: _pay.differentials,
      billRates: _pay.billRates,
      npoAgreements: _pay.npoAgreements,
      npoPayouts: [for (final p in _npoPayouts.values) if (eventIds.contains(p.eventId)) p],
      tipPools: pools,
      tipAllocations: [for (final t in pools) ...?_allocations[t.id]],
      eventBudgetsCents: {
        for (final e in events)
          if (e.laborBudgetCents != null) e.id: e.laborBudgetCents!,
      },
    );
  }
}
