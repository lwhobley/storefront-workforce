part of '../supabase_repository.dart';

/// Supabase implementation of [OperationsRepository]. Every change goes through the
/// database functions in 0021_checklists_incidents.sql, which check the person's scope.
/// Photos go to private buckets in one folder per run or incident; file names come from
/// the change id, so a retried upload finds the file already there.
mixin _SupabaseOperations on _SupabaseCore implements OperationsRepository {
  static const _checklistBucket = 'checklist-photos';
  static const _incidentBucket = 'incident-photos';

  Map<String, dynamic> _opsMap(Object? data) => (data as Map).cast<String, dynamic>();

  /// Uploads one photo. A file already at that path (an earlier try that lost its
  /// answer) counts as uploaded; photos are never replaced.
  Future<void> _uploadPhoto(String bucket, String path, Uint8List bytes) async {
    try {
      await client.storage.from(bucket).uploadBinary(path, bytes, fileOptions: const FileOptions(contentType: 'image/jpeg'));
    } on StorageException catch (e) {
      final m = e.message.toLowerCase();
      if (e.statusCode == '409' || m.contains('exist') || m.contains('duplicate')) return;
      final code = int.tryParse(e.statusCode ?? '');
      if (code != null && code >= 500) {
        throw const AppFailure('No connection. Your change is saved on this device.', offline: true);
      }
      throw AppFailure('The photo was refused: ${e.message}');
    }
  }

  Future<Uint8List?> _download(String bucket, String path) async {
    try {
      return await client.storage.from(bucket).download(path);
    } catch (_) {
      return null;
    }
  }

  // ---- Checklists ----

  @override
  Future<EventChecklists> loadEventChecklists(AppSession session, String eventId) =>
      _guard(() async => EventChecklists.fromJson(_opsMap(await client.rpc('event_checklists', params: {'p_event': eventId}))));

  @override
  Future<ChecklistRun> recordChecklistItem(AppSession session, ChecklistItemChange change, {List<Uint8List> photos = const []}) =>
      _guard(() async {
        final paths = <String>[];
        if (photos.isNotEmpty) {
          // The run's folder holds the photos, so start the run first (safe to repeat).
          final run = _opsMap(await client.rpc('start_checklist_run', params: {
            'p_event': change.eventId,
            'p_storefront': change.storefrontId,
            'p_template': change.templateId,
          }));
          for (var i = 0; i < photos.length; i++) {
            final path = '${session.venue.id}/${run['id']}/${change.id}-$i.jpg';
            await _uploadPhoto(_checklistBucket, path, photos[i]);
            paths.add(path);
          }
        }
        final data = await client.rpc('record_checklist_item', params: {
          'p': {...change.toJson(), 'photo_paths': paths},
        });
        return ChecklistRun.fromJson(_opsMap(data));
      });

  @override
  Future<ChecklistRun> signOffChecklist(String runId, {String note = ''}) =>
      _guard(() async => ChecklistRun.fromJson(_opsMap(await client.rpc('sign_off_checklist', params: {'p_run': runId, 'p_note': note}))));

  @override
  Future<ChecklistRun> reopenChecklist(String runId, String reason) =>
      _guard(() async => ChecklistRun.fromJson(_opsMap(await client.rpc('reopen_checklist', params: {'p_run': runId, 'p_reason': reason}))));

  @override
  Future<Uint8List?> downloadChecklistPhoto(String path) => _download(_checklistBucket, path);

  @override
  Future<List<ChecklistTemplate>> listChecklistTemplates(AppSession session) => _guard(() async {
        final data = await client.rpc('checklist_templates_list', params: {'p_venue': session.venue.id});
        return [for (final t in (data as List? ?? const [])) ChecklistTemplate.fromJson(_opsMap(t))];
      });

  @override
  Future<void> saveChecklistTemplate(AppSession session, ChecklistTemplate template) =>
      _guard(() => client.rpc('save_checklist_template', params: {'p': template.toJson(session.venue.id)}));

  // ---- Incidents ----

  @override
  Future<List<Incident>> listIncidents(AppSession session) => _guard(() async {
        final data = await client.rpc('incidents_list', params: {'p_venue': session.venue.id});
        return [for (final i in (data as List? ?? const [])) Incident.fromJson(_opsMap(i))];
      });

  @override
  Future<Incident> logIncident(AppSession session, IncidentDraft draft, {List<Uint8List> photos = const []}) => _guard(() async {
        var incident = Incident.fromJson(_opsMap(await client.rpc('log_incident', params: {'p': draft.toJson()})));
        if (photos.isNotEmpty) incident = await addIncidentPhotos(session, draft.id, draft.id, photos);
        return incident;
      });

  @override
  Future<Incident> addIncidentPhotos(AppSession session, String incidentId, String batchId, List<Uint8List> photos) => _guard(() async {
        final paths = <String>[];
        for (var i = 0; i < photos.length; i++) {
          final path = '${session.venue.id}/$incidentId/$batchId-$i.jpg';
          await _uploadPhoto(_incidentBucket, path, photos[i]);
          paths.add(path);
        }
        return Incident.fromJson(_opsMap(await client.rpc('add_incident_photos', params: {'p_incident': incidentId, 'p_paths': paths})));
      });

  @override
  Future<Incident> addIncidentNote(AppSession session, IncidentNoteDraft note) =>
      _guard(() async => Incident.fromJson(_opsMap(await client.rpc('add_incident_note', params: {'p': note.toJson()}))));

  @override
  Future<Incident> updateIncident(String incidentId, {IncidentStatus? status, String? assignedTo, bool unassign = false, String? closingNote}) =>
      _guard(() async => Incident.fromJson(_opsMap(await client.rpc('update_incident', params: {
            'p_incident': incidentId,
            'p_status': status?.code,
            'p_assigned_to': assignedTo,
            'p_closing_note': closingNote,
            'p_unassign': unassign,
          }))));

  @override
  Future<List<IncidentAssignee>> incidentAssignees(AppSession session, IncidentKind kind) => _guard(() async {
        final data = await client.rpc('incident_assignees', params: {'p_venue': session.venue.id, 'p_kind': kind.name});
        return [for (final a in (data as List? ?? const [])) IncidentAssignee.fromJson(_opsMap(a))];
      });

  @override
  Future<Uint8List?> downloadIncidentPhoto(String path) => _download(_incidentBucket, path);
}
