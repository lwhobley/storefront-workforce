part of '../supabase_repository.dart';

/// Supabase implementation of [ReportsRepository]. Reads go through row level
/// security; labor budgets come from report_labor_budgets() (0024), which needs
/// view_pay, because the budget columns are not readable from the tables.
mixin _SupabaseReports on _SupabaseCore implements ReportsRepository {
  static const _shiftColumns =
      'id, venue_id, event_id, storefront_id, station_id, job_role_code, worker_id, call_time, scheduled_end, status, released_at, release_order, release_reason, version, created_at';
  static const _punchColumns = 'id, venue_id, worker_id, event_id, shift_id, kind, break_kind, occurred_at, source, status';
  static const _changeColumns =
      'id, event_id, shift_id, action, worker_id, from_storefront_id, to_storefront_id, from_job_role_code, to_job_role_code, reason, changed_at';

  /// A season of records is many pages; allow longer than the usual 20 seconds.
  Future<T> _reportGuard<T>(Future<T> Function() body) async {
    try {
      return await body().timeout(const Duration(seconds: 120));
    } on TimeoutException {
      throw const AppFailure('The report took too long to load. Try a shorter range or try again.');
    } catch (e) {
      _fail(e);
    }
  }

  /// Splits [ids] into chunks small enough for a URL filter.
  Iterable<List<String>> _chunks(List<String> ids, [int size = 150]) sync* {
    for (var i = 0; i < ids.length; i += size) {
      yield ids.sublist(i, i + size > ids.length ? ids.length : i + size);
    }
  }

  Future<List<Map<String, dynamic>>> _byEvents(
    List<String> eventIds,
    PostgrestTransformBuilder<List<Map<String, dynamic>>> Function(List<String> ids, int from, int to) page,
  ) async {
    final out = <Map<String, dynamic>>[];
    for (final chunk in _chunks(eventIds)) {
      out.addAll(await _all((a, b) => page(chunk, a, b)));
    }
    return out;
  }

  @override
  Future<ReportTargets> loadReportTargets(AppSession session) => _guard(() async {
        final row = await client.from('report_targets').select().eq('venue_id', session.venue.id).maybeSingle();
        return ReportTargets.fromRow(row, settings: session.venue.settings);
      });

  @override
  Future<void> saveReportTargets(AppSession session, ReportTargets targets) => _guard(() async {
        final problem = targets.validate();
        if (problem != null) throw AppFailure(problem);
        await client.from('report_targets').upsert({...targets.toRow(session.venue.id), 'updated_at': DateTime.now().toUtc().toIso8601String()});
      });

  @override
  Future<ReportData> loadReportData(AppSession session, DateTime from, DateTime to) => _reportGuard(() async {
        final venueId = session.venue.id;
        final w = _window(session.venue.timeZone, from, to);
        final f = w.from.toIso8601String(), t = w.to.toIso8601String();
        final eventRows = await _all((a, b) => client
            .from('events')
            .select(eventReadColumns)
            .eq('venue_id', venueId)
            .gte('start_time', f)
            .lt('start_time', t)
            .order('start_time', ascending: true)
            .range(a, b));
        final ids = [for (final r in eventRows) r['id'] as String];
        final storefrontRows = await _byEvents(ids, (c, a, b) => client
            .from('event_storefronts')
            .select('event_id, storefront_id, is_open')
            .inFilter('event_id', c)
            .order('event_id', ascending: true)
            .order('storefront_id', ascending: true)
            .range(a, b));
        final needRows = await _byEvents(ids, (c, a, b) => client
            .from('event_staffing_needs')
            .select('event_id, storefront_id, job_role_code, count')
            .inFilter('event_id', c)
            .order('event_id', ascending: true)
            .order('storefront_id', ascending: true)
            .order('job_role_code', ascending: true)
            .range(a, b));
        final shiftRows = await _byEvents(ids, (c, a, b) =>
            client.from('shifts').select(_shiftColumns).inFilter('event_id', c).order('id', ascending: true).range(a, b));
        final changeRows = await _byEvents(ids, (c, a, b) =>
            client.from('assignment_changes').select(_changeColumns).inFilter('event_id', c).order('id', ascending: true).range(a, b));
        final punchRows = await _all((a, b) => client
            .from('punches')
            .select(_punchColumns)
            .eq('venue_id', venueId)
            .gte('occurred_at', f)
            .lt('occurred_at', t)
            .order('id', ascending: true)
            .range(a, b));
        final workerRows = await _all((a, b) => client
            .from('workers')
            .select('*, worker_job_roles(job_role_code), worker_certifications(id, worker_id, cert_type_code, number, issued_on, expires_on)')
            .eq('venue_id', venueId)
            .order('id', ascending: true)
            .range(a, b));

        ReportMoney? money;
        if (session.canVenueWide('view_pay')) {
          final setup = await loadPaySetup(session);
          final pools = await _byEvents(ids, (c, a, b) =>
              client.from('tip_pools').select().inFilter('event_id', c).order('id', ascending: true).range(a, b));
          final poolIds = [for (final p in pools) p['id'] as String];
          final allocations = <Map<String, dynamic>>[];
          for (final chunk in _chunks(poolIds)) {
            allocations.addAll(await _all((a, b) => client
                .from('tip_allocations')
                .select()
                .inFilter('pool_id', chunk)
                .order('pool_id', ascending: true)
                .order('worker_id', ascending: true)
                .range(a, b)));
          }
          final payouts = await _byEvents(ids, (c, a, b) =>
              client.from('npo_payouts').select().inFilter('event_id', c).order('id', ascending: true).range(a, b));
          final budgets = await client.rpc('report_labor_budgets', params: {'p_venue': venueId, 'p_from': f, 'p_to': t});
          final eventBudgets = <String, int>{};
          final storefrontBudgets = <String, Map<String, int>>{};
          for (final r in (budgets as List? ?? const [])) {
            final row = (r as Map).cast<String, dynamic>();
            if (row['labor_budget'] == null) continue;
            final cents = parseCents(row['labor_budget']);
            final sf = row['storefront_id'] as String?;
            if (sf == null) {
              eventBudgets[row['event_id'] as String] = cents;
            } else {
              storefrontBudgets.putIfAbsent(row['event_id'] as String, () => {})[sf] = cents;
            }
          }
          money = ReportMoney(
            payRules: PayRules.fromVenueSettings(session.venue.settings),
            payCodes: setup.payCodes,
            rates: setup.rates,
            differentials: setup.differentials,
            billRates: setup.billRates,
            npoAgreements: setup.npoAgreements,
            npoPayouts: [for (final r in payouts) NpoPayout.fromJson(r)],
            tipPools: [for (final r in pools) TipPool.fromJson(r)],
            tipAllocations: [for (final r in allocations) TipAllocation.fromJson(r)],
            eventBudgetsCents: eventBudgets,
            storefrontBudgetsCents: storefrontBudgets,
          );
        }

        return ReportData(
          events: [for (final r in eventRows) Event.fromJson(r)],
          workers: {
            for (final r in workerRows)
              r['id'] as String: Worker.fromJson({
                ...r,
                'job_roles': [for (final j in (r['worker_job_roles'] as List? ?? const [])) j['job_role_code']],
                'certifications': r['worker_certifications'] ?? const [],
              }),
          },
          eventStorefronts: [for (final r in storefrontRows) EventStorefront.fromJson(r)],
          needs: [for (final r in needRows) StaffingNeed.fromJson(r)],
          shifts: [for (final r in shiftRows) Shift.fromJson(r)],
          punches: [for (final r in punchRows) Punch.fromJson(r)],
          changes: [for (final r in changeRows) AssignmentChange.fromJson({...r, 'id': '${r['id']}'})],
          shiftCreatedAt: {
            for (final r in shiftRows)
              if (r['created_at'] != null) r['id'] as String: DateTime.parse(r['created_at'] as String).toUtc(),
          },
          money: money,
        );
      });

  @override
  Future<List<WorkerSeason>> loadWorkerSeasons(AppSession session, {int startMonth = Season.defaultStartMonth}) => _reportGuard(() async {
        final data = await client.rpc('report_worker_seasons', params: {'p_venue': session.venue.id, 'p_start_month': startMonth});
        return [for (final r in (data as List? ?? const [])) WorkerSeason.fromJson((r as Map).cast())];
      });
}
