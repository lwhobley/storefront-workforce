part of '../demo_repository.dart';

/// Demo (in-memory) implementation of [PeopleRepository]. Follows the same rules as the
/// database functions in 0014_onboarding_partners.sql: the same default steps, the same
/// "step finishes itself" logic, and the same checks on what a person may submit.
mixin _DemoPeople on _DemoCore implements PeopleRepository {
  // ---- State ----
  bool _peopleReady = false;
  final List<_DemoStep> _onbSteps = [];
  final List<OnboardingDocument> _onbDocs = [];

  /// worker id -> step code -> progress (JSON shaped like onboarding_progress).
  final Map<String, Map<String, Map<String, dynamic>>> _onbProgress = {};

  /// worker id -> when they were added (onboarding starts then).
  final Map<String, DateTime> _addedAt = {};

  /// When a document's text last changed (people who signed before sign again).
  final Map<String, DateTime> _docUpdatedAt = {};

  /// Uploaded files by path.
  final Map<String, Uint8List> _onbFiles = {};

  /// Cards people uploaded that no manager has checked yet, by certification id.
  final Map<String, CertRecord> _pendingCerts = {};
  final Map<String, String> _certPaths = {};

  /// Partner contacts' demo sign-ins.
  final Map<String, AppSession> _partnerSessions = {};

  DateTime get _peopleNow => DateTime.now().toUtc();
  VenueRules get _venueRules => VenueRules.fromJson(_arena.venue.settings);
  String get _tz => _arena.venue.timeZone;
  DateTime get _today => venueDate(_peopleNow, _tz);

  // ---- Sign-in: NPO coordinator and agency contact personas ----

  void _ensurePartnerSessions() {
    if (_partnerSessions.isNotEmpty) return;
    final venue = _arena.venue;
    final group = _arena.npoGroups.firstOrNull;
    final agency = _arena.agencies.firstOrNull;
    if (group != null) {
      _partnerSessions['600006'] = AppSession(
        userId: 'demo-npo-coordinator',
        displayName: group.coordinatorName.isEmpty ? 'NPO Coordinator' : group.coordinatorName,
        venue: venue,
        grants: [RoleGrant(roleCode: 'npo_coordinator', permissions: const {'npo_portal'}, scopeType: 'npo_group', scopeId: group.id)],
      );
    }
    if (agency != null) {
      _partnerSessions['700007'] = AppSession(
        userId: 'demo-agency-contact',
        displayName: agency.contactName.isEmpty ? 'Agency Contact' : agency.contactName,
        venue: venue,
        grants: [RoleGrant(roleCode: 'agency_contact', permissions: const {'agency_portal'}, scopeType: 'agency', scopeId: agency.id)],
      );
    }
  }

  @override
  Future<AppSession> signInWithPin(String pin) {
    _ensurePartnerSessions();
    final partner = _partnerSessions[pin];
    if (partner != null) return _delay(() => _session = partner);
    return super.signInWithPin(pin);
  }

  /// A new person's PIN signs them in too, so the demo can walk through their onboarding.
  @override
  Future<String> issuePin(AppSession session, Worker worker) async {
    final pin = await super.issuePin(session, worker);
    _sessionsByPin.putIfAbsent(
      pin,
      () => AppSession(
        userId: 'demo-${worker.id}',
        displayName: worker.displayName,
        venue: _arena.venue,
        workerId: worker.id,
        language: worker.preferredLanguage,
        grants: [RoleGrant(roleCode: 'employee', permissions: const {'punch_self'})],
      ),
    );
    final w = _workers[worker.id];
    if (w != null && w.userId == null) _workers[w.id] = _withUser(w, 'demo-${worker.id}');
    return pin;
  }

  // ---- Seed ----

  void _ensurePeople() {
    if (_peopleReady) return;
    _peopleReady = true;
    _onbSteps.addAll(_DemoStep.defaults);
    _onbDocs.addAll(const [
      OnboardingDocument(
        id: 'doc-handbook',
        stepCode: 'policies',
        title: 'Employee handbook acknowledgment',
        body: 'I have received the Pecan Valley concessions handbook. I will follow it, including attendance, '
            'cash handling, food safety, and alcohol service rules, and I will ask my manager when something is unclear.',
        sort: 1,
      ),
      OnboardingDocument(
        id: 'doc-uniform',
        version: 2,
        stepCode: 'policies',
        title: 'Uniform and appearance policy',
        body: 'Black pants, closed-toe non-slip shoes, the venue shirt and hat, hair tied back at food stations, '
            'name badge visible. No personal phones at the register.',
        sort: 2,
      ),
      OnboardingDocument(
        id: 'doc-waiver',
        version: 2,
        stepCode: 'waiver',
        title: 'Volunteer waiver and release',
        appliesTo: ['npo'],
        body: 'I volunteer with my nonprofit group and am not an employee of the venue. I will follow the venue\'s '
            'safety rules and my group coordinator\'s directions. Volunteers under 18 need a parent or guardian to sign too.',
        sort: 1,
      ),
    ]);

    final now = _arena.now;
    _docUpdatedAt['doc-uniform'] = now.subtract(const Duration(days: 5));
    _docUpdatedAt['doc-waiver'] = now.subtract(const Duration(days: 5));
    for (final w in _workers.values) {
      _addedAt[w.id] = (w.hireDate ?? now.subtract(const Duration(days: 400))).add(const Duration(hours: 15));
    }

    // A few new hires part way through; everyone else finished when they started.
    final personaWorkers = {for (final s in _sessionsByPin.values) ?s.workerId};
    final newest = [for (final w in _workers.values) if (!personaWorkers.contains(w.id) && w.status == 'active') w]
      ..sort((a, b) => (b.hireDate ?? DateTime(2000)).compareTo(a.hireDate ?? DateTime(2000)));
    Worker? pick(bool Function(Worker) test) {
      final w = newest.where(test).firstOrNull;
      if (w != null) newest.remove(w);
      return w;
    }

    bool needsCard(Worker w) => _requiredCerts(w).isNotEmpty;
    final reviewHire = pick((w) => w.type == WorkerType.regular && needsCard(w));
    final overdueHire = pick((w) => w.type == WorkerType.regular);
    final freshHire = pick((w) => w.type == WorkerType.regular);
    final tempHire = pick((w) => w.type == WorkerType.temp);
    final firstGroup = _arena.npoGroups.firstOrNull?.id;
    final minorVolunteer = pick((w) => w.type == WorkerType.npo && w.npoGroupId == firstGroup && _isMinor(w)) ??
        pick((w) => w.type == WorkerType.npo && w.npoGroupId == firstGroup);
    final npoHire = pick((w) => w.type == WorkerType.npo && w.npoGroupId == firstGroup);
    final newHires = {?reviewHire?.id, ?overdueHire?.id, ?freshHire?.id, ?tempHire?.id, ?minorVolunteer?.id, ?npoHire?.id};

    for (final w in _workers.values) {
      if (newHires.contains(w.id)) continue;
      final t = _addedAt[w.id]!;
      _completeAll(w, t);
    }
    // The uniform policy and the waiver were updated this season (version 2). The
    // English employee persona signed the old version and has to sign again.
    final persona = _sessionsByPin['400004']?.workerId;
    if (persona != null) {
      for (final step in const ['policies', 'waiver']) {
        final acks = ((_onbProgress[persona]?[step]?['data'] as Map?)?['acknowledgments'] as List?) ?? const [];
        for (final a in acks.cast<Map>()) {
          if (a['document_id'] == 'doc-uniform' || a['document_id'] == 'doc-waiver') a['version'] = 1;
        }
      }
    }

    void started(Worker? w, int daysAgo) {
      if (w != null) _addedAt[w.id] = now.subtract(Duration(days: daysAgo, hours: 3));
    }

    if (reviewHire != null) {
      started(reviewHire, 2);
      final t = _addedAt[reviewHire.id]!;
      _seedApplication(reviewHire, t.add(const Duration(hours: 5)));
      _seedAcks(reviewHire, 'policies', t.add(const Duration(hours: 6)));
      // Their card is a photo waiting for a manager.
      final type = _requiredCerts(reviewHire).first;
      final path = '${_arena.venue.id}/${reviewHire.id}/$type-card.jpg';
      final certId = 'cert-upload-${reviewHire.id}';
      final expires = DateTime.utc(now.year + 2, now.month, 1);
      final cert = CertRecord(id: certId, workerId: reviewHire.id, typeCode: type, number: type == 'tabc' ? 'TABC-5582140' : 'FHC-448201', expiresOn: expires, documentPath: path, verified: false);
      _pendingCerts[certId] = cert;
      _certPaths[certId] = path;
      _workers[reviewHire.id] = reviewHire.copyWith(certifications: [
        for (final c in reviewHire.certifications) if (c.typeCode != type) c,
        WorkerCertification(id: certId, workerId: reviewHire.id, typeCode: type, number: cert.number, expiresOn: expires),
      ]);
      _setProgress(reviewHire.id, 'certifications', {
        'status': 'submitted',
        'data': {
          'certs': [
            {'id': certId, 'cert_type_code': type, 'number': cert.number, 'expires_on': dateOnly(expires), 'file_path': path},
          ],
        },
        'file_paths': [path],
        'submitted_at': t.add(const Duration(hours: 7)),
      });
    }
    if (overdueHire != null) {
      started(overdueHire, 9);
      _seedApplication(overdueHire, _addedAt[overdueHire.id]!.add(const Duration(days: 1)));
    }
    started(freshHire, 1);
    if (tempHire != null) {
      started(tempHire, 5);
      final t = _addedAt[tempHire.id]!;
      _seedAcks(tempHire, 'policies', t.add(const Duration(hours: 4)));
      _setProgress(tempHire.id, 'training', {
        'status': 'not_started',
        'data': {
          'items': {
            'cash_handling': {'at': t.add(const Duration(days: 1)).toIso8601String(), 'by': 'demo-manager'},
          },
        },
        'submitted_at': t.add(const Duration(days: 1)),
        'reviewed_at': t.add(const Duration(days: 1)),
      });
    }
    started(minorVolunteer, 4);
    if (npoHire != null) {
      started(npoHire, 3);
      _seedAcks(npoHire, 'waiver', _addedAt[npoHire.id]!.add(const Duration(hours: 2)));
    }
  }

  Worker _withUser(Worker w, String userId) => Worker.fromJson({...w.toJson(), 'user_id': userId});

  void _setProgress(String workerId, String step, Map<String, dynamic> p) {
    final row = {
      'status': 'not_started',
      'data': <String, dynamic>{},
      'file_paths': <String>[],
      'note': '',
      ...p,
    };
    for (final k in ['submitted_at', 'reviewed_at']) {
      if (row[k] is DateTime) row[k] = (row[k] as DateTime).toUtc().toIso8601String();
    }
    row['updated_at'] = _peopleNow.toIso8601String();
    _onbProgress.putIfAbsent(workerId, () => {})[step] = row;
  }

  void _seedApplication(Worker w, DateTime at) => _setProgress(w.id, 'application', {
        'status': 'complete',
        'data': {
          'phone': w.phone,
          'email': w.email,
          'emergency_contact_name': w.emergencyContactName,
          'emergency_contact_phone': w.emergencyContactPhone,
          'uniform_size': w.uniformSize,
          'preferred_language': w.preferredLanguage,
          'address': '',
        },
        'submitted_at': at,
      });

  void _seedAcks(Worker w, String step, DateTime at) {
    final minor = _isMinor(w);
    _setProgress(w.id, step, {
      'status': 'complete',
      'data': {
        'acknowledgments': [
          for (final d in _docsFor(w, step))
            {
              'document_id': d.id,
              'title': d.title,
              'version': d.version,
              'typed_name': '${w.firstName} ${w.lastName}',
              if (minor && step == 'waiver') 'guardian_name': 'Parent of ${w.firstName}',
              'at': at.toIso8601String(),
            },
        ],
      },
      'submitted_at': at,
    });
  }

  void _completeAll(Worker w, DateTime t) {
    for (final s in _onbSteps.where((s) => s.appliesTo.contains(w.type.code))) {
      final at = t.add(Duration(days: 1 + s.sort ~/ 20));
      switch (s.code) {
        case 'application':
          _seedApplication(w, at);
        case 'policies' || 'waiver':
          _seedAcks(w, s.code, at);
        case 'training':
          _setProgress(w.id, 'training', {
            'status': 'complete',
            'data': {
              'items': {for (final i in _itemsFor(w, s)) i.code: {'at': at.toIso8601String(), 'by': 'demo-manager'}},
            },
            'submitted_at': at,
            'reviewed_at': at,
          });
        case 'paycom':
          _setProgress(w.id, 'paycom', {
            'status': 'complete',
            'data': {'completed_on': dateOnly(at), 'by': 'demo-manager'},
            'submitted_at': at,
            'reviewed_at': at,
          });
      }
    }
  }

  // ---- Rules shared with the database (onboarding_state) ----

  bool _isMinor(Worker w) {
    final age = w.ageOn(_today);
    return age != null && age < _venueRules.minors.adultAge;
  }

  List<String> _requiredCerts(Worker w) {
    final out = <String>{};
    for (final r in w.jobRoles) {
      out.addAll(_arena.jobRoles.where((j) => j.code == r).firstOrNull?.requiredCertifications ?? const []);
    }
    return out.toList()..sort();
  }

  List<OnboardingDocument> _docsFor(Worker w, String step) =>
      [for (final d in _onbDocs) if (d.active && d.stepCode == step && d.appliesTo.contains(w.type.code)) d]..sort((a, b) => a.sort.compareTo(b.sort));

  List<ChecklistItem> _itemsFor(Worker w, _DemoStep s) => [
        for (final i in s.items)
          if (i.roles.isEmpty || i.roles.any(w.jobRoles.contains)) i,
      ];

  Map<String, dynamic> _stateJson(Worker w, {bool detail = false}) {
    final today = _today;
    final minor = _isMinor(w);
    final reqCerts = _requiredCerts(w);
    final progress = _onbProgress[w.id] ?? const {};
    final steps = <Map<String, dynamic>>[];
    final missing = <String>[];
    var done = 0, required = 0;
    var review = false;
    DateTime? last;
    final started = _addedAt[w.id] ?? _arena.now;
    // When the earliest outstanding requirement became outstanding (as in the database).
    DateTime? openSince;
    DateTime later(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

    for (final s in [..._onbSteps]..sort((a, b) => a.sort.compareTo(b.sort))) {
      if (!s.appliesTo.contains(w.type.code)) continue;
      final p = progress[s.code];
      var status = (p?['status'] as String?) ?? 'not_started';
      final extra = <String, dynamic>{};
      DateTime? moment;
      if (s.kind == StepKind.document) {
        final docs = _docsFor(w, s.code);
        if (docs.isEmpty) continue;
        final acks = ((p?['data'] as Map?)?['acknowledgments'] as List?) ?? const [];
        final missingDocs = [
          for (final d in docs)
            if (!acks.any((a) => (a as Map)['document_id'] == d.id && ((a['version'] as int?) ?? 1) >= d.version)) d,
        ];
        if (missingDocs.isEmpty) {
          status = 'complete';
        } else if (status == 'complete' || status == 'approved') {
          status = 'not_started';
        }
        for (final d in missingDocs) {
          final signedOlder = acks.any((a) => (a as Map)['document_id'] == d.id);
          final t = signedOlder ? later(_docUpdatedAt[d.id] ?? started, started) : started;
          if (moment == null || t.isBefore(moment)) moment = t;
        }
        extra.addAll({
          'documents': [for (final d in docs) {'id': d.id, 'title': d.title, 'version': d.version}],
          'missing_documents': [for (final d in missingDocs) {'id': d.id, 'title': d.title, 'version': d.version}],
          'guardian_required': s.config['guardian_for_minors'] == true && minor,
          'birth_date_on_file': w.dateOfBirth != null,
        });
      } else if (s.kind == StepKind.upload) {
        if (reqCerts.isEmpty) continue;
        final missingCerts = [
          for (final c in reqCerts)
            if (!w.certifications.any((x) =>
                x.typeCode == c && !_pendingCerts.containsKey(x.id) && (x.expiresOn == null || !x.expiresOn!.isBefore(today))))
              c,
        ];
        if (missingCerts.isEmpty) {
          status = 'complete';
        } else if (status == 'complete' || status == 'approved') {
          status = 'not_started';
        }
        for (final c in missingCerts) {
          final expired = [
            for (final x in w.certifications)
              if (x.typeCode == c && x.expiresOn != null && x.expiresOn!.isBefore(today)) x.expiresOn!,
          ]..sort();
          final t = expired.isEmpty ? started : later(expired.last.add(const Duration(days: 1)), started);
          if (moment == null || t.isBefore(moment)) moment = t;
        }
        extra.addAll({
          'required_certs': reqCerts,
          'missing_certs': missingCerts,
          'pending_certs': [
            for (final c in _pendingCerts.values)
              if (c.workerId == w.id)
                {'id': c.id, 'cert_type_code': c.typeCode, 'number': c.number, 'expires_on': c.expiresOn == null ? null : dateOnly(c.expiresOn!), 'document_path': c.documentPath},
          ],
        });
      } else if (s.kind == StepKind.checklist) {
        final items = _itemsFor(w, s);
        if (items.isEmpty) continue;
        final ticked = ((p?['data'] as Map?)?['items'] as Map?) ?? const {};
        final n = items.where((i) => ticked.containsKey(i.code)).length;
        if (n == items.length) {
          status = 'complete';
        } else if (status == 'complete' || status == 'approved') {
          status = 'not_started';
        }
        extra.addAll({'items': [for (final i in items) i.toJson()], 'items_done': n});
      } else if (s.config['auto_complete_when'] == 'date_of_birth') {
        if (w.dateOfBirth != null) status = 'complete';
        extra['birth_date_on_file'] = w.dateOfBirth != null;
      }

      final isDone = status == 'complete' || status == 'approved';
      if (s.required && !isDone) {
        final t = moment ?? started;
        if (openSince == null || t.isBefore(openSince)) openSince = t;
      }
      if (s.required) {
        required++;
        if (isDone) {
          done++;
        } else {
          missing.add(s.name);
        }
      }
      if (status == 'submitted') review = true;
      if (isDone && p != null) {
        final t = DateTime.parse((p['reviewed_at'] ?? p['submitted_at'] ?? p['updated_at']) as String).toUtc();
        if (last == null || t.isAfter(last)) last = t;
      }
      steps.add({
        'code': s.code,
        'name': s.name,
        'kind': s.kind.name,
        'required': s.required,
        'sort': s.sort,
        'status': status,
        'done': isDone,
        'note': p?['note'] ?? '',
        'submitted_at': p?['submitted_at'],
        'reviewed_at': p?['reviewed_at'],
        if (detail) ...{
          'description': s.description,
          'config': s.config,
          'data': p?['data'] ?? const <String, dynamic>{},
          'file_paths': p?['file_paths'] ?? const <String>[],
          ...extra,
        },
      });
    }
    final finished = done == required ? (last ?? started) : null;
    return {
      'worker_id': w.id,
      'venue_id': w.venueId,
      'first_name': w.firstName,
      'last_name': w.lastName,
      'preferred_name': w.preferredName,
      'employee_number': w.employeeNumber,
      'worker_type': w.type.code,
      'has_login': w.userId != null || _sessionsByPin.values.any((s) => s.workerId == w.id),
      'minor': minor,
      'started_at': started.toIso8601String(),
      'finished_at': finished?.toIso8601String(),
      'open_since': openSince?.toIso8601String(),
      'days_open': finished != null ? finished.difference(started).inDays : _peopleNow.difference(openSince ?? started).inDays,
      'done': done,
      'required': required,
      'percent': required == 0 ? 100 : (100 * done) ~/ required,
      'missing': missing,
      'needs_review': review,
      'steps': steps,
    };
  }

  Map<String, dynamic> _docJson(OnboardingDocument d) =>
      {'id': d.id, 'step_code': d.stepCode, 'title': d.title, 'body': d.body, 'document_path': d.documentPath, 'version': d.version};

  OnboardingState _fullState(Worker w, {bool profile = false}) => OnboardingState.fromJson({
        ..._stateJson(w, detail: true),
        'documents': [for (final d in _onbDocs) if (d.active && d.appliesTo.contains(w.type.code)) _docJson(d)],
        if (profile)
          'profile': {
            'phone': w.phone,
            'email': w.email,
            'uniform_size': w.uniformSize,
            'emergency_contact_name': w.emergencyContactName,
            'emergency_contact_phone': w.emergencyContactPhone,
            'preferred_language': w.preferredLanguage,
            'date_of_birth': w.dateOfBirth == null ? null : dateOnly(w.dateOfBirth!),
          },
      });

  Worker _myWorker() {
    final w = _workers[_me.workerId];
    if (w == null || w.status != 'active') throw const AppFailure('No staff record is linked to this sign-in');
    return w;
  }

  Worker _managedWorker(String workerId) {
    _requirePerm(Perm.manageWorkers);
    final w = _workers[workerId];
    if (w == null) throw const AppFailure('Unknown person');
    return w;
  }

  // ---- Employee: hours and tips ----

  @override
  Future<MyHoursData> loadMyHours(AppSession session, DateTime from, DateTime to) => _delay(() {
        final me = _me.workerId;
        if (me == null) throw const AppFailure('No staff record is linked to this sign-in');
        final punches = [
          for (final p in _punches)
            if (p.workerId == me && !p.occurredAt.isBefore(from) && p.occurredAt.isBefore(to)) p,
        ];
        final eventIds = {for (final p in punches) ?p.eventId};
        return MyHoursData(
          punches: punches,
          events: {for (final id in eventIds) id: ?_events[id]},
          shifts: [for (final s in _shifts.values) if (s.workerId == me && eventIds.contains(s.eventId)) s],
        );
      });

  /// Splits of the sample tip pools as a manager would finalize them. Pools a manager
  /// split in this session win.
  final Map<String, List<TipAllocation>> _demoTipSplits = {};

  @override
  Future<List<MyTip>> loadMyTips(AppSession session) => _delay(() {
        final me = _me.workerId;
        if (me == null) throw const AppFailure('No staff record is linked to this sign-in');
        final cutoff = _peopleNow.subtract(const Duration(days: 2));
        final payRules = PayRules.fromVenueSettings(_arena.venue.settings);
        final out = <MyTip>[];
        for (final pool in _tipPools.values) {
          final e = _events[pool.eventId];
          if (e == null || !(e.endTime ?? e.startTime).isBefore(cutoff)) continue;
          final allocations = _allocations[pool.id] ??
              _demoTipSplits.putIfAbsent(pool.id, () {
                final shifts = [for (final s in _shifts.values) if (s.eventId == pool.eventId) s];
                final ids = {for (final s in shifts) ?s.workerId};
                final participants = tipParticipantsFromShifts(
                  pool: pool,
                  workers: {for (final id in ids) id: ?_workers[id]},
                  shifts: shifts,
                  punchesByWorker: {
                    for (final id in ids) id: [for (final p in _punches) if (p.workerId == id && p.eventId == pool.eventId) p],
                  },
                  timeZone: _tz,
                  breakRules: _venueRules.breaks,
                );
                return allocateTipPool(pool: pool, participants: participants, payRules: payRules).allocations;
              });
          for (final a in allocations.where((a) => a.workerId == me && a.amountCents > 0)) {
            out.add(MyTip(
              eventId: e.id,
              eventName: e.name,
              startTime: e.startTime,
              storefrontName: _arena.storefronts.where((f) => f.id == pool.storefrontId).firstOrNull?.name ?? '',
              hoursHundredths: a.hoursHundredths,
              amountCents: a.amountCents,
            ));
          }
        }
        return out..sort((a, b) => b.startTime.compareTo(a.startTime));
      });

  // ---- Employee: onboarding ----

  @override
  Future<OnboardingState> myOnboarding(AppSession session) => _delay(() {
        _ensurePeople();
        return _fullState(_myWorker(), profile: true);
      });

  @override
  Future<String> uploadOnboardingFile(AppSession session, String fileName, Uint8List bytes, {String contentType = 'image/jpeg'}) => _delay(() {
        final w = _myWorker();
        final safe = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        final path = '${w.venueId}/${w.id}/${_id()}-$safe';
        _onbFiles[path] = bytes;
        return path;
      });

  @override
  Future<Uint8List?> downloadOnboardingFile(String path) => _delay(() => _onbFiles[path]);

  @override
  Future<OnboardingState> submitOnboardingStep(AppSession session, String step, Map<String, dynamic> data, {List<String> files = const []}) => _delay(() {
        _ensurePeople();
        var w = _myWorker();
        final s = _onbSteps.where((s) => s.code == step && s.appliesTo.contains(w.type.code)).firstOrNull;
        if (s == null) throw const AppFailure('Unknown onboarding step');
        if (s.kind == StepKind.checklist || s.kind == StepKind.external || s.config['manager_only'] == true) {
          throw const AppFailure('A manager completes this step');
        }
        final prefix = '${w.venueId}/${w.id}/';
        if (files.any((f) => !f.startsWith(prefix) || f.contains('..'))) throw const AppFailure('Upload files to your own folder');
        final now = _peopleNow;
        final previous = _onbProgress[w.id]?[step];
        String status;
        Map<String, dynamic> stored;

        if (s.kind == StepKind.form && (s.config['fields'] as List).contains('date_of_birth')) {
          final dob = DateTime.tryParse('${data['date_of_birth'] ?? ''}');
          if (dob == null || dob.isAfter(_today) || dob.year < 1900) throw const AppFailure('Enter a valid birth date');
          stored = {'date_of_birth': dateOnly(dob)};
          status = 'submitted';
        } else if (s.kind == StepKind.form) {
          String field(String k) => ((data[k] as String?) ?? '').trim();
          if (field('phone').isEmpty) throw const AppFailure('Enter a phone number');
          if (field('emergency_contact_name').isEmpty || field('emergency_contact_phone').isEmpty) {
            throw const AppFailure('Enter an emergency contact and their phone');
          }
          final lang = data['preferred_language'] == 'es' ? 'es' : 'en';
          stored = {
            for (final k in const ['address', 'phone', 'email', 'emergency_contact_name', 'emergency_contact_phone', 'uniform_size', 'notes'])
              if (data[k] is String) k: field(k).length > 300 ? field(k).substring(0, 300) : field(k),
            'preferred_language': lang,
          };
          w = Worker.fromJson({
            ...w.toJson(),
            'phone': field('phone'),
            if (data['email'] is String) 'email': field('email'),
            'emergency_contact_name': field('emergency_contact_name'),
            'emergency_contact_phone': field('emergency_contact_phone'),
            if (data['uniform_size'] is String) 'uniform_size': field('uniform_size'),
            'preferred_language': lang,
          });
          _workers[w.id] = w;
          status = 'complete';
        } else if (s.kind == StepKind.document) {
          final acks = [
            for (final a in ((previous?['data'] as Map?)?['acknowledgments'] as List?) ?? const []) Map<String, dynamic>.from(a as Map),
          ];
          final minor = _isMinor(w);
          final adultConfirmed = data['adult_confirmed'] == true;
          for (final a in (data['acknowledgments'] as List?) ?? const []) {
            final ack = (a as Map).cast<String, dynamic>();
            final d = _docsFor(w, step).where((d) => d.id == ack['document_id']).firstOrNull;
            if (d == null) throw const AppFailure('Unknown document');
            final typed = (ack['typed_name'] as String?) ?? '';
            if (!typedNameMatches(typed, firstName: w.firstName, preferredName: w.preferredName, lastName: w.lastName)) {
              throw AppFailure('Type your full name as it appears on your record to sign "${d.title}"');
            }
            final guardian = ((ack['guardian_name'] as String?) ?? '').trim();
            if (s.config['guardian_for_minors'] == true &&
                (minor || (w.dateOfBirth == null && !adultConfirmed)) &&
                (guardian.length < 3 || normalizeName(guardian) == normalizeName(typed))) {
              throw AppFailure('A parent or guardian must also type their name for volunteers under ${_venueRules.minors.adultAge}');
            }
            acks.removeWhere((x) => x['document_id'] == d.id);
            acks.add({
              'document_id': d.id,
              'title': d.title,
              'version': d.version,
              'typed_name': typed.trim(),
              if (guardian.isNotEmpty) 'guardian_name': guardian,
              if (adultConfirmed) 'adult_confirmed': true,
              'at': now.toIso8601String(),
            });
          }
          stored = {'acknowledgments': acks};
          final all = _docsFor(w, step).every((d) => acks.any((x) => x['document_id'] == d.id && (x['version'] as int) >= d.version));
          status = all ? 'complete' : 'not_started';
        } else if (s.kind == StepKind.upload) {
          final certs = (data['certs'] as List?) ?? const [];
          if (certs.isEmpty) throw const AppFailure('Add a photo of your card');
          final saved = <Map<String, dynamic>>[];
          final added = <WorkerCertification>[];
          for (final c in certs) {
            final m = (c as Map).cast<String, dynamic>();
            final type = m['cert_type_code'] as String?;
            if (!_arena.certificationTypes.any((t) => t.code == type)) throw const AppFailure('Unknown certification');
            final path = m['file_path'] as String?;
            if (path == null || !files.contains(path)) throw const AppFailure('Add a photo of your card');
            final expires = DateTime.tryParse('${m['expires_on'] ?? ''}');
            final expiresOn = expires == null ? null : DateTime.utc(expires.year, expires.month, expires.day);
            if (expiresOn != null && expiresOn.isBefore(_today)) throw const AppFailure('This card has expired');
            final id = _id();
            final number = ((m['number'] as String?) ?? '').trim();
            _pendingCerts[id] = CertRecord(id: id, workerId: w.id, typeCode: type!, number: number, expiresOn: expiresOn, documentPath: path, verified: false);
            _certPaths[id] = path;
            added.add(WorkerCertification(id: id, workerId: w.id, typeCode: type, number: number, expiresOn: expiresOn));
            saved.add({'id': id, 'cert_type_code': type, 'number': number, 'expires_on': expiresOn == null ? null : dateOnly(expiresOn), 'file_path': path});
          }
          w = w.copyWith(certifications: [...w.certifications, ...added]);
          _workers[w.id] = w;
          stored = {'certs': saved};
          status = 'submitted';
        } else {
          throw const AppFailure('A manager completes this step');
        }
        _setProgress(w.id, step, {'status': status, 'data': stored, 'file_paths': files, 'submitted_at': now});
        return _fullState(w, profile: true);
      });

  @override
  Future<List<CertRecord>> workerCertifications(String workerId) => _delay(() {
        _ensurePeople();
        final me = _me;
        if (me.workerId != workerId && !me.canVenueWide(Perm.viewWorkers)) throw const AppFailure('Not authorized');
        final w = _workers[workerId];
        if (w == null) return const <CertRecord>[];
        return [
          for (final c in w.certifications)
            _pendingCerts[c.id] ??
                CertRecord(
                  id: c.id,
                  workerId: c.workerId,
                  typeCode: c.typeCode,
                  number: c.number,
                  issuedOn: c.issuedOn,
                  expiresOn: c.expiresOn,
                  documentPath: _certPaths[c.id],
                ),
        ];
      });

  // ---- Managers ----

  @override
  Future<List<OnboardingState>> onboardingOverview(AppSession session) => _delay(() {
        _ensurePeople();
        if (!_me.canVenueWide(Perm.manageWorkers) && !_me.canVenueWide(Perm.viewWorkers)) throw const AppFailure('Not authorized');
        final people = [for (final w in _workers.values) if (w.status == 'active') w]
          ..sort((a, b) => '${a.lastName} ${a.firstName}'.compareTo('${b.lastName} ${b.firstName}'));
        return [for (final w in people) OnboardingState.fromJson(_stateJson(w))];
      });

  @override
  Future<OnboardingState> workerOnboarding(String workerId) => _delay(() {
        _ensurePeople();
        if (!_me.canVenueWide(Perm.manageWorkers) && !_me.canVenueWide(Perm.viewWorkers)) throw const AppFailure('Not authorized');
        final w = _workers[workerId];
        if (w == null) throw const AppFailure('Unknown person');
        return _fullState(w);
      });

  @override
  Future<OnboardingState> reviewOnboardingStep(String workerId, String step, {required bool approve, String note = ''}) => _delay(() {
        _ensurePeople();
        var w = _managedWorker(workerId);
        final p = _onbProgress[w.id]?[step];
        if (p == null || p['status'] != 'submitted') throw const AppFailure('Nothing to review for this step');
        if (!approve && note.trim().isEmpty) throw const AppFailure('Say what needs to change');
        final data = (p['data'] as Map).cast<String, dynamic>();
        final ids = {for (final c in (data['certs'] as List?) ?? const []) (c as Map)['id'] as String};
        if (approve) {
          ids.forEach(_pendingCerts.remove);
          if (data['date_of_birth'] is String) {
            w = Worker.fromJson({...w.toJson(), 'date_of_birth': data['date_of_birth']});
            _workers[w.id] = w;
          }
        } else if (ids.isNotEmpty) {
          for (final id in ids) {
            _pendingCerts.remove(id);
            _certPaths.remove(id);
          }
          w = w.copyWith(certifications: [for (final c in w.certifications) if (!ids.contains(c.id)) c]);
          _workers[w.id] = w;
        }
        _setProgress(w.id, step, {
          ...p,
          'status': approve ? 'approved' : 'needs_changes',
          'reviewed_at': _peopleNow,
          'reviewed_by': _me.userId,
          'note': note.trim(),
        });
        if (!approve) {
          final name = _onbSteps.firstWhere((s) => s.code == step).name;
          _notifyWorker(w.id,
              kind: 'onboarding_review',
              title: '${w.preferredLanguage == 'es' ? 'Revise su incorporación: ' : 'Onboarding needs a change: '}$name',
              body: note.trim(),
              link: '/me');
        }
        return _fullState(w);
      });

  @override
  Future<OnboardingState> completeOnboardingStep(String workerId, String step, Map<String, dynamic> data) => _delay(() {
        _ensurePeople();
        final w = _managedWorker(workerId);
        final s = _onbSteps.where((s) => s.code == step && s.appliesTo.contains(w.type.code)).firstOrNull;
        if (s == null) throw const AppFailure('Unknown onboarding step');
        final p = _onbProgress[w.id]?[step];
        final now = _peopleNow;
        Map<String, dynamic> stored;
        var status = 'complete';
        if (s.kind == StepKind.checklist) {
          final before = ((p?['data'] as Map?)?['items'] as Map?) ?? const {};
          final items = <String, dynamic>{};
          for (final code in ((data['items'] as List?) ?? const []).cast<String>()) {
            if (!s.items.any((i) => i.code == code)) throw AppFailure('Unknown training item $code');
            items[code] = before[code] ?? {'at': now.toIso8601String(), 'by': _me.userId};
          }
          stored = {'items': items};
          status = 'not_started';
        } else if (s.kind == StepKind.external) {
          final on = data['completed_on'] == null ? _today : DateTime.tryParse('${data['completed_on']}');
          if (on == null) throw const AppFailure('Enter a valid date');
          if (on.isAfter(_today)) throw const AppFailure('The date cannot be in the future');
          stored = {'completed_on': dateOnly(on), 'by': _me.userId};
        } else {
          stored = {...((p?['data'] as Map?) ?? const {}).cast<String, dynamic>(), 'completed_by_manager': true, 'note': data['note'] ?? ''};
        }
        _setProgress(w.id, step, {'status': status, 'data': stored, 'submitted_at': now, 'reviewed_at': now, 'reviewed_by': _me.userId});
        return _fullState(w);
      });

  @override
  Future<void> sendOnboardingReminder(String workerId) => _delay(() {
        _ensurePeople();
        final w = _managedWorker(workerId);
        final state = OnboardingState.fromJson(_stateJson(w));
        if (state.finished) throw const AppFailure('Onboarding is already complete');
        if (!state.hasLogin) throw const AppFailure('This person has no sign-in yet. Create a PIN first.');
        final es = w.preferredLanguage == 'es';
        _notifyWorker(w.id,
            kind: 'onboarding_reminder',
            title: es ? 'Termine su incorporación' : 'Finish your onboarding',
            body: '${es ? 'Falta: ' : 'Still to do: '}${state.missing.join(', ')}',
            link: '/me');
      });

  @override
  Future<List<OnboardingDocument>> listOnboardingDocuments(AppSession session) => _delay(() {
        _ensurePeople();
        return [..._onbDocs]..sort((a, b) => '${a.stepCode}${a.sort}'.compareTo('${b.stepCode}${b.sort}'));
      });

  @override
  Future<void> saveOnboardingDocument(AppSession session, OnboardingDocument document) => _delay(() {
        _ensurePeople();
        _requirePerm(Perm.manageWorkers);
        if (document.title.trim().isEmpty) throw const AppFailure('Give the document a title');
        final i = _onbDocs.indexWhere((d) => d.id == document.id);
        if (i < 0) {
          _onbDocs.add(document.copyWith(id: 'doc-${_id()}', version: 1));
        } else {
          final old = _onbDocs[i];
          final changed = old.title != document.title || old.body != document.body;
          _onbDocs[i] = document.copyWith(version: changed ? old.version + 1 : old.version);
          if (changed) _docUpdatedAt[old.id] = _peopleNow;
        }
      });

  // ---- Adding people ----

  Worker _personToWorker(NewPerson p, {required String id, Worker? existing}) => Worker.fromJson({
        ...?existing?.toJson(),
        ...p.toRow(_arena.venue.id),
        'id': id,
        'user_id': existing?.userId,
        'status': existing?.status ?? 'active',
        'job_roles': p.jobRoles,
        'certifications': [for (final c in existing?.certifications ?? const <WorkerCertification>[]) c.toJson()],
      });

  void _checkPerson(NewPerson p) {
    if (!RegExp(r'^[A-Z0-9-]{2,20}$').hasMatch(p.employeeNumber)) throw const AppFailure('Employee numbers are 2 to 20 letters, digits or dashes');
    if (p.firstName.trim().isEmpty || p.lastName.trim().isEmpty) throw const AppFailure('Enter a first and last name');
    if (p.type == WorkerType.temp && p.agencyId == null) throw const AppFailure('Choose the temp agency');
    if (p.type == WorkerType.npo && p.npoGroupId == null) throw const AppFailure('Choose the NPO group');
    for (final r in p.jobRoles) {
      if (!_arena.jobRoles.any((j) => j.code == r)) throw AppFailure('Unknown role $r');
    }
  }

  @override
  Future<Worker> addWorker(AppSession session, NewPerson person) => _delay(() {
        _ensurePeople();
        _requirePerm(Perm.manageWorkers);
        _checkPerson(person);
        if (_workers.values.any((w) => w.employeeNumber == person.employeeNumber)) {
          throw AppFailure('Employee number ${person.employeeNumber} is already used');
        }
        final w = _personToWorker(person, id: _id());
        _workers[w.id] = w;
        _addedAt[w.id] = _peopleNow;
        return w;
      });

  @override
  Future<RosterImportResult> importRoster(AppSession session, List<NewPerson> rows, {required bool updateExisting}) => _delay(() {
        _ensurePeople();
        _requirePerm(Perm.manageWorkers);
        rows.forEach(_checkPerson);
        var added = 0, updated = 0, skipped = 0;
        for (final p in rows) {
          final existing = _workers.values.where((w) => w.employeeNumber == p.employeeNumber).firstOrNull;
          if (existing == null) {
            final w = _personToWorker(p, id: _id());
            _workers[w.id] = w;
            _addedAt[w.id] = _peopleNow;
            added++;
          } else if (updateExisting) {
            _workers[existing.id] = _personToWorker(p, id: existing.id, existing: existing);
            updated++;
          } else {
            skipped++;
          }
        }
        return RosterImportResult(added: added, updated: updated, skipped: skipped);
      });

  @override
  Future<void> verifyCertification(AppSession session, String certId) => _delay(() {
        _ensurePeople();
        _requirePerm(Perm.manageWorkers);
        _pendingCerts.remove(certId);
      });

  // ---- Partners ----

  PartnerActivity _activity(Set<String> ids, DateTime from, DateTime to) {
    final start = startOfLocalDay(from, _tz);
    final end = startOfLocalDay(addCalendarDays(to, 1), _tz);
    final weekBefore = start.subtract(const Duration(days: 7));
    final now = _peopleNow;
    bool upcoming(Event e) => !e.startTime.isBefore(now.subtract(const Duration(hours: 12))) &&
        (e.status == EventStatus.scheduled || e.status == EventStatus.live);
    final shifts = [
      for (final s in _shifts.values)
        if (ids.contains(s.workerId) &&
            (s.status == ShiftStatus.assigned || s.status == ShiftStatus.released) &&
            _events[s.eventId] != null &&
            ((!_events[s.eventId]!.startTime.isBefore(weekBefore) && _events[s.eventId]!.startTime.isBefore(end)) || upcoming(_events[s.eventId]!)))
          s,
    ]..sort((a, b) => a.callTime.compareTo(b.callTime));
    final punches = [
      for (final p in _punches)
        if (ids.contains(p.workerId) && p.status != PunchStatus.voided && !p.occurredAt.isBefore(weekBefore) &&
            p.occurredAt.isBefore(end.add(const Duration(hours: 12))))
          Punch(
            id: p.id,
            venueId: p.venueId,
            workerId: p.workerId,
            eventId: p.eventId,
            shiftId: p.shiftId,
            kind: p.kind,
            breakKind: p.breakKind,
            occurredAt: p.occurredAt,
            source: p.source,
            status: p.status,
          ),
    ];
    final eventIds = {for (final s in shifts) s.eventId, for (final p in punches) ?p.eventId};
    return PartnerActivity(
      events: {for (final id in eventIds) id: ?_events[id]},
      shifts: shifts,
      punches: punches,
      storefrontNames: {for (final s in shifts) s.id: _arena.storefronts.where((f) => f.id == s.storefrontId).firstOrNull?.name ?? ''},
    );
  }

  PortalMember _member(Worker w, {bool phone = false}) {
    final st = OnboardingState.fromJson(_stateJson(w));
    return PortalMember(
      id: w.id,
      firstName: w.firstName,
      lastName: w.lastName,
      preferredName: w.preferredName,
      employeeNumber: w.employeeNumber,
      status: w.status,
      phone: phone ? w.phone : '',
      minor: phone && st.minor,
      roles: [...w.jobRoles]..sort(),
      onboardingPercent: st.percent,
      onboardingMissing: st.missing,
      waiverStatus: st.step('waiver')?.status.code ?? 'not_required',
    );
  }

  String _scopeId(String permission, String scopeType, String? wanted) {
    final ids = [
      for (final g in _me.grants)
        if (g.permissions.contains(permission) && g.scopeType == scopeType && g.scopeId != null) g.scopeId!,
    ];
    if (ids.isEmpty || (wanted != null && !ids.contains(wanted))) throw const AppFailure('Not authorized');
    return wanted ?? ids.first;
  }

  @override
  Future<NpoPortalData> loadNpoPortal(AppSession session, DateTime from, DateTime to, {String? groupId}) => _delay(() {
        _ensurePeople();
        final id = _scopeId('npo_portal', 'npo_group', groupId);
        final group = _arena.npoGroups.firstWhere((g) => g.id == id);
        final members = [for (final w in _workers.values) if (w.npoGroupId == id) w]
          ..sort((a, b) => '${a.lastName} ${a.firstName}'.compareTo('${b.lastName} ${b.firstName}'));
        final activity = _activity({for (final m in members) m.id}, from, to);

        // Payouts: stored ones win; otherwise figured as the pay screen would, with older
        // ones shown as approved or paid (demo only).
        final now = _peopleNow;
        final payouts = <NpoPayout>[];
        final names = <String, String>{};
        for (final e in _events.values) {
          final local = venueDate(e.startTime, _tz);
          if (local.isBefore(from) || local.isAfter(to) || e.status != EventStatus.completed) continue;
          final stored = _npoPayouts['${e.id}:$id'];
          NpoPayout? payout = stored;
          if (payout == null) {
            final shifts = [for (final s in _shifts.values) if (s.eventId == e.id) s];
            if (!shifts.any((s) => members.any((m) => m.id == s.workerId))) continue;
            final computed = calculateNpoPayout(
              event: e,
              npoGroupId: id,
              members: members,
              shifts: shifts,
              punchesByWorker: {
                for (final m in members) m.id: [for (final p in _punches) if (p.workerId == m.id && p.eventId == e.id) p],
              },
              agreements: _pay.npoAgreements,
              timeZone: _tz,
              breakRules: _venueRules.breaks,
            ).payout;
            final age = now.difference(e.startTime).inDays;
            final status = age > 14 ? 'paid' : age > 4 ? 'approved' : 'pending';
            payout = NpoPayout.fromJson({
              ...computed.toJson(),
              'id': 'demo-payout-${e.id}',
              'status': status,
              if (status != 'pending') 'approved_at': e.startTime.add(const Duration(days: 3)).toIso8601String(),
              if (status == 'paid') 'paid_at': e.startTime.add(const Duration(days: 12)).toIso8601String(),
              if (status == 'paid') 'payment_reference': 'ACH-${e.startTime.month.toString().padLeft(2, '0')}${e.startTime.day.toString().padLeft(2, '0')}-${group.displayName.substring(0, 3).toUpperCase()}',
            });
          }
          payouts.add(payout);
          names[e.id] = e.name;
        }
        payouts.sort((a, b) => _events[a.eventId]!.startTime.compareTo(_events[b.eventId]!.startTime));
        final groups = [
          for (final g in _me.grants)
            if (g.permissions.contains('npo_portal') && g.scopeType == 'npo_group')
              for (final x in _arena.npoGroups.where((x) => x.id == g.scopeId)) (x.id, x.displayName),
        ];
        return NpoPortalData(
          groupId: id,
          groupName: group.displayName,
          legalName: group.legalName,
          groups: groups,
          members: [for (final w in members) _member(w, phone: true)],
          activity: activity,
          payouts: payouts,
          eventNames: names,
        );
      });

  @override
  Future<AgencyPortalData> loadAgencyPortal(AppSession session, DateTime from, DateTime to, {String? agencyId}) => _delay(() {
        _ensurePeople();
        final id = _scopeId('agency_portal', 'agency', agencyId);
        final agency = _arena.agencies.firstWhere((a) => a.id == id);
        final members = [for (final w in _workers.values) if (w.agencyId == id) w]
          ..sort((a, b) => '${a.lastName} ${a.firstName}'.compareTo('${b.lastName} ${b.firstName}'));
        return AgencyPortalData(
          agencyId: id,
          agencyName: agency.name,
          agencies: [
            for (final g in _me.grants)
              if (g.permissions.contains('agency_portal') && g.scopeType == 'agency')
                for (final x in _arena.agencies.where((x) => x.id == g.scopeId)) (x.id, x.name),
          ],
          members: [for (final w in members) _member(w)],
          activity: _activity({for (final m in members) m.id}, from, to),
          billRates: [for (final r in _pay.billRates) if (r.agencyId == id) r],
        );
      });
}

/// An onboarding step definition (onboarding_steps).
class _DemoStep {
  const _DemoStep(this.code, this.name, this.description, this.kind, this.appliesTo, this.sort, {this.config = const {}});

  final String code;
  final String name;
  final String description;
  final StepKind kind;
  final List<String> appliesTo;
  final int sort;
  final Map<String, dynamic> config;

  /// Every default step is required.
  bool get required => true;

  List<ChecklistItem> get items => [for (final i in (config['items'] as List?) ?? const []) ChecklistItem.fromJson((i as Map).cast())];

  /// Same as seed_onboarding_defaults() in the database.
  static const defaults = [
    _DemoStep('application', 'Application', 'Contact details, emergency contact, uniform size, language.', StepKind.form, ['regular'], 10, config: {
      'fields': ['address', 'phone', 'email', 'emergency_contact_name', 'emergency_contact_phone', 'uniform_size', 'preferred_language', 'notes'],
    }),
    _DemoStep('policies', 'Policies', 'Read and acknowledge the venue\'s policies.', StepKind.document, ['regular', 'temp'], 20),
    _DemoStep('waiver', 'Volunteer waiver', 'Read and sign the volunteer waiver. Volunteers under 18 also need a parent or guardian.',
        StepKind.document, ['npo'], 25,
        config: {'guardian_for_minors': true}),
    _DemoStep('age_confirmation', 'Age confirmation', 'A birth date on file, so the schedule follows the rules for minors.', StepKind.form, ['npo'], 30,
        config: {
          'fields': ['date_of_birth'],
          'auto_complete_when': 'date_of_birth',
          'review': true,
        }),
    _DemoStep('certifications', 'Certification cards', 'A photo of each card your roles need (food handler, TABC).', StepKind.upload,
        ['regular', 'temp', 'npo'], 40,
        config: {'review': true}),
    _DemoStep('training', 'Training', 'Your trainer checks these off as you finish them.', StepKind.checklist, ['regular', 'temp', 'npo'], 50, config: {
      'items': [
        {'code': 'cash_handling', 'label': 'Cash handling'},
        {'code': 'food_safety', 'label': 'Food safety at the stand'},
        {
          'code': 'alcohol_service',
          'label': 'Alcohol service (bartenders)',
          'roles': ['bartender'],
        },
        {'code': 'emergency_exits', 'label': 'Emergency exits'},
      ],
    }),
    _DemoStep('paycom', 'Paycom onboarding', 'Paycom onboarding (I-9, W-4, direct deposit) complete. Done in Paycom, marked here by a manager.',
        StepKind.external, ['regular'], 60,
        config: {'label': 'Paycom onboarding (I-9, W-4, direct deposit) complete', 'manager_only': true}),
  ];
}
