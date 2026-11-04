part of '../demo_repository.dart';

/// Demo (in-memory) implementation of [ReportsRepository]. The sample arena's own
/// events (and whatever was changed in this session) plus [SampleHistory]: two earlier
/// seasons and preseason games, so comparisons, trends and retention show something.
mixin _DemoReports on _DemoCore implements ReportsRepository {
  late final SampleHistory _history = SampleHistory.generate(_arena);
  ReportTargets? _reportTargets;

  void _requireReports() {
    if (!_me.can(Perm.viewReports)) throw const AppFailure('You do not have permission to see reports.');
  }

  List<Event> get _allReportEvents => [..._history.events, ..._events.values];

  @override
  Future<ReportTargets> loadReportTargets(AppSession session) async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    return _reportTargets ?? ReportTargets.fromRow(null, settings: session.venue.settings);
  }

  @override
  Future<void> saveReportTargets(AppSession session, ReportTargets targets) => _delay(() {
        if (!_me.canVenueWide(Perm.manageSettings)) throw const AppFailure('Only someone who manages settings can change targets.');
        final problem = targets.validate();
        if (problem != null) throw AppFailure(problem);
        _reportTargets = ReportTargets.fromRow(targets.toRow(session.venue.id), settings: session.venue.settings);
      });

  @override
  Future<ReportData> loadReportData(AppSession session, DateTime from, DateTime to) => _delay(() {
        _requireReports();
        final tz = _arena.venue.timeZone;
        final start = startOfLocalDay(addCalendarDays(from, -7), tz);
        final end = startOfLocalDay(addCalendarDays(to, 8), tz);
        bool inWindow(DateTime t) => !t.isBefore(start) && t.isBefore(end);
        final events = [for (final e in _allReportEvents) if (inWindow(e.startTime)) e];
        final ids = {for (final e in events) e.id};
        final current = {for (final e in _events.values) if (ids.contains(e.id)) e.id};
        final workers = {for (final w in _history.formerWorkers) w.id: w, ..._workers};
        final money = session.canVenueWide('view_pay')
            ? ReportMoney(
                payRules: PayRules.fromVenueSettings(session.venue.settings),
                payCodes: _pay.payCodes,
                rates: [..._history.rates, ..._pay.rates],
                differentials: _pay.differentials,
                billRates: [..._history.billRates, ..._pay.billRates],
                npoAgreements: [..._history.npoAgreements, ..._pay.npoAgreements],
                npoPayouts: [
                  for (final p in _history.npoPayouts) if (ids.contains(p.eventId)) p,
                  for (final p in _npoPayouts.values) if (ids.contains(p.eventId)) p,
                ],
                tipPools: [
                  for (final t in _history.tipPools) if (ids.contains(t.eventId)) t,
                  for (final t in _tipPools.values) if (ids.contains(t.eventId)) t,
                ],
                tipAllocations: [for (final list in _allocations.values) ...list],
                eventBudgetsCents: {for (final e in _history.eventBudgetsCents.entries) if (ids.contains(e.key)) e.key: e.value},
                storefrontBudgetsCents: {
                  for (final e in _history.storefrontBudgetsCents.entries) if (ids.contains(e.key)) e.key: e.value,
                },
              )
            : null;
        return ReportData(
          events: events,
          workers: workers,
          eventStorefronts: [
            for (final es in _history.eventStorefronts) if (ids.contains(es.eventId)) es,
            for (final id in current)
              for (final f in _arena.storefronts)
                EventStorefront(eventId: id, storefrontId: f.id, isOpen: _openStorefronts[id]?.contains(f.id) ?? false),
          ],
          needs: [
            for (final n in _history.needs) if (ids.contains(n.eventId)) n,
            for (final n in _needs) if (ids.contains(n.eventId)) n,
          ],
          shifts: [
            for (final s in _history.shifts) if (ids.contains(s.eventId)) s,
            for (final s in _shifts.values) if (ids.contains(s.eventId)) s,
          ],
          punches: [
            for (final p in _history.punches) if (inWindow(p.occurredAt)) p,
            for (final p in _punches) if (inWindow(p.occurredAt)) p,
          ],
          changes: [
            for (final c in _history.changes) if (ids.contains(c.eventId)) c,
            for (final c in _changes) if (ids.contains(c.eventId)) c,
          ],
          shiftCreatedAt: _history.shiftCreatedAt,
          money: money,
        );
      });

  @override
  Future<List<WorkerSeason>> loadWorkerSeasons(AppSession session, {int startMonth = Season.defaultStartMonth}) => _delay(() {
        _requireReports();
        return workerSeasonsFromPunches(
          punches: [..._history.punches, ..._punches],
          events: {for (final e in _allReportEvents) e.id: e},
          timeZone: _arena.venue.timeZone,
          startMonth: startMonth,
        );
      });
}
