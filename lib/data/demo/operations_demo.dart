part of '../demo_repository.dart';

/// Demo (in-memory) implementation of [OperationsRepository]. Follows the same rules as
/// the database functions in 0021_checklists_incidents.sql: the same default templates,
/// the same scope checks (leads tick their own storefront; managers for the venue or the
/// level sign off), the same "same id twice is stored once" rule, and the same incident
/// visibility (employee incidents only for people who manage staff).
mixin _DemoOperations on _DemoCore implements OperationsRepository {
  bool _opsReady = false;
  final List<ChecklistTemplate> _opsTemplates = [];

  /// Runs as the database returns them (JSON), by id.
  final Map<String, Map<String, dynamic>> _opsRuns = {};

  /// Change ids already stored, with who sent them.
  final Map<String, String> _opsChangeIds = {};
  final Map<String, Uint8List> _opsPhotos = {};

  /// Incidents as the database returns them (JSON), by id, plus who reported each.
  final Map<String, Map<String, dynamic>> _opsIncidents = {};
  final Map<String, String> _opsNoteAuthors = {};

  static final Uint8List _samplePhoto = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAEAAAAAwCAIAAAAuKetIAAAAVUlEQVR42u3PsQ0AEAAAQeMolBKNSqE0gP0HsYBaiEu+/OZCTHlbbWPbbX8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAOA+YvTwdAAAAAAAAAAAAAMC/gAV2q7e5RaS/ogAAAABJRU5ErkJggg==');

  // ---- Access (same rules as the database) ----

  Set<String> _checklistScope(AppSession s) => _scope(s, {Perm.viewLive, Perm.manageSchedule});
  Set<String> _checklistEditScope(AppSession s) => _scope(s, {Perm.manageSchedule});

  bool _canSignOff(AppSession s, String storefrontId) {
    final sf = _arena.storefronts.where((f) => f.id == storefrontId).firstOrNull;
    if (sf == null) return false;
    return s.grants.any((g) =>
        g.permissions.contains(Perm.manageSchedule) && (g.scopeType == 'venue' || (g.scopeType == 'level' && g.scopeId == sf.levelId)));
  }

  bool _incidentVisible(Map<String, dynamic> i, AppSession s) {
    if (!s.can(Perm.viewLive) && !s.can(Perm.manageWorkers)) return false;
    if (i['reported_by'] == s.userId) return true;
    if (i['kind'] == 'employee') return s.canVenueWide(Perm.manageWorkers);
    if (s.canVenueWide(Perm.viewLive)) return true;
    final sf = i['storefront_id'] as String?;
    return sf != null && _scope(s, {Perm.viewLive}).contains(sf);
  }

  bool _canManageIncident(Map<String, dynamic> i, AppSession s) =>
      _incidentVisible(i, s) && (i['kind'] == 'employee' ? s.canVenueWide(Perm.manageWorkers) : s.canVenueWide(Perm.viewLive));

  String _nameOf(String userId) {
    for (final s in _sessionsByPin.values) {
      if (s.userId == userId) return s.displayName;
    }
    return '';
  }

  // ---- Sample data ----

  void _ensureOps() {
    if (_opsReady) return;
    _opsReady = true;
    _opsTemplates.addAll(_defaultTemplates());
    _seedChecklists();
    _seedIncidents();
  }

  int _tplSeq = 0;
  String _tplId() => 'cccccccc-0000-4000-8000-${(++_tplSeq).toRadixString(16).padLeft(12, '0')}';

  List<ChecklistTemplate> _defaultTemplates() {
    ChecklistTemplateItem item(String label, String help, int sort, {bool photo = false, List<String> kinds = const []}) =>
        ChecklistTemplateItem(id: _tplId(), label: label, help: help, photoRequired: photo, storefrontKinds: kinds, sort: sort);
    return [
      ChecklistTemplate(id: _tplId(), kind: ChecklistKind.opening, name: 'Opening', sort: 10, items: [
        item('All staff clocked in', 'Anyone missing is reported to a manager.', 10),
        item('Uniforms checked', 'Shirt, hat or visor, name badge. Photo of the crew.', 20, photo: true),
        item('Stations assigned', 'Everyone knows their station for the event.', 30),
        item('Lead briefing done', 'Event, menu changes, break order.', 40),
        item('TABC cards on hand', 'Every bartender and server has a current card.', 50, photo: true, kinds: const ['bar']),
        item('Food handler cards on hand', 'Every food worker has a current card.', 60, kinds: const ['permanent_stand', 'portable_cart', 'kiosk']),
      ]),
      ChecklistTemplate(id: _tplId(), kind: ChecklistKind.closing, name: 'Closing', sort: 20, items: [
        item('Breaks taken', 'Everyone got the breaks they were due.', 10),
        item('Staff sent home in order', 'Follow the send-home order on the live view.', 20),
        item('Station clean-up assigned', 'Each station has someone on clean-up.', 30),
        item('Clean-up checked', 'Photo of the finished stand.', 40, photo: true),
        item('All clocked out', 'No one left on the clock.', 50),
      ]),
    ];
  }

  Storefront? _storefront(String id) => _arena.storefronts.where((s) => s.id == id).firstOrNull;

  /// Starts a run in memory (no checks), like ensure_checklist_run().
  Map<String, dynamic> _ensureRun(String eventId, String storefrontId, String templateId, {String startedBy = ''}) {
    for (final r in _opsRuns.values) {
      if (r['event_id'] == eventId && r['storefront_id'] == storefrontId && r['template_id'] == templateId) return r;
    }
    final sf = _storefront(storefrontId);
    final t = _opsTemplates.where((t) => t.id == templateId && t.active).firstOrNull;
    if (sf == null || t == null) throw const AppFailure('Unknown checklist');
    if (!_events.containsKey(eventId)) throw const AppFailure('Unknown event');
    final id = _id();
    final run = <String, dynamic>{
      'id': id,
      'venue_id': _arena.venue.id,
      'event_id': eventId,
      'storefront_id': storefrontId,
      'template_id': templateId,
      'template_name': t.name,
      'template_kind': t.kind.name,
      'status': 'in_progress',
      'signed_off_by_name': '',
      'sign_off_note': '',
      'reopened_by_name': '',
      'reopen_reason': '',
      'items': [
        for (final i in t.itemsFor(sf.kind))
          <String, dynamic>{
            'id': _id(),
            'template_item_id': i.id,
            'label': i.label,
            'help': i.help,
            'photo_required': i.photoRequired,
            'sort': i.sort,
            'done': false,
            'done_by_name': '',
            'done_at': null,
            'note': '',
            'photo_paths': <String>[],
            'last_change_at': null,
          },
      ],
    };
    _opsRuns[id] = run;
    return run;
  }

  void _refreshStatus(Map<String, dynamic> run) {
    if (run['status'] == 'signed_off') return;
    final items = (run['items'] as List).cast<Map<String, dynamic>>();
    final open = items.where((i) => i['done'] != true || (i['photo_required'] == true && (i['photo_paths'] as List).isEmpty));
    run['status'] = open.isEmpty ? 'complete' : 'in_progress';
  }

  /// Ticks the first [count] items of a seeded run, with photos where needed.
  void _tick(Map<String, dynamic> run, int count, DateTime start, String by, {bool photos = true}) {
    final items = (run['items'] as List).cast<Map<String, dynamic>>();
    for (var n = 0; n < items.length && n < count; n++) {
      final i = items[n];
      final at = start.add(Duration(minutes: 4 * n));
      i['done'] = true;
      i['done_by_name'] = by;
      i['done_at'] = at.toIso8601String();
      i['last_change_at'] = at.toIso8601String();
      if (i['photo_required'] == true && photos) {
        final path = '${_arena.venue.id}/${run['id']}/seed-$n.jpg';
        _opsPhotos[path] = _samplePhoto;
        i['photo_paths'] = <String>[path];
      }
    }
    _refreshStatus(run);
  }

  void _signOff(Map<String, dynamic> run, DateTime at, String by, String note) {
    run['status'] = 'signed_off';
    run['signed_off_by_name'] = by;
    run['signed_off_at'] = at.toIso8601String();
    run['sign_off_note'] = note;
  }

  void _seedChecklists() {
    final live = liveEvent;
    final opening = _opsTemplates.first;
    final closing = _opsTemplates[1];
    final leadStorefront = _sessionsByPin['300003']?.grants.where((g) => g.scopeType == 'storefront').firstOrNull?.scopeId;
    const manager = 'Marcus Bell';
    if (live != null) {
      final open = [for (final f in _arena.storefronts) if (_openStorefronts[live.id]?.contains(f.id) ?? false) f.id];
      final start = live.callTime.add(const Duration(minutes: 5));
      final leadName = _sessionsByPin['300003']?.displayName ?? 'Lead';
      // The lead's storefront: well along, waiting on the last items.
      if (leadStorefront != null && open.contains(leadStorefront)) {
        final run = _ensureRun(live.id, leadStorefront, opening.id);
        _tick(run, (run['items'] as List).length - 2, start, leadName);
        final items = (run['items'] as List).cast<Map<String, dynamic>>();
        items[1]['note'] = 'Two visors short; borrowed from the bar.';
      }
      final others = open.where((id) => id != leadStorefront).toList();
      for (var n = 0; n < others.length && n < 6; n++) {
        final run = _ensureRun(live.id, others[n], opening.id);
        final total = (run['items'] as List).length;
        switch (n) {
          case 0 || 1:
            _tick(run, total, start, 'Crew lead');
            _signOff(run, start.add(const Duration(minutes: 40)), manager, n == 0 ? 'Good to go' : '');
          case 2:
            _tick(run, total, start, 'Crew lead');
          case 3:
            _tick(run, 2, start, 'Crew lead');
          default:
            _tick(run, 1, start, 'Crew lead', photos: false);
        }
      }
    }
    // The last finished event: both checklists done and signed off at a few storefronts.
    final past = _events.values.where((e) => e.status == EventStatus.completed && (live == null || e.startTime.isBefore(live.startTime))).toList()
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    if (past.isNotEmpty) {
      final e = past.first;
      final open = [for (final f in _arena.storefronts) if (_openStorefronts[e.id]?.contains(f.id) ?? false) f.id];
      for (final id in open.take(4)) {
        for (final t in [opening, closing]) {
          final run = _ensureRun(e.id, id, t.id);
          final at = t == opening ? e.callTime.add(const Duration(minutes: 5)) : (e.endTime ?? e.startTime.add(const Duration(hours: 3)));
          _tick(run, (run['items'] as List).length, at, 'Crew lead');
          _signOff(run, at.add(const Duration(minutes: 30)), manager, '');
        }
      }
    }
  }

  void _seedIncidents() {
    final live = liveEvent;
    final venue = _arena.venue.id;
    final leadStorefront = _sessionsByPin['300003']?.grants.where((g) => g.scopeType == 'storefront').firstOrNull?.scopeId;
    final past = _events.values.where((e) => e.status == EventStatus.completed).toList()..sort((a, b) => b.startTime.compareTo(a.startTime));
    final prev = past.firstOrNull;

    IncidentPerson? workerAt(String? eventId, String? storefrontId, {String? notRole}) {
      for (final s in _shifts.values) {
        if (s.eventId == eventId && s.storefrontId == storefrontId && s.workerId != null && s.jobRoleCode != notRole) {
          final w = _workers[s.workerId]!;
          return IncidentPerson(id: w.id, name: w.displayName, employeeNumber: w.employeeNumber);
        }
      }
      return null;
    }

    Map<String, dynamic> add({
      required String kind,
      required String severity,
      required Event? event,
      required String? storefrontId,
      required DateTime at,
      required String description,
      required String reportedBy,
      String status = 'open',
      List<IncidentPerson> people = const [],
      List<(String, String, String, Duration)> notes = const [],
      String? assignedTo,
      String closingNote = '',
      int photos = 0,
    }) {
      final id = _id();
      final paths = <String>[];
      for (var n = 0; n < photos; n++) {
        final path = '$venue/$id/seed-$n.jpg';
        _opsPhotos[path] = _samplePhoto;
        paths.add(path);
      }
      final j = <String, dynamic>{
        'id': id,
        'venue_id': venue,
        'kind': kind,
        'severity': severity,
        'event_id': event?.id,
        'event_name': event?.name ?? '',
        'storefront_id': storefrontId,
        'occurred_at': at.toIso8601String(),
        'description': description,
        'photo_paths': paths,
        'status': status,
        'assigned_to': assignedTo,
        'assigned_to_name': assignedTo == null ? '' : _nameOf(assignedTo),
        'closing_note': closingNote,
        'closed_at': status == 'closed' ? at.add(const Duration(days: 1)).toIso8601String() : null,
        'closed_by_name': status == 'closed' ? 'Dana Whitfield' : '',
        'reported_by': reportedBy,
        'reported_by_name': _nameOf(reportedBy),
        'created_at': at.add(const Duration(minutes: 6)).toIso8601String(),
        'people': [for (final p in people) {'id': p.id, 'name': p.name, 'employee_number': p.employeeNumber}],
        'notes': [
          for (final (kind, body, author, after) in notes)
            {'id': _id(), 'kind': kind, 'body': body, 'author_name': author, 'created_at': at.add(after).toIso8601String()},
        ],
      };
      _opsIncidents[id] = j;
      return j;
    }

    if (live != null) {
      final open = [for (final f in _arena.storefronts) if (_openStorefronts[live.id]?.contains(f.id) ?? false) f.id];
      final other = open.where((id) => id != leadStorefront).firstOrNull;
      final cook = workerAt(live.id, other, notRole: 'lead');
      add(
        kind: 'injury',
        severity: 'medium',
        event: live,
        storefrontId: other,
        at: live.callTime.add(const Duration(minutes: 70)),
        description: 'Cook burned forearm on the fryer basket. First aid at the stand (cool water, burn gel). Kept working at the register.',
        reportedBy: 'demo-manager',
        status: 'following_up',
        people: [?cook],
        assignedTo: 'demo-manager',
        photos: 1,
        notes: const [
          ('assigned', 'Follow-up: Marcus Bell', 'Marcus Bell', Duration(minutes: 10)),
          ('note', 'Fryer basket handle is loose. Asked maintenance to look at it before Friday.', 'Marcus Bell', Duration(minutes: 25)),
        ],
      );
      if (leadStorefront != null) {
        add(
          kind: 'safety',
          severity: 'low',
          event: live,
          storefrontId: leadStorefront,
          at: live.callTime.add(const Duration(minutes: 95)),
          description: 'Ice spilled behind the counter; floor wet near the register. Mopped and put out a wet-floor sign.',
          reportedBy: 'demo-lead',
        );
      }
    }
    if (prev != null) {
      final open = [for (final f in _arena.storefronts) if (_openStorefronts[prev.id]?.contains(f.id) ?? false) f.id];
      final sf = open.length > 2 ? open[2] : open.firstOrNull;
      final person = workerAt(prev.id, sf, notRole: 'lead');
      add(
        kind: 'employee',
        severity: 'high',
        event: prev,
        storefrontId: sf,
        at: prev.callTime.add(const Duration(minutes: 30)),
        description: 'No call, no show for the second time this month. Called twice, no answer.',
        reportedBy: 'demo-admin',
        people: [?person],
        notes: const [('note', 'Left a voicemail asking them to come see me before next shift.', 'Dana Whitfield', Duration(hours: 20))],
      );
      add(
        kind: 'safety',
        severity: 'medium',
        event: prev,
        storefrontId: open.length > 3 ? open[3] : null,
        at: prev.startTime.add(const Duration(minutes: 50)),
        description: 'Portable cart wheel cracked; cart tipped when moved. No one hurt.',
        reportedBy: 'demo-manager',
        status: 'closed',
        closingNote: 'Wheel replaced. Carts checked before each event now.',
        notes: const [
          ('status', 'Status: Closed', 'Dana Whitfield', Duration(days: 1)),
        ],
      );
      add(
        kind: 'other',
        severity: 'low',
        event: prev,
        storefrontId: null,
        at: (prev.endTime ?? prev.startTime.add(const Duration(hours: 3))).add(const Duration(minutes: 20)),
        description: 'Two radios not returned at end of night. Found in the lost and found the next morning.',
        reportedBy: 'demo-admin',
        status: 'closed',
        closingNote: 'Radios back. Radio sign-out sheet added to the closing checklist talk.',
      );
    }
  }

  // ---- Checklists ----

  @override
  Future<EventChecklists> loadEventChecklists(AppSession session, String eventId) => _delay(() {
        _ensureOps();
        final me = _me;
        final scope = _checklistScope(me);
        if (scope.isEmpty) throw const AppFailure('Not authorized');
        final edit = _checklistEditScope(me);
        final open = [
          for (final f in [..._arena.storefronts]..sort((a, b) => a.code.compareTo(b.code)))
            if (f.active && scope.contains(f.id) && (_openStorefronts[eventId]?.contains(f.id) ?? false)) f.id,
        ];
        return EventChecklists(
          eventId: eventId,
          storefrontIds: open,
          templates: [for (final t in _opsTemplates) if (t.active) t],
          runs: [for (final r in _opsRuns.values) if (r['event_id'] == eventId && scope.contains(r['storefront_id'])) ChecklistRun.fromJson(r)],
          editStorefrontIds: edit,
          signOffStorefrontIds: {for (final id in scope) if (_canSignOff(me, id)) id},
        );
      });

  @override
  Future<ChecklistRun> recordChecklistItem(AppSession session, ChecklistItemChange change, {List<Uint8List> photos = const []}) => _delay(() {
        _ensureOps();
        final me = _me;
        final seen = _opsChangeIds[change.id];
        if (seen != null) {
          if (seen != me.userId) throw const AppFailure('Change id already used');
          final run = _opsRuns.values.firstWhere((r) => r['event_id'] == change.eventId && r['storefront_id'] == change.storefrontId && r['template_id'] == change.templateId);
          return ChecklistRun.fromJson(run);
        }
        if (!_checklistEditScope(me).contains(change.storefrontId)) throw const AppFailure('Not authorized for this storefront');
        final run = _ensureRun(change.eventId, change.storefrontId, change.templateId, startedBy: me.userId);
        if (run['status'] == 'signed_off') throw const AppFailure('This checklist is signed off. A manager can reopen it.');
        final item = (run['items'] as List).cast<Map<String, dynamic>>().where((i) => i['template_item_id'] == change.templateItemId).firstOrNull;
        if (item == null) throw const AppFailure('This item is not on this checklist');
        final paths = <String>{...(item['photo_paths'] as List).cast<String>()};
        final newPaths = [for (var i = 0; i < photos.length; i++) '${_arena.venue.id}/${run['id']}/${change.id}-$i.jpg'];
        final all = {...paths, ...newPaths};
        if (all.length > 6) throw const AppFailure('Up to 6 photos per item');
        if (change.done && item['photo_required'] == true && all.isEmpty) throw AppFailure('Add a photo for "${item['label']}" first');
        final now = DateTime.now().toUtc();
        final at = change.occurredAt.isAfter(now) ? now : change.occurredAt;
        final last = item['last_change_at'] == null ? null : DateTime.parse(item['last_change_at'] as String);
        final applied = last == null || !at.isBefore(last);
        for (var i = 0; i < photos.length; i++) {
          _opsPhotos[newPaths[i]] = photos[i];
        }
        _opsChangeIds[change.id] = me.userId;
        item['photo_paths'] = all.toList()..sort();
        if (applied) {
          item['done'] = change.done;
          item['done_by_name'] = change.done ? me.displayName : '';
          item['done_at'] = change.done ? at.toIso8601String() : null;
          if (change.note != null) item['note'] = change.note!.trim();
          item['last_change_at'] = at.toIso8601String();
        }
        _refreshStatus(run);
        return ChecklistRun.fromJson(run);
      });

  Map<String, dynamic> _runForSignOff(String runId) {
    _ensureOps();
    final run = _opsRuns[runId];
    if (run == null || !_canSignOff(_me, run['storefront_id'] as String)) throw const AppFailure('Only a manager can sign off');
    return run;
  }

  @override
  Future<ChecklistRun> signOffChecklist(String runId, {String note = ''}) => _delay(() {
        final run = _runForSignOff(runId);
        _refreshStatus(run);
        if (run['status'] == 'signed_off') throw const AppFailure('Already signed off');
        if (run['status'] != 'complete') throw const AppFailure('Finish every item (and its photos) before signing off');
        _signOff(run, DateTime.now().toUtc(), _me.displayName, note.trim());
        return ChecklistRun.fromJson(run);
      });

  @override
  Future<ChecklistRun> reopenChecklist(String runId, String reason) => _delay(() {
        final run = _runForSignOff(runId);
        if (run['status'] != 'signed_off') throw const AppFailure('This checklist is not signed off');
        if (reason.trim().isEmpty) throw const AppFailure('Give a reason');
        run['status'] = 'in_progress';
        run['signed_off_by_name'] = '';
        run['signed_off_at'] = null;
        run['sign_off_note'] = '';
        run['reopened_by_name'] = _me.displayName;
        run['reopened_at'] = DateTime.now().toUtc().toIso8601String();
        run['reopen_reason'] = reason.trim();
        _refreshStatus(run);
        return ChecklistRun.fromJson(run);
      });

  @override
  Future<Uint8List?> downloadChecklistPhoto(String path) => _delay(() => _opsPhotos[path]);

  @override
  Future<List<ChecklistTemplate>> listChecklistTemplates(AppSession session) => _delay(() {
        _ensureOps();
        if (!session.can(Perm.viewLive) && !session.can(Perm.manageSchedule)) throw const AppFailure('Not authorized');
        return [..._opsTemplates]..sort((a, b) => a.sort.compareTo(b.sort));
      });

  @override
  Future<void> saveChecklistTemplate(AppSession session, ChecklistTemplate template) => _delay(() {
        _ensureOps();
        if (!_me.canVenueWide(Perm.manageSchedule)) throw const AppFailure('Not authorized');
        if (template.items.isEmpty) throw const AppFailure('Add at least one item');
        if (template.name.trim().isEmpty || template.items.any((i) => i.label.trim().isEmpty)) throw const AppFailure('Every item needs a label');
        if (_opsTemplates.any((t) => t.id != template.id && t.name.toLowerCase() == template.name.trim().toLowerCase())) {
          throw const AppFailure('A checklist with this name already exists');
        }
        var sort = 0;
        final saved = ChecklistTemplate(
          id: template.id.isEmpty ? _tplId() : template.id,
          kind: template.kind,
          name: template.name.trim(),
          sort: template.id.isEmpty ? 100 + _opsTemplates.length : template.sort,
          active: template.active,
          items: [
            for (final i in template.items)
              ChecklistTemplateItem(
                id: i.id.isEmpty ? _tplId() : i.id,
                label: i.label.trim(),
                help: i.help.trim(),
                photoRequired: i.photoRequired,
                storefrontKinds: i.storefrontKinds,
                sort: sort += 10,
              ),
          ],
        );
        final at = _opsTemplates.indexWhere((t) => t.id == saved.id);
        if (at < 0) {
          _opsTemplates.add(saved);
        } else {
          _opsTemplates[at] = saved;
        }
      });

  // ---- Incidents ----

  @override
  Future<List<Incident>> listIncidents(AppSession session) => _delay(() {
        _ensureOps();
        final me = _me;
        if (!me.can(Perm.viewLive)) throw const AppFailure('Not authorized');
        final list = [for (final i in _opsIncidents.values) if (_incidentVisible(i, me)) Incident.fromJson(i)]
          ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
        return list;
      });

  void _notifyIncident(Map<String, dynamic> i, String title, String body, {String? only}) {
    final kind = i['kind'] as String;
    final sent = <String>{};
    for (final s in _sessionsByPin.values) {
      if (s.isKiosk || s.userId == _me.userId || !sent.add(s.userId)) continue;
      if (only != null && s.userId != only) continue;
      final ok = only != null || (kind == 'employee' ? s.canVenueWide(Perm.manageWorkers) : s.canVenueWide(Perm.viewLive));
      if (ok) _notifyUser(s.userId, kind: 'incident', title: title, body: body, link: '/incidents');
    }
  }

  static String _kindLabel(String kind) => switch (kind) {
        'injury' => 'Injury',
        'safety' => 'Safety issue',
        'employee' => 'Employee incident',
        _ => 'Incident',
      };

  @override
  Future<Incident> logIncident(AppSession session, IncidentDraft draft, {List<Uint8List> photos = const []}) async {
    final incident = await _delay(() {
      _ensureOps();
      final me = _me;
      final existing = _opsIncidents[draft.id];
      if (existing != null) {
        if (existing['reported_by'] != me.userId) throw const AppFailure('Incident id already used');
        return Incident.fromJson(existing);
      }
      if (draft.storefrontId == null) {
        if (!me.canVenueWide(Perm.viewLive)) throw const AppFailure('Choose your storefront');
      } else if (!_scope(me, {Perm.viewLive}).contains(draft.storefrontId)) {
        throw const AppFailure('Not authorized for this storefront');
      }
      if (draft.description.trim().isEmpty) throw const AppFailure('Describe what happened');
      if (draft.people.any((p) => !_workers.containsKey(p.id))) throw const AppFailure('Unknown person');
      final now = DateTime.now().toUtc();
      final at = draft.occurredAt.isAfter(now) ? now : draft.occurredAt;
      final event = draft.eventId == null ? null : _events[draft.eventId];
      final j = <String, dynamic>{
        'id': draft.id,
        'venue_id': _arena.venue.id,
        'kind': draft.kind.name,
        'severity': draft.severity.name,
        'event_id': event?.id,
        'event_name': event?.name ?? '',
        'storefront_id': draft.storefrontId,
        'occurred_at': at.toIso8601String(),
        'description': draft.description.trim(),
        'photo_paths': <String>[],
        'status': 'open',
        'assigned_to': null,
        'assigned_to_name': '',
        'closing_note': '',
        'closed_at': null,
        'closed_by_name': '',
        'reported_by': me.userId,
        'reported_by_name': me.displayName,
        'created_at': now.toIso8601String(),
        'people': [for (final p in draft.people) {'id': p.id, 'name': p.name, 'employee_number': p.employeeNumber}],
        'notes': <Map<String, dynamic>>[],
      };
      _opsIncidents[draft.id] = j;
      if (draft.kind == IncidentKind.injury || draft.severity == IncidentSeverity.high) {
        final where = _storefront(draft.storefrontId ?? '')?.name;
        _notifyIncident(j, '${_kindLabel(draft.kind.name)} reported${where == null ? '' : ' at $where'}',
            '${draft.severity == IncidentSeverity.high ? 'High severity. ' : ''}Open Incidents for details.');
      }
      return Incident.fromJson(j);
    });
    if (photos.isEmpty) return incident;
    return addIncidentPhotos(session, draft.id, draft.id, photos);
  }

  Map<String, dynamic> _visibleIncident(String id) {
    _ensureOps();
    final i = _opsIncidents[id];
    if (i == null || !_incidentVisible(i, _me)) throw const AppFailure('Not authorized');
    return i;
  }

  void _timeline(Map<String, dynamic> i, String kind, String body, {String? id}) {
    (i['notes'] as List).add({
      'id': id ?? _id(),
      'kind': kind,
      'body': body,
      'author_name': _me.displayName,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  @override
  Future<Incident> addIncidentPhotos(AppSession session, String incidentId, String batchId, List<Uint8List> photos) => _delay(() {
        final i = _visibleIncident(incidentId);
        final paths = [for (var n = 0; n < photos.length; n++) '${_arena.venue.id}/$incidentId/$batchId-$n.jpg'];
        final before = (i['photo_paths'] as List).cast<String>();
        final all = {...before, ...paths}.toList()..sort();
        final added = all.length - before.length;
        if (added == 0) return Incident.fromJson(i);
        if (i['status'] == 'closed') throw const AppFailure('This incident is closed');
        if (all.length > 12) throw const AppFailure('Up to 12 photos per incident');
        for (var n = 0; n < photos.length; n++) {
          _opsPhotos[paths[n]] = photos[n];
        }
        i['photo_paths'] = all;
        _timeline(i, 'photos', added == 1 ? 'Added a photo' : 'Added $added photos');
        return Incident.fromJson(i);
      });

  @override
  Future<Incident> addIncidentNote(AppSession session, IncidentNoteDraft note) => _delay(() {
        _ensureOps();
        final author = _opsNoteAuthors[note.id];
        if (author != null) {
          if (author != _me.userId) throw const AppFailure('Note id already used');
          return Incident.fromJson(_opsIncidents[note.incidentId]!);
        }
        final i = _visibleIncident(note.incidentId);
        if (i['status'] == 'closed') throw const AppFailure('This incident is closed. Reopen it to add notes.');
        if (note.body.trim().isEmpty) throw const AppFailure('Write a note');
        _opsNoteAuthors[note.id] = _me.userId;
        _timeline(i, 'note', note.body.trim(), id: note.id);
        if (i['status'] == 'open') i['status'] = 'following_up';
        return Incident.fromJson(i);
      });

  @override
  Future<Incident> updateIncident(String incidentId, {IncidentStatus? status, String? assignedTo, bool unassign = false, String? closingNote}) =>
      _delay(() {
        final i = _visibleIncident(incidentId);
        final me = _me;
        if (!_canManageIncident(i, me)) throw const AppFailure('Not authorized');
        if (assignedTo != null && assignedTo != i['assigned_to']) {
          final target = _sessionsByPin.values.where((s) => s.userId == assignedTo).firstOrNull;
          if (target == null || !_incidentVisible(i, target)) throw const AppFailure('That person cannot see this incident');
          i['assigned_to'] = assignedTo;
          i['assigned_to_name'] = target.displayName;
          _timeline(i, 'assigned', 'Follow-up: ${target.displayName}');
          _notifyIncident(i, 'You own the follow-up on an incident', '${_kindLabel(i['kind'] as String)}. Open Incidents for details.', only: assignedTo);
        } else if (unassign && i['assigned_to'] != null) {
          i['assigned_to'] = null;
          i['assigned_to_name'] = '';
          _timeline(i, 'assigned', 'No follow-up owner');
        }
        if (status != null && status.code != i['status']) {
          final wasClosed = i['status'] == 'closed';
          if (status == IncidentStatus.closed) {
            if ((closingNote ?? '').trim().isEmpty) throw const AppFailure('Add a closing note');
            i['closing_note'] = closingNote!.trim();
            i['closed_at'] = DateTime.now().toUtc().toIso8601String();
            i['closed_by_name'] = me.displayName;
          } else {
            i['closed_at'] = null;
            i['closed_by_name'] = '';
          }
          i['status'] = status.code;
          _timeline(i, 'status', wasClosed ? 'Reopened: ${status.label}' : 'Status: ${status.label}');
        }
        return Incident.fromJson(i);
      });

  @override
  Future<List<IncidentAssignee>> incidentAssignees(AppSession session, IncidentKind kind) => _delay(() {
        if (!_me.canVenueWide(Perm.viewLive)) throw const AppFailure('Not authorized');
        final seen = <String>{};
        return [
          for (final s in _sessionsByPin.values)
            if (!s.isKiosk && seen.add(s.userId) && (kind == IncidentKind.employee ? s.canVenueWide(Perm.manageWorkers) : s.canVenueWide(Perm.viewLive)))
              IncidentAssignee(userId: s.userId, name: s.displayName),
        ]..sort((a, b) => a.name.compareTo(b.name));
      });

  @override
  Future<Uint8List?> downloadIncidentPhoto(String path) => _delay(() => _opsPhotos[path]);
}
