part of '../demo_repository.dart';

/// Demo (in-memory) implementation of [AdminRepository]. Follows the same rules as
/// migration 0023: only an admin changes settings or decides a request, nobody approves
/// their own, and anonymising keeps the hours and clears the personal details.
mixin _DemoAdmin on _DemoCore implements AdminRepository {
  @override
  Future<void> saveVenueProfile(AppSession session, {String? name, String? timeZone, Map<String, dynamic>? branding}) => _delay(() {
        _requirePerm('manage_settings');
        if (name != null && name.trim().isEmpty) throw const AppFailure('Give the venue a name');
        // Every signed-in demo persona sees the change at once, as they would after a reload.
        for (final pin in _sessionsByPin.keys.toList()) {
          final s = _sessionsByPin[pin]!;
          final venue = Venue.fromJson({
            ...s.venue.toJson(),
            'name': ?name?.trim(),
            'time_zone': ?timeZone,
            'branding': ?branding,
          });
          _sessionsByPin[pin] = AppSession(
            userId: s.userId,
            displayName: s.displayName,
            venue: venue,
            grants: s.grants,
            workerId: s.workerId,
            language: s.language,
            isKiosk: s.isKiosk,
          );
        }
        final me = _session;
        if (me != null) {
          _session = _sessionsByPin.values.firstWhere((s) => s.userId == me.userId, orElse: () => me);
        }
      });

  @override
  Future<RetentionPolicy> loadRetention(AppSession session) => _delay(() {
        _requirePerm(Perm.viewWorkers);
        return _retention;
      });

  @override
  Future<void> saveRetention(AppSession session, RetentionPolicy policy) => _delay(() {
        _requirePerm('manage_settings');
        final problem = policy.validate();
        if (problem != null) throw AppFailure(problem);
        _retention = policy;
      });

  @override
  Future<RetentionDue> retentionDue(AppSession session) => _delay(() {
        _requirePerm(Perm.viewWorkers);
        final photoCutoff = _now.subtract(Duration(days: 30 * _retention.punchPhotoMonths));
        final workerCutoff = _now.subtract(Duration(days: 30 * _retention.inactiveWorkerMonths));
        return RetentionDue(
          punchPhotos: _punches.where((p) => p.photoPath != null && p.occurredAt.isBefore(photoCutoff)).length,
          inactiveWorkers: _workers.values
              .where((w) =>
                  w.status == 'inactive' &&
                  w.firstName != 'Removed' &&
                  !_punches.any((p) => p.workerId == w.id && p.occurredAt.isAfter(workerCutoff)))
              .length,
        );
      });

  @override
  Future<int> purgeOldPunchPhotos(AppSession session) => _delay(() {
        _requirePerm('manage_settings');
        final cutoff = _now.subtract(Duration(days: 30 * _retention.punchPhotoMonths));
        var count = 0;
        for (var i = 0; i < _punches.length; i++) {
          final p = _punches[i];
          if (p.photoPath == null || !p.occurredAt.isBefore(cutoff)) continue;
          _punches[i] = Punch.fromJson({...p.toJson(), 'photo_path': null});
          count++;
        }
        return count;
      });

  @override
  Future<List<DeletionRequest>> loadDeletionRequests(AppSession session) => _delay(() {
        _requirePerm(Perm.manageWorkers);
        return [for (final r in _deletionRequests) _asSeenBy(r, session)]
          ..sort((a, b) => b.requestedAt.compareTo(a.requestedAt));
      });

  /// "Did I ask for this?" depends on who is signed in, so it is worked out on the way out.
  DeletionRequest _asSeenBy(DeletionRequest r, AppSession session) => DeletionRequest(
        id: r.id,
        workerId: r.workerId,
        status: r.status,
        requestedAt: r.requestedAt,
        note: r.note,
        decisionNote: r.decisionNote,
        requestedByMe: _deletionRequesters[r.id] == session.userId,
      );

  @override
  Future<void> requestDataDeletion(AppSession session, String workerId, {String note = ''}) => _delay(() {
        _requirePerm(Perm.manageWorkers);
        if (!_workers.containsKey(workerId)) throw const AppFailure('Staff member not found');
        if (_deletionRequests.any((r) => r.workerId == workerId && r.isPending)) {
          throw const AppFailure('There is already a request waiting for this person');
        }
        final id = _id();
        _deletionRequesters[id] = session.userId;
        _deletionRequests.add(DeletionRequest(
          id: id,
          workerId: workerId,
          status: 'pending',
          requestedAt: _now,
          note: note.trim(),
        ));
      });

  @override
  Future<void> approveDataDeletion(AppSession session, String requestId, {String note = ''}) => _delay(() {
        _requirePerm('manage_settings');
        final i = _deletionRequests.indexWhere((r) => r.id == requestId);
        if (i < 0) throw const AppFailure('Request not found');
        final r = _deletionRequests[i];
        if (!r.isPending) throw const AppFailure('This request has already been decided');
        if (_deletionRequesters[r.id] == session.userId) {
          throw const AppFailure('Someone else must approve a deletion request');
        }

        final w = _workers[r.workerId];
        if (w == null) throw const AppFailure('Staff member not found');
        // Hours and pay stay; the personal details go.
        _workers[w.id] = Worker.fromJson({
          ...w.toJson(),
          'first_name': 'Removed',
          'last_name': 'Record',
          'preferred_name': '',
          'date_of_birth': null,
          'phone': '',
          'email': '',
          'photo_path': null,
          'employee_number': 'REMOVED-${w.id.replaceAll('-', '').substring(0, 8)}',
          'status': 'inactive',
        });
        for (var j = 0; j < _punches.length; j++) {
          if (_punches[j].workerId == w.id && _punches[j].photoPath != null) {
            _punches[j] = Punch.fromJson({..._punches[j].toJson(), 'photo_path': null});
          }
        }
        _deletionRequests[i] = DeletionRequest(
          id: r.id,
          workerId: r.workerId,
          status: 'completed',
          requestedAt: r.requestedAt,
          note: r.note,
          decisionNote: note.trim(),
        );
      });

  @override
  Future<void> refuseDataDeletion(AppSession session, String requestId, String reason) => _delay(() {
        _requirePerm('manage_settings');
        if (reason.trim().isEmpty) throw const AppFailure('Give a reason for refusing');
        final i = _deletionRequests.indexWhere((r) => r.id == requestId);
        if (i < 0) throw const AppFailure('Request not found');
        final r = _deletionRequests[i];
        if (!r.isPending) throw const AppFailure('This request has already been decided');
        _deletionRequests[i] = DeletionRequest(
          id: r.id,
          workerId: r.workerId,
          status: 'refused',
          requestedAt: r.requestedAt,
          note: r.note,
          decisionNote: reason.trim(),
        );
      });
}
