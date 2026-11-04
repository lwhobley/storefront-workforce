part of '../demo_repository.dart';

/// Demo (in-memory) implementation of [PerformanceRepository].
///
/// The sample arena already has late arrivals and a few no-shows at past events. This
/// part adds what it lacks, all deterministic: call-offs (a manager removed someone close
/// to call time and a coworker covered), a season of ratings and notes, and one person
/// flagged do not rehire.
mixin _DemoPerformance on _DemoCore implements PerformanceRepository {
  final List<WorkerRating> _perfRatings = [];
  final List<WorkerNote> _perfNotes = [];
  final Map<String, RehireFlag> _perfFlags = {};
  int _perfSeq = 0;

  /// Performance data is computed at the sample's own "now", so it does not drift with
  /// the wall clock (the sample is generated around that instant).
  DateTime get _perfNow {
    final real = DateTime.now().toUtc();
    return real.isBefore(_arena.now) ? _arena.now : real;
  }

  ReliabilityRules get _reliabilityRules => ReliabilityRules.fromVenueSettings(_arena.venue.settings);

  @override
  bool _doNotRehire(String workerId) => _perfFlags.containsKey(workerId);

  String _perfId() => 'pppppppp-0000-4000-8000-${(++_perfSeq).toRadixString(16).padLeft(12, '0')}';

  // ---- Seed ----

  void _seedPerformanceDemo() {
    final rnd = _PerfRng(4242);
    final pastEvents = _events.values.where((e) => e.status == EventStatus.completed).toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    if (pastEvents.isEmpty) return;
    final personas = {for (final s in _sessionsByPin.values) ?s.workerId};
    final pastIds = {for (final e in pastEvents) e.id};
    final pastShifts = [for (final s in _shifts.values) if (pastIds.contains(s.eventId)) s];
    final worked = <String, Set<String>>{}; // worker -> events
    for (final s in pastShifts) {
      if (s.workerId != null) worked.putIfAbsent(s.workerId!, () => {}).add(s.eventId);
    }

    // People who call off: staff and temps with a couple of past events, not a persona.
    final pool = [
      for (final w in _workers.values)
        if (w.type != WorkerType.npo && w.status == 'active' && !personas.contains(w.id) && (worked[w.id]?.length ?? 0) >= 2) w,
    ]..sort((a, b) => a.employeeNumber.compareTo(b.employeeNumber));
    rnd.shuffle(pool);
    final shaky = pool.take(7).toList();
    const callOffsEach = [3, 2, 2, 1, 1, 1, 1];
    for (var i = 0; i < shaky.length; i++) {
      final w = shaky[i];
      final options = [
        for (final e in pastEvents)
          if (!(worked[w.id]?.contains(e.id) ?? false)) e,
      ];
      rnd.shuffle(options);
      var made = 0;
      for (final e in options) {
        if (made >= callOffsEach[i]) break;
        final cover = pastShifts
            .where((s) => s.eventId == e.id && s.workerId != null && s.status == ShiftStatus.assigned && w.jobRoles.contains(s.jobRoleCode))
            .firstOrNull;
        if (cover == null) continue;
        final at = cover.callTime.subtract(Duration(hours: 3 + rnd.nextInt(30), minutes: rnd.nextInt(60)));
        _changes
          ..add(AssignmentChange(
            id: '${_changes.length + 1}',
            eventId: e.id,
            shiftId: cover.id,
            action: 'unassigned',
            changedAt: at,
            workerId: w.id,
            fromStorefrontId: cover.storefrontId,
            toStorefrontId: cover.storefrontId,
            fromJobRoleCode: cover.jobRoleCode,
            toJobRoleCode: cover.jobRoleCode,
            reason: rnd.nextBool() ? 'Called off' : 'Called off sick',
            changedByName: 'Marcus Bell',
          ))
          ..add(AssignmentChange(
            id: '${_changes.length + 2}',
            eventId: e.id,
            shiftId: cover.id,
            action: 'assigned',
            changedAt: at.add(const Duration(minutes: 25)),
            workerId: cover.workerId,
            fromStorefrontId: cover.storefrontId,
            toStorefrontId: cover.storefrontId,
            fromJobRoleCode: cover.jobRoleCode,
            toJobRoleCode: cover.jobRoleCode,
            reason: 'Covering a call-off',
            changedByName: 'Marcus Bell',
          ));
        worked.putIfAbsent(w.id, () => {}).add(e.id);
        made++;
      }
    }

    // The flag: someone with a no-show in the sample (and ideally a call-off too).
    final outcomes = _perfOutcomes(_perfNow);
    final noShows = [
      for (final o in outcomes)
        if (o.outcome == AttendanceOutcome.noShow && !personas.contains(o.workerId)) o.workerId,
    ];
    final shakyIds = {for (final w in shaky) w.id};
    final flagged = noShows.where(shakyIds.contains).firstOrNull ?? noShows.firstOrNull ?? shaky.firstOrNull?.id;
    if (flagged != null) {
      final lastEvent = pastEvents.last;
      _perfFlags[flagged] = RehireFlag(
        workerId: flagged,
        reason: 'No-show without calling, and left a shift early without telling the lead.',
        flaggedAt: (lastEvent.endTime ?? lastEvent.startTime).add(const Duration(hours: 14)),
        flaggedByName: 'Dana Whitfield',
      );
    }

    // Ratings: a manager rates some people after events. Shaky people rate lower.
    const notes = {
      5: ['Ran the register solo during the rush', 'Great with guests, stayed late to restock', 'Trained two new cashiers', ''],
      4: ['Solid night, quick on orders', 'Good attitude', '', 'Kept the stand clean'],
      3: ['Fine, needed reminders on cleanup', 'Slow at first, picked it up', ''],
      2: ['On the phone during the rush', 'Left the station without telling the lead'],
      1: ['Walked out before close'],
    };
    final rateable = [
      for (final s in pastShifts)
        if (s.workerId != null && s.status != ShiftStatus.cancelled && !personas.contains(s.workerId)) s,
    ];
    rnd.shuffle(rateable);
    final rated = <String>{};
    for (final s in rateable) {
      if (rated.length >= 36) break;
      if (!rated.add('${s.workerId}|${s.eventId}')) continue;
      final w = s.workerId!;
      final low = shakyIds.contains(w) || w == flagged;
      final roll = rnd.nextInt(100);
      final stars = low
          ? (roll < 50 ? 2 : roll < 85 ? 3 : 1)
          : (roll < 38 ? 5 : roll < 75 ? 4 : roll < 93 ? 3 : 2);
      final options = notes[stars]!;
      final e = _events[s.eventId]!;
      _perfRatings.add(WorkerRating(
        id: _perfId(),
        workerId: w,
        eventId: e.id,
        stars: stars,
        note: options[rnd.nextInt(options.length)],
        ratedAt: (e.endTime ?? e.startTime).add(Duration(hours: 13, minutes: rnd.nextInt(120))),
        ratedByName: rnd.nextBool() ? 'Marcus Bell' : 'Dana Whitfield',
      ));
    }
    // A few people with several ratings, so averages mean something.
    for (final w in shaky.take(2)) {
      for (final e in pastEvents.where((e) => worked[w.id]?.contains(e.id) ?? false).take(2)) {
        _perfRatings.add(WorkerRating(
          id: _perfId(),
          workerId: w.id,
          eventId: e.id,
          stars: 3,
          note: 'Reliable once here; calls off too often',
          ratedAt: (e.endTime ?? e.startTime).add(const Duration(hours: 15)),
          ratedByName: 'Marcus Bell',
        ));
      }
    }

    // Notes.
    final noteTargets = [?flagged, ...shaky.take(2).map((w) => w.id), ...rateable.take(3).map((s) => s.workerId!)];
    const noteTexts = [
      'Talked with them after the second no-show. Said it would not happen again.',
      'Prefers bar shifts on weekends; ask before scheduling weeknights.',
      'Asked to be considered for lead next season.',
      'Good candidate for the concert crew.',
      'Needs a TABC renewal before spring.',
      'Covered two call-offs this month without being asked.',
    ];
    for (var i = 0; i < noteTargets.length && i < noteTexts.length; i++) {
      _perfNotes.add(WorkerNote(
        id: _perfId(),
        workerId: noteTargets[i],
        body: noteTexts[i],
        writtenAt: _perfNow.subtract(Duration(days: 2 + i * 5, hours: i)),
        writtenByName: i.isEven ? 'Dana Whitfield' : 'Marcus Bell',
      ));
    }
  }

  /// Outcomes for every scheduled person at events in the reliability window.
  List<ShiftOutcome> _perfOutcomes(DateTime now) {
    final since = now.subtract(Duration(days: _reliabilityRules.windowDays + 1));
    final events = {for (final e in _events.values) if (!e.callTime.isBefore(since) && !e.callTime.isAfter(now)) e.id};
    return attendanceOutcomes(
      shifts: [for (final s in _shifts.values) if (events.contains(s.eventId)) s],
      punches: [for (final p in _punches) if (events.contains(p.eventId)) p],
      changes: [for (final c in _changes) if (events.contains(c.eventId)) c],
      rules: VenueRules.fromJson(_arena.venue.settings).attendance,
      now: now,
    );
  }

  // ---- Reads ----

  @override
  Future<PerformanceData> loadPerformance(AppSession session) => _delay(() {
        _requirePerm(Perm.viewWorkers);
        final now = _perfNow;
        final outcomes = _perfOutcomes(now);
        final eventIds = {for (final o in outcomes) o.eventId};
        return PerformanceData(
          now: now,
          rules: _reliabilityRules,
          outcomes: outcomes,
          events: {for (final id in eventIds) id: _events[id]!},
          ratings: List.of(_perfRatings),
          flags: Map.of(_perfFlags),
          workedMinutes: workedMinutesByWorker([for (final p in _punches) if (eventIds.contains(p.eventId)) p], now: now),
        );
      });

  @override
  Future<WorkerPerformanceDetail> workerPerformance(AppSession session, String workerId) => _delay(() {
        _requirePerm(Perm.viewWorkers);
        return WorkerPerformanceDetail(
          ratings: [for (final r in _perfRatings) if (r.workerId == workerId) r]..sort((a, b) => b.ratedAt.compareTo(a.ratedAt)),
          notes: [for (final n in _perfNotes) if (n.workerId == workerId) n]..sort((a, b) => b.writtenAt.compareTo(a.writtenAt)),
          flag: _perfFlags[workerId],
        );
      });

  @override
  Future<List<PastEventStaffing>> staffingHistory(AppSession session, String eventTypeCode) => _delay(() {
        _requirePerm(Perm.manageSchedule);
        final now = _perfNow;
        return [
          for (final e in _events.values)
            if (e.eventTypeCode == eventTypeCode && e.status == EventStatus.completed && e.startTime.isBefore(now))
              PastEventStaffing.fromSchedule(
                e,
                _needs.where((n) => n.eventId == e.id),
                _shifts.values.where((s) => s.eventId == e.id),
              ),
        ];
      });

  // ---- Changes ----

  void _requireWorker(String workerId) {
    if (!_workers.containsKey(workerId)) throw const AppFailure('This person is not on this venue\'s staff.');
  }

  @override
  Future<void> addRating(AppSession session, String workerId, {required int stars, String note = '', String? eventId}) => _delay(() {
        _requirePerm(Perm.manageWorkers);
        _requireWorker(workerId);
        if (stars < 1 || stars > 5) throw const AppFailure('Pick 1 to 5 stars.');
        if (note.length > 500) throw const AppFailure('Keep the note to 500 characters.');
        _perfRatings.add(WorkerRating(
          id: _perfId(),
          workerId: workerId,
          eventId: eventId,
          stars: stars,
          note: note.trim(),
          ratedAt: DateTime.now().toUtc(),
          ratedByName: _me.displayName,
        ));
      });

  @override
  Future<void> addNote(AppSession session, String workerId, String body, {String? eventId}) => _delay(() {
        _requirePerm(Perm.manageWorkers);
        _requireWorker(workerId);
        final text = body.trim();
        if (text.isEmpty) throw const AppFailure('Write the note first.');
        if (text.length > 1000) throw const AppFailure('Keep the note to 1,000 characters.');
        _perfNotes.add(WorkerNote(
          id: _perfId(),
          workerId: workerId,
          eventId: eventId,
          body: text,
          writtenAt: DateTime.now().toUtc(),
          writtenByName: _me.displayName,
        ));
      });

  @override
  Future<void> setDoNotRehire(AppSession session, String workerId, String reason) => _delay(() {
        _requirePerm(Perm.manageWorkers);
        _requireWorker(workerId);
        final text = reason.trim();
        if (text.isEmpty) throw const AppFailure('Give a reason.');
        if (text.length > 500) throw const AppFailure('Keep the reason to 500 characters.');
        final existing = _perfFlags[workerId];
        _perfFlags[workerId] = RehireFlag(
          workerId: workerId,
          reason: text,
          // Only the reason changes on an existing flag (as in the database).
          flaggedAt: existing?.flaggedAt ?? DateTime.now().toUtc(),
          flaggedByName: existing?.flaggedByName ?? _me.displayName,
        );
      });

  @override
  Future<void> clearDoNotRehire(AppSession session, String workerId) => _delay(() {
        _requirePerm(Perm.manageWorkers);
        _perfFlags.remove(workerId);
      });

  /// Reasons by person, for the assign sheet's do-not-rehire block.
  @override
  Future<Map<String, String>> loadRehireFlags(AppSession session) => _delay(() {
        _requirePerm(Perm.viewWorkers);
        return {for (final e in _perfFlags.entries) e.key: e.value.reason};
      });
}

/// A small seeded random source (the demo library does not import dart:math), so the
/// seeded performance data is the same on every run and platform.
class _PerfRng {
  _PerfRng(this._state);

  int _state;

  int nextInt(int max) {
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return _state % max;
  }

  bool nextBool() => nextInt(2) == 0;

  void shuffle<T>(List<T> list) {
    for (var i = list.length - 1; i > 0; i--) {
      final j = nextInt(i + 1);
      final t = list[i];
      list[i] = list[j];
      list[j] = t;
    }
  }
}
