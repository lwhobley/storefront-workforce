part of '../supabase_repository.dart';

/// Supabase implementation of [AdminRepository]. The database enforces the same rules
/// again: only manage_settings may change settings or decide a deletion request, and
/// nobody may approve their own.
mixin _SupabaseAdmin on _SupabaseCore implements AdminRepository {
  @override
  Future<void> saveVenueProfile(AppSession session, {String? name, String? timeZone, Map<String, dynamic>? branding}) =>
      _guard(() async {
        final patch = <String, dynamic>{
          'name': ?name?.trim(),
          'time_zone': ?timeZone,
          'branding': ?branding,
        };
        if (patch.isEmpty) return;
        await client.from('venues').update(patch).eq('id', session.venue.id);
      });

  @override
  Future<RetentionPolicy> loadRetention(AppSession session) => _guard(() async {
        final row = await client.from('retention_policies').select().eq('venue_id', session.venue.id).maybeSingle();
        return RetentionPolicy.fromRow(row);
      });

  @override
  Future<void> saveRetention(AppSession session, RetentionPolicy policy) => _guard(() async {
        final problem = policy.validate();
        if (problem != null) throw AppFailure(problem);
        await client.from('retention_policies').upsert(policy.toRow(session.venue.id));
      });

  @override
  Future<RetentionDue> retentionDue(AppSession session) => _guard(() async {
        final data = await client.rpc('retention_due', params: {'p_venue': session.venue.id});
        return data == null ? const RetentionDue() : RetentionDue.fromJson((data as Map).cast());
      });

  @override
  Future<int> purgeOldPunchPhotos(AppSession session) => _guard(() async {
        final n = await client.rpc('purge_old_punch_photos', params: {'p_venue': session.venue.id});
        return (n as num?)?.toInt() ?? 0;
      });

  @override
  Future<List<DeletionRequest>> loadDeletionRequests(AppSession session) => _guard(() async {
        final rows = await client
            .from('data_deletion_requests')
            .select()
            .eq('venue_id', session.venue.id)
            .order('requested_at', ascending: false);
        final me = client.auth.currentUser?.id;
        return [for (final r in rows) DeletionRequest.fromRow(r, myUserId: me)];
      });

  @override
  Future<void> requestDataDeletion(AppSession session, String workerId, {String note = ''}) => _guard(() async {
        await client.from('data_deletion_requests').insert({
          'venue_id': session.venue.id,
          'worker_id': workerId,
          'note': note.trim(),
        });
      });

  @override
  Future<void> approveDataDeletion(AppSession session, String requestId, {String note = ''}) =>
      _guard(() => client.rpc('anonymize_worker', params: {'p_request': requestId, 'p_note': note.trim()}));

  @override
  Future<void> refuseDataDeletion(AppSession session, String requestId, String reason) =>
      _guard(() => client.rpc('refuse_deletion_request', params: {'p_request': requestId, 'p_note': reason.trim()}));
}
