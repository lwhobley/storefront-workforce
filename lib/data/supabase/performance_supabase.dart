part of '../supabase_repository.dart';

/// Supabase implementation of [PerformanceRepository].
///
/// Ratings and flags are the tables from 0016 (read needs view_workers, writes need
/// manage_workers; audited since 0019); notes are 0022's worker_notes. Reliability is
/// worked out here from shifts, punches and assignment changes with the shared
/// [attendanceOutcomes], so it matches the reports exactly.
mixin _SupabasePerformance on _SupabaseCore implements PerformanceRepository {
  static const _eventColumns =
      'id, venue_id, name, event_type_code, start_time, call_time, doors_time, end_time, expected_attendance, actual_attendance, status, source, external_id, notes';
  static const _punchColumns = 'id, venue_id, worker_id, event_id, shift_id, kind, break_kind, occurred_at, source, status';

  /// Display names for user ids (ratings, notes, flags record who did it).
  Future<Map<String, String>> _perfNames(Iterable<String?> ids) async {
    final list = {for (final id in ids) ?id}.toList();
    if (list.isEmpty) return const {};
    final rows = await client.from('user_profiles').select('id, display_name').inFilter('id', list);
    return {for (final r in rows) r['id'] as String: (r['display_name'] as String?) ?? ''};
  }

  @override
  Future<PerformanceData> loadPerformance(AppSession session) => _guard(() async {
        if (!session.canVenueWide(Perm.viewWorkers)) throw const AppFailure('Not authorized');
        final venueId = session.venue.id;
        final rules = ReliabilityRules.fromVenueSettings(session.venue.settings);
        final now = DateTime.now().toUtc();
        final since = now.subtract(Duration(days: rules.windowDays + 1));
        final from = since.toIso8601String(), to = now.toIso8601String();

        final events = await _all((a, b) => client.from('events').select(_eventColumns).eq('venue_id', venueId)
            .gte('call_time', from).lte('call_time', to).order('id', ascending: true).range(a, b));
        final shifts = await _all((a, b) => client.from('shifts').select().eq('venue_id', venueId)
            .gte('call_time', from).lte('call_time', to).order('id', ascending: true).range(a, b));
        final punches = await _all((a, b) => client.from('punches').select(_punchColumns).eq('venue_id', venueId)
            .gte('occurred_at', since.subtract(const Duration(hours: 12)).toIso8601String()).order('id', ascending: true).range(a, b));
        // Call-offs are removals; only those are needed (a call-off counts within 48 hours).
        final changes = await _all((a, b) => client.from('assignment_changes')
            .select('id, event_id, shift_id, action, changed_at, worker_id, from_storefront_id, to_storefront_id, from_job_role_code, to_job_role_code, reason')
            .eq('venue_id', venueId).eq('action', 'unassigned').gte('changed_at', since.subtract(const Duration(days: 3)).toIso8601String())
            .order('id', ascending: true).range(a, b));
        final ratings = await _all((a, b) => client.from('worker_ratings').select().eq('venue_id', venueId)
            .order('rated_at', ascending: true).order('id', ascending: true).range(a, b));
        final flags = await client.from('rehire_flags').select().eq('venue_id', venueId);
        final names = await _perfNames([for (final r in ratings) r['rated_by'] as String?, for (final f in flags) f['flagged_by'] as String?]);

        final eventIds = {for (final e in events) e['id'] as String};
        final punchList = [for (final r in punches) if (eventIds.contains(r['event_id'])) Punch.fromJson(r)];
        final outcomes = attendanceOutcomes(
          shifts: [for (final r in shifts) Shift.fromJson(r)],
          punches: punchList,
          changes: [for (final r in changes) if (eventIds.contains(r['event_id'])) AssignmentChange.fromJson(r)],
          rules: session.rules.attendance,
          now: now,
        );
        return PerformanceData(
          now: now,
          rules: rules,
          outcomes: outcomes,
          events: {for (final e in events) e['id'] as String: Event.fromJson(e)},
          ratings: [for (final r in ratings) WorkerRating.fromJson(r, ratedByName: names[r['rated_by']] ?? '')],
          flags: {for (final f in flags) f['worker_id'] as String: RehireFlag.fromJson(f, flaggedByName: names[f['flagged_by']] ?? '')},
          workedMinutes: workedMinutesByWorker(punchList, now: now),
        );
      });

  @override
  Future<WorkerPerformanceDetail> workerPerformance(AppSession session, String workerId) => _guard(() async {
        final venueId = session.venue.id;
        final ratings = await client.from('worker_ratings').select().eq('venue_id', venueId).eq('worker_id', workerId)
            .order('rated_at', ascending: false);
        final notes = await client.from('worker_notes').select().eq('venue_id', venueId).eq('worker_id', workerId)
            .order('written_at', ascending: false);
        final flag = await client.from('rehire_flags').select().eq('venue_id', venueId).eq('worker_id', workerId).maybeSingle();
        final names = await _perfNames([
          for (final r in ratings) r['rated_by'] as String?,
          for (final n in notes) n['written_by'] as String?,
          flag?['flagged_by'] as String?,
        ]);
        return WorkerPerformanceDetail(
          ratings: [for (final r in ratings) WorkerRating.fromJson(r, ratedByName: names[r['rated_by']] ?? '')],
          notes: [for (final n in notes) WorkerNote.fromJson(n, writtenByName: names[n['written_by']] ?? '')],
          flag: flag == null ? null : RehireFlag.fromJson(flag, flaggedByName: names[flag['flagged_by']] ?? ''),
        );
      });

  @override
  Future<void> addRating(AppSession session, String workerId, {required int stars, String note = '', String? eventId}) => _guard(() async {
        if (stars < 1 || stars > 5) throw const AppFailure('Pick 1 to 5 stars.');
        await client.from('worker_ratings').insert({
          'venue_id': session.venue.id,
          'worker_id': workerId,
          'event_id': eventId,
          'stars': stars,
          'note': note.trim(),
        });
      });

  @override
  Future<void> addNote(AppSession session, String workerId, String body, {String? eventId}) => _guard(() async {
        final text = body.trim();
        if (text.isEmpty) throw const AppFailure('Write the note first.');
        await client.from('worker_notes').insert({
          'venue_id': session.venue.id,
          'worker_id': workerId,
          'event_id': eventId,
          'body': text,
        });
      });

  @override
  Future<void> setDoNotRehire(AppSession session, String workerId, String reason) => _guard(() async {
        final text = reason.trim();
        if (text.isEmpty) throw const AppFailure('Give a reason.');
        final venueId = session.venue.id;
        final existing = await client.from('rehire_flags').select('worker_id').eq('venue_id', venueId).eq('worker_id', workerId).maybeSingle();
        // Since 0019 only the reason of an existing flag may change.
        if (existing == null) {
          await client.from('rehire_flags').insert({'venue_id': venueId, 'worker_id': workerId, 'reason': text});
        } else {
          await client.from('rehire_flags').update({'reason': text}).eq('venue_id', venueId).eq('worker_id', workerId);
        }
      });

  @override
  Future<void> clearDoNotRehire(AppSession session, String workerId) => _guard(() async {
        await client.from('rehire_flags').delete().eq('venue_id', session.venue.id).eq('worker_id', workerId);
      });

  @override
  Future<List<PastEventStaffing>> staffingHistory(AppSession session, String eventTypeCode) => _guard(() async {
        final venueId = session.venue.id;
        final events = await client.from('events').select(_eventColumns).eq('venue_id', venueId)
            .eq('event_type_code', eventTypeCode).eq('status', 'completed').order('start_time', ascending: true);
        if (events.isEmpty) return const <PastEventStaffing>[];
        final ids = [for (final e in events) e['id'] as String];
        final needs = await _all((a, b) => client.from('event_staffing_needs').select('event_id, storefront_id, job_role_code, count')
            .inFilter('event_id', ids).order('event_id', ascending: true).order('storefront_id', ascending: true)
            .order('job_role_code', ascending: true).range(a, b));
        final shifts = await _all((a, b) => client.from('shifts').select().inFilter('event_id', ids)
            .order('id', ascending: true).range(a, b));
        final byEventNeeds = <String, List<StaffingNeed>>{};
        for (final n in needs) {
          byEventNeeds.putIfAbsent(n['event_id'] as String, () => []).add(StaffingNeed.fromJson(n));
        }
        final byEventShifts = <String, List<Shift>>{};
        for (final s in shifts) {
          byEventShifts.putIfAbsent(s['event_id'] as String, () => []).add(Shift.fromJson(s));
        }
        return [
          for (final e in events)
            PastEventStaffing.fromSchedule(Event.fromJson(e), byEventNeeds[e['id']] ?? const [], byEventShifts[e['id']] ?? const []),
        ];
      });
}
