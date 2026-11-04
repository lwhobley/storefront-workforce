part of '../supabase_repository.dart';

/// Supabase implementation of [PeopleRepository]. Onboarding and the partner portals go
/// through the database functions in 0014_onboarding_partners.sql; adding people writes
/// the workers table directly as the manager (row level security checks manage_workers).
mixin _SupabasePeople on _SupabaseCore implements PeopleRepository {
  static const _bucket = 'onboarding-docs';

  Map<String, dynamic> _map(Object? data) => (data as Map).cast<String, dynamic>();

  // ---- The signed-in person ----

  @override
  Future<MyHoursData> loadMyHours(AppSession session, DateTime from, DateTime to) => _guard(() async {
        final workerId = session.workerId;
        if (workerId == null) throw const AppFailure('No staff record is linked to this sign-in');
        final punches = await _all((a, b) => client
            .from('punches')
            .select('id, venue_id, worker_id, event_id, shift_id, kind, break_kind, occurred_at, source, status')
            .eq('worker_id', workerId)
            .gte('occurred_at', from.toUtc().toIso8601String())
            .lt('occurred_at', to.toUtc().toIso8601String())
            .order('id', ascending: true)
            .range(a, b));
        final eventIds = {for (final p in punches) ?p['event_id'] as String?}.toList();
        final events = eventIds.isEmpty ? <Map<String, dynamic>>[] : await client.from('events').select().inFilter('id', eventIds);
        final shifts = eventIds.isEmpty
            ? <Map<String, dynamic>>[]
            : await client.from('shifts').select().eq('worker_id', workerId).inFilter('event_id', eventIds);
        return MyHoursData(
          punches: [for (final r in punches) Punch.fromJson(r)],
          events: {for (final r in events) r['id'] as String: Event.fromJson(r)},
          shifts: [for (final r in shifts) Shift.fromJson(r)],
        );
      });

  @override
  Future<List<MyTip>> loadMyTips(AppSession session) => _guard(() async {
        final data = await client.rpc('my_tips');
        return [for (final t in (data as List? ?? const [])) MyTip.fromJson(_map(t))];
      });

  @override
  Future<OnboardingState> myOnboarding(AppSession session) =>
      _guard(() async => OnboardingState.fromJson(_map(await client.rpc('my_onboarding'))));

  @override
  Future<String> uploadOnboardingFile(AppSession session, String fileName, Uint8List bytes, {String contentType = 'image/jpeg'}) => _guard(() async {
        final workerId = session.workerId;
        if (workerId == null) throw const AppFailure('No staff record is linked to this sign-in');
        final safe = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        final path = '${session.venue.id}/$workerId/${DateTime.now().toUtc().millisecondsSinceEpoch}-$safe';
        await client.storage.from(_bucket).uploadBinary(path, bytes, fileOptions: FileOptions(contentType: contentType));
        return path;
      });

  @override
  Future<Uint8List?> downloadOnboardingFile(String path) async {
    try {
      return await client.storage.from(_bucket).download(path);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<OnboardingState> submitOnboardingStep(AppSession session, String step, Map<String, dynamic> data, {List<String> files = const []}) =>
      _guard(() async => OnboardingState.fromJson(
          _map(await client.rpc('submit_onboarding_step', params: {'p_step': step, 'p_data': data, 'p_files': files}))));

  @override
  Future<List<CertRecord>> workerCertifications(String workerId) => _guard(() async {
        final rows = await client.from('worker_certifications').select().eq('worker_id', workerId).order('created_at', ascending: true);
        return [for (final r in rows) CertRecord.fromJson(r)];
      });

  // ---- Managers ----

  @override
  Future<List<OnboardingState>> onboardingOverview(AppSession session) => _guard(() async {
        final data = await client.rpc('onboarding_overview', params: {'p_venue': session.venue.id});
        return [for (final s in (data as List? ?? const [])) OnboardingState.fromJson(_map(s))];
      });

  @override
  Future<OnboardingState> workerOnboarding(String workerId) =>
      _guard(() async => OnboardingState.fromJson(_map(await client.rpc('worker_onboarding', params: {'p_worker': workerId}))));

  @override
  Future<OnboardingState> reviewOnboardingStep(String workerId, String step, {required bool approve, String note = ''}) =>
      _guard(() async => OnboardingState.fromJson(_map(await client.rpc('review_onboarding_step',
          params: {'p_worker': workerId, 'p_step': step, 'p_approve': approve, 'p_note': note}))));

  @override
  Future<OnboardingState> completeOnboardingStep(String workerId, String step, Map<String, dynamic> data) =>
      _guard(() async => OnboardingState.fromJson(_map(await client.rpc('complete_onboarding_step',
          params: {'p_worker': workerId, 'p_step': step, 'p_data': data}))));

  @override
  Future<void> sendOnboardingReminder(String workerId) =>
      _guard(() => client.rpc('send_onboarding_reminder', params: {'p_worker': workerId}));

  @override
  Future<List<OnboardingDocument>> listOnboardingDocuments(AppSession session) => _guard(() async {
        final rows = await client.from('onboarding_documents').select().eq('venue_id', session.venue.id).order('step_code').order('sort');
        return [for (final r in rows) OnboardingDocument.fromJson(r)];
      });

  @override
  Future<void> saveOnboardingDocument(AppSession session, OnboardingDocument d) => _guard(() async {
        final row = {'step_code': d.stepCode, 'title': d.title.trim(), 'body': d.body, 'applies_to': d.appliesTo, 'active': d.active, 'sort': d.sort};
        if (d.id.isEmpty) {
          await client.from('onboarding_documents').insert({...row, 'venue_id': session.venue.id});
        } else {
          await client.from('onboarding_documents').update(row).eq('id', d.id);
        }
      });

  // ---- Adding people ----

  Future<void> _setRoles(String venueId, Map<String, List<String>> rolesByWorker) async {
    if (rolesByWorker.isEmpty) return;
    await client.from('worker_job_roles').delete().inFilter('worker_id', rolesByWorker.keys.toList());
    final rows = [
      for (final e in rolesByWorker.entries)
        for (final r in e.value) {'venue_id': venueId, 'worker_id': e.key, 'job_role_code': r},
    ];
    if (rows.isNotEmpty) await client.from('worker_job_roles').insert(rows);
  }

  @override
  Future<Worker> addWorker(AppSession session, NewPerson person) => _guard(() async {
        final row = await client.from('workers').insert(person.toRow(session.venue.id)).select().single();
        final id = row['id'] as String;
        await _setRoles(session.venue.id, {id: person.jobRoles});
        return Worker.fromJson({...row, 'job_roles': person.jobRoles});
      });

  @override
  Future<RosterImportResult> importRoster(AppSession session, List<NewPerson> rows, {required bool updateExisting}) => _guard(() async {
        final venueId = session.venue.id;
        final numbers = [for (final p in rows) p.employeeNumber];
        final existing = await client.from('workers').select('id, employee_number').eq('venue_id', venueId).inFilter('employee_number', numbers);
        final idByNumber = {for (final r in existing) r['employee_number'] as String: r['id'] as String};
        final toAdd = [for (final p in rows) if (!idByNumber.containsKey(p.employeeNumber)) p];
        final toUpdate = updateExisting ? [for (final p in rows) if (idByNumber.containsKey(p.employeeNumber)) p] : const <NewPerson>[];
        final roles = <String, List<String>>{};
        if (toAdd.isNotEmpty) {
          final inserted = await client.from('workers').insert([for (final p in toAdd) p.toRow(venueId)]).select('id, employee_number');
          final byNumber = {for (final p in toAdd) p.employeeNumber: p};
          for (final r in inserted) {
            roles[r['id'] as String] = byNumber[r['employee_number']]!.jobRoles;
          }
        }
        for (final p in toUpdate) {
          final id = idByNumber[p.employeeNumber]!;
          await client.from('workers').update(p.toRow(venueId)..remove('venue_id')).eq('id', id);
          roles[id] = p.jobRoles;
        }
        await _setRoles(venueId, roles);
        return RosterImportResult(added: toAdd.length, updated: toUpdate.length, skipped: rows.length - toAdd.length - toUpdate.length);
      });

  @override
  Future<void> verifyCertification(AppSession session, String certId) => _guard(() => client
      .from('worker_certifications')
      .update({'verified_by': session.userId, 'verified_at': DateTime.now().toUtc().toIso8601String()})
      .eq('id', certId));

  // ---- Partners ----

  @override
  Future<NpoPortalData> loadNpoPortal(AppSession session, DateTime from, DateTime to, {String? groupId}) => _guard(() async {
        final data = await client.rpc('npo_portal', params: {'p_from': dateOnly(from), 'p_to': dateOnly(to), 'p_group': groupId});
        return NpoPortalData.fromJson(_map(data));
      });

  @override
  Future<AgencyPortalData> loadAgencyPortal(AppSession session, DateTime from, DateTime to, {String? agencyId}) => _guard(() async {
        final data = await client.rpc('agency_portal', params: {'p_from': dateOnly(from), 'p_to': dateOnly(to), 'p_agency': agencyId});
        return AgencyPortalData.fromJson(_map(data));
      });
}
