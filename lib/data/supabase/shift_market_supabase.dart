part of '../supabase_repository.dart';

/// Supabase implementation of [ShiftMarketRepository]. Every call is a database function
/// (0012_shift_market.sql) that checks who is asking and logs what changed.
mixin _SupabaseShiftMarket on _SupabaseCore implements ShiftMarketRepository {
  List<Map<String, dynamic>> _smRows(Object? data) => [for (final r in (data as List? ?? const [])) (r as Map).cast<String, dynamic>()];

  String _smDay(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Future<List<OpenShift>> openShiftsForMe() => _guard(() async {
        final data = await client.rpc('open_shifts_for_me');
        return [for (final r in _smRows(data)) OpenShift.fromJson(r)];
      });

  @override
  Future<ShiftRequest> requestPickup(String shiftId, {String note = ''}) => _guard(() async {
        final row = await client.rpc('request_pickup', params: {'p_shift': shiftId, 'p_note': note});
        final id = (row as Map)['id'] as String;
        final mine = await myShiftRequests();
        return mine.firstWhere((r) => r.id == id);
      });

  @override
  Future<void> requestDrop(String shiftId, {String reason = ''}) =>
      _guard(() => client.rpc('request_drop', params: {'p_shift': shiftId, 'p_reason': reason}));

  @override
  Future<List<SwapCandidate>> swapCandidates(String shiftId) => _guard(() async {
        final data = await client.rpc('my_swap_candidates', params: {'p_shift': shiftId});
        return [for (final r in _smRows(data)) SwapCandidate.fromJson(r)];
      });

  @override
  Future<void> offerSwap(String shiftId, String toWorkerId, {String note = ''}) =>
      _guard(() => client.rpc('offer_swap', params: {'p_shift': shiftId, 'p_to_worker': toWorkerId, 'p_note': note}));

  @override
  Future<void> respondSwap(String requestId, {required bool accept}) =>
      _guard(() => client.rpc('respond_swap', params: {'p_request': requestId, 'p_accept': accept}));

  @override
  Future<void> cancelShiftRequest(String requestId) => _guard(() => client.rpc('cancel_shift_request', params: {'p_request': requestId}));

  @override
  Future<List<ShiftRequest>> myShiftRequests() => _guard(() async {
        final data = await client.rpc('my_shift_requests');
        return [for (final r in _smRows(data)) ShiftRequest.fromJson(r)];
      });

  @override
  Future<MyAvailability> myAvailability() => _guard(() async {
        final data = await client.rpc('my_availability');
        return MyAvailability.fromJson((data as Map).cast());
      });

  @override
  Future<void> setEventAvailability(String eventId, AvailabilityStatus? status, {String note = ''}) =>
      _guard(() => client.rpc('set_event_availability', params: {'p_event': eventId, 'p_status': status?.code, 'p_note': note}));

  @override
  Future<Blackout> setBlackout(DateTime startsOn, DateTime endsOn, {String note = '', String? id}) => _guard(() async {
        final row = await client.rpc('set_blackout', params: {'p_starts': _smDay(startsOn), 'p_ends': _smDay(endsOn), 'p_note': note, 'p_id': id});
        return Blackout.fromJson((row as Map).cast());
      });

  @override
  Future<void> deleteBlackout(String id) => _guard(() => client.rpc('delete_blackout', params: {'p_id': id}));

  @override
  Future<List<ShiftRequest>> reviewShiftRequests({bool history = false}) => _guard(() async {
        final data = await client.rpc('review_shift_requests', params: {'p_history': history});
        return [for (final r in _smRows(data)) ShiftRequest.fromJson(r)];
      });

  @override
  Future<void> decideShiftRequest(String requestId, {required bool approve, String note = '', List<String> warnings = const []}) =>
      _guard(() => client.rpc('decide_shift_request',
          params: {'p_request': requestId, 'p_approve': approve, 'p_note': note, 'p_warnings': warnings}));

  @override
  Future<List<MarketCandidate>> candidatesWithAvailability(String eventId, String jobRole) => _guard(() async {
        final data = await client.rpc('assignment_candidates', params: {'p_event': eventId, 'p_role': jobRole});
        return [for (final r in _smRows(data)) MarketCandidate.fromJson(r)];
      });

  @override
  Future<ScheduleOptimizationPlan> generateSmartSchedule(
    String eventId, {
    SmartSchedulerConstraints constraints = const SmartSchedulerConstraints(),
  }) => _guard(() async {
    final eventData = await client.from('events').select(eventReadColumns).eq('id', eventId).single();
    final event = Event.fromJson(eventData);
    final session = (await restoreSession())!;
    final venue = session.venue;
    final rules = VenueRules.fromJson(venue.settings);
    final timeZone = venue.timeZone;

    final sfData = await client.from('storefronts').select().eq('venue_id', venue.id);
    final storefronts = {for (final r in _smRows(sfData)) r['id'] as String: Storefront.fromJson(r)};

    final roleData = await client.from('job_roles').select().eq('venue_id', venue.id);
    final jobRoles = {for (final r in _smRows(roleData)) r['code'] as String: JobRole.fromJson(r)};

    final shiftData = await client.from('shifts').select().eq('event_id', eventId);
    final shifts = [for (final r in _smRows(shiftData)) Shift.fromJson(r)];

    final allWorkers = await listWorkers(session);

    final weekStart = workweekStart(event.callTime, timeZone, rules.overtime.workweekStartDay);
    final weekEnd = weekStart.add(const Duration(days: 7));
    final wwShifts = await client
        .from('shifts')
        .select()
        .eq('venue_id', venue.id)
        .gte('call_time', weekStart.toIso8601String())
        .lt('call_time', weekEnd.toIso8601String());

    final weekHoursByWorker = <String, double>{};
    for (final r in _smRows(wwShifts)) {
      final s = Shift.fromJson(r);
      if (s.workerId != null && s.eventId != eventId && s.status == ShiftStatus.assigned) {
        final dur = SmartScheduler.estimateShiftHours(event, s);
        weekHoursByWorker[s.workerId!] = (weekHoursByWorker[s.workerId!] ?? 0.0) + dur;
      }
    }

    final recentWindow = event.callTime.subtract(const Duration(days: 30));
    final recentShifts = await client
        .from('shifts')
        .select('worker_id, storefront_id, call_time')
        .eq('venue_id', venue.id)
        .not('worker_id', 'is', null)
        .gte('call_time', recentWindow.toIso8601String())
        .lt('call_time', event.callTime.toIso8601String());

    final recentCountByWorker = <String, int>{};
    final recentSfByWorker = <String, List<String>>{};
    for (final r in _smRows(recentShifts)) {
      final wid = r['worker_id'] as String;
      final sfid = r['storefront_id'] as String;
      recentCountByWorker[wid] = (recentCountByWorker[wid] ?? 0) + 1;
      recentSfByWorker.putIfAbsent(wid, () => []).add(sfid);
    }

    final rehireFlags = await loadRehireFlags(session);
    final day = localDateOf(event.callTime, timeZone);

    final profiles = <WorkerScheduleProfile>[];
    for (final w in allWorkers.where((w) => w.status == 'active')) {
      final rehireReason = rehireFlags[w.id];
      profiles.add(WorkerScheduleProfile(
        worker: w,
        ageOnEvent: w.ageOn(day),
        availability: CandidateAvailabilityStatus.available,
        currentWeekHours: weekHoursByWorker[w.id] ?? 0.0,
        recentShiftsCount: recentCountByWorker[w.id] ?? 0,
        recentStorefrontIds: recentSfByWorker[w.id] ?? const [],
        reliabilityScore: 95,
        doNotRehire: rehireReason != null,
        doNotRehireReason: rehireReason,
      ));
    }

    return SmartScheduler.optimize(
      event: event,
      shifts: shifts,
      candidateProfiles: profiles,
      storefronts: storefronts,
      jobRoles: jobRoles,
      rules: rules,
      timeZone: timeZone,
      constraints: constraints,
    );
  });

  @override
  Future<List<CandidateFitScore>> scoreCandidatesForShift(
    Shift shift,
    List<MarketCandidate> candidates, {
    SmartSchedulerConstraints constraints = const SmartSchedulerConstraints(),
  }) => _guard(() async {
    final session = (await restoreSession())!;
    final venue = session.venue;
    final rules = VenueRules.fromJson(venue.settings);
    final timeZone = venue.timeZone;
    final eventData = await client.from('events').select(eventReadColumns).eq('id', shift.eventId).single();
    final event = Event.fromJson(eventData);

    final roleData = await client.from('job_roles').select().eq('venue_id', venue.id).eq('code', shift.jobRoleCode).maybeSingle();
    final role = roleData != null
        ? JobRole.fromJson(roleData)
        : JobRole(venueId: venue.id, code: shift.jobRoleCode, name: shift.jobRoleCode, requiredCertifications: const []);

    final weekStart = workweekStart(event.callTime, timeZone, rules.overtime.workweekStartDay);
    final weekEnd = weekStart.add(const Duration(days: 7));
    final wwShifts = await client
        .from('shifts')
        .select()
        .eq('venue_id', venue.id)
        .gte('call_time', weekStart.toIso8601String())
        .lt('call_time', weekEnd.toIso8601String());

    final weekHoursByWorker = <String, double>{};
    for (final r in _smRows(wwShifts)) {
      final s = Shift.fromJson(r);
      if (s.workerId != null && s.eventId != event.id && s.status == ShiftStatus.assigned) {
        final dur = SmartScheduler.estimateShiftHours(event, s);
        weekHoursByWorker[s.workerId!] = (weekHoursByWorker[s.workerId!] ?? 0.0) + dur;
      }
    }

    final rehireFlags = await loadRehireFlags(session);
    final scores = <CandidateFitScore>[];
    for (final m in candidates) {
      final w = m.worker.worker;
      final cand = m.availability;
      final availStatus = cand.blackout
          ? CandidateAvailabilityStatus.blackout
          : switch (cand.status) {
              AvailabilityStatus.available => cand.note.toLowerCase().contains('preferred')
                  ? CandidateAvailabilityStatus.preferred
                  : CandidateAvailabilityStatus.available,
              AvailabilityStatus.unavailable => CandidateAvailabilityStatus.unavailable,
              null => CandidateAvailabilityStatus.noAnswer,
            };

      final profile = WorkerScheduleProfile(
        worker: w,
        ageOnEvent: m.worker.ageOnEvent,
        availability: availStatus,
        availabilityNote: cand.note,
        currentWeekHours: weekHoursByWorker[w.id] ?? 0.0,
        recentShiftsCount: 1,
        recentStorefrontIds: const [],
        reliabilityScore: 95,
        doNotRehire: rehireFlags.containsKey(w.id),
        doNotRehireReason: rehireFlags[w.id],
      );

      scores.add(SmartScheduler.evaluateFit(
        profile: profile,
        shift: shift,
        role: role,
        event: event,
        rules: rules,
        timeZone: timeZone,
        constraints: constraints,
      ));
    }
    return scores;
  });

  @override
  Future<int> applySmartSchedule(
    String eventId,
    List<ShiftAssignmentProposal> proposals,
  ) => _guard(() async {
    int applied = 0;
    for (final p in proposals) {
      await assign(p.shiftId, p.workerId, reason: 'AI Auto-Schedule', warnings: p.warnings);
      applied++;
    }
    return applied;
  });
}
