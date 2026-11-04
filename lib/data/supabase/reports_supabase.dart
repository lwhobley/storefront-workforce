part of '../supabase_repository.dart';

/// Supabase implementation of [ReportsRepository]. Row-level security already limits
/// every table to the venue, and pay information is only asked for when the person may
/// see pay.
mixin _SupabaseReports on _SupabaseCore implements ReportsRepository {
  @override
  Future<ReportData> loadReportData(AppSession session, DateTime from, DateTime to) => _guard(() async {
        final venueId = session.venue.id;
        final w = _window(session.venue.timeZone, from, to);
        final f = w.from.toIso8601String(), t = w.to.toIso8601String();

        final eventRows = await client.from('events').select().eq('venue_id', venueId).gte('start_time', f).lt('start_time', t);
        final events = [for (final r in eventRows) Event.fromJson(r)];
        final eventIds = [for (final e in events) e.id];
        if (eventIds.isEmpty) return ReportData(events: const [], workers: await _workers(venueId));

        final shiftRows = await _all((a, b) =>
            client.from('shifts').select().inFilter('event_id', eventIds).order('id', ascending: true).range(a, b));
        final punchRows = await _all((a, b) => client.from('punches').select().eq('venue_id', venueId)
            .gte('occurred_at', f).lt('occurred_at', t).order('id', ascending: true).range(a, b));
        final changeRows = await _all((a, b) =>
            client.from('assignment_changes').select().inFilter('event_id', eventIds).order('id', ascending: true).range(a, b));
        final needRows = await client.from('event_staffing_needs').select().inFilter('event_id', eventIds);
        final storefrontRows = await client.from('event_storefronts').select().inFilter('event_id', eventIds);

        return ReportData(
          events: events,
          workers: await _workers(venueId),
          eventStorefronts: [for (final r in storefrontRows) EventStorefront.fromJson(r)],
          needs: [for (final r in needRows) StaffingNeed.fromJson(r)],
          shifts: [for (final r in shiftRows) Shift.fromJson(r)],
          punches: [for (final r in punchRows) Punch.fromJson(r)],
          changes: [for (final r in changeRows) AssignmentChange.fromJson(r)],
          shiftCreatedAt: {
            for (final r in shiftRows)
              if (r['created_at'] != null) r['id'] as String: DateTime.parse(r['created_at'] as String).toUtc(),
          },
          money: session.canVenueWide('view_pay') ? await _reportMoney(session, eventIds, storefrontRows) : null,
        );
      });

  Future<ReportMoney> _reportMoney(AppSession session, List<String> eventIds, List<Map<String, dynamic>> storefrontRows) async {
    final venueId = session.venue.id;
    final results = await Future.wait([
      client.from('pay_codes').select().eq('venue_id', venueId),
      client.from('pay_rates').select().eq('venue_id', venueId),
      client.from('pay_differentials').select().eq('venue_id', venueId),
      client.from('agency_bill_rates').select().eq('venue_id', venueId),
      client.from('npo_agreements').select().eq('venue_id', venueId),
      client.from('npo_payouts').select().inFilter('event_id', eventIds),
      client.from('tip_pools').select().inFilter('event_id', eventIds),
      client.from('events').select('id, labor_budget').inFilter('id', eventIds),
    ]);
    final pools = [for (final r in results[6]) TipPool.fromJson(r)];
    final poolIds = [for (final p in pools) p.id];
    final allocations = poolIds.isEmpty
        ? <Map<String, dynamic>>[]
        : await _all((a, b) => client.from('tip_allocations').select().inFilter('pool_id', poolIds).order('pool_id', ascending: true).range(a, b));

    final storefrontBudgets = <String, Map<String, int>>{};
    for (final r in storefrontRows) {
      final cents = _budgetCents(r['labor_budget']);
      if (cents == null) continue;
      storefrontBudgets.putIfAbsent(r['event_id'] as String, () => {})[r['storefront_id'] as String] = cents;
    }

    return ReportMoney(
      payRules: PayRules.fromVenueSettings(session.venue.settings),
      payCodes: [for (final r in results[0]) PayCode.fromJson(r)],
      rates: [for (final r in results[1]) PayRate.fromJson(r)],
      differentials: [for (final r in results[2]) PayDifferential.fromJson(r)],
      billRates: [for (final r in results[3]) AgencyBillRate.fromJson(r)],
      npoAgreements: [for (final r in results[4]) NpoAgreement.fromJson(r)],
      npoPayouts: [for (final r in results[5]) NpoPayout.fromJson(r)],
      tipPools: pools,
      tipAllocations: [for (final r in allocations) TipAllocation.fromJson(r)],
      eventBudgetsCents: {
        for (final r in results[7]) r['id'] as String: ?_budgetCents(r['labor_budget']),
      },
      storefrontBudgetsCents: storefrontBudgets,
    );
  }

  /// Budgets are stored as dollars (numeric); reports work in whole cents.
  static int? _budgetCents(Object? v) => v == null ? null : ((v as num) * 100).round();
}
