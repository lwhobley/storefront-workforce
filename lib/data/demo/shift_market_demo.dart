part of '../demo_repository.dart';

/// One request as the demo stores it. Shift, event and names are resolved on read, so a
/// request always shows the position as it is now.
class _SmRequest {
  _SmRequest({
    required this.id,
    required this.kind,
    required this.shiftId,
    required this.requesterId,
    required this.createdAt,
    this.targetId,
    this.status = ShiftRequestStatus.pending,
    this.note = '',
  });

  final String id;
  final ShiftRequestKind kind;
  final String shiftId;
  final String requesterId;
  final String? targetId;
  final DateTime createdAt;
  ShiftRequestStatus status;
  String note;
  List<String> warnings = const [];
  DateTime? decidedAt;
  String decisionNote = '';
  String decidedByName = '';

  bool get isOpen => status.isOpen;
}

/// Demo (in-memory) implementation of [ShiftMarketRepository]. Follows the same rules as
/// 0012_shift_market.sql. Sample requests, availability answers and blackouts are added
/// the first time any of these features is used.
mixin _DemoShiftMarket on _DemoCore implements ShiftMarketRepository {
  final Stopwatch _smClock = Stopwatch()..start();
  final Map<String, _SmRequest> _smRequests = {};

  /// eventId -> workerId -> (answer, note).
  final Map<String, Map<String, (AvailabilityStatus, String)>> _smAvailability = {};

  /// blackout id -> (workerId, blackout).
  final Map<String, (String, Blackout)> _smBlackouts = {};
  bool _smSeeded = false;

  /// The sample arena's clock: the generation time plus time since the demo started.
  DateTime get _smNow => _arena.now.add(_smClock.elapsed);

  SelfServiceSettings get _smSettings => SelfServiceSettings.fromVenueSettings(_arena.venue.settings);

  String get _smZone => _arena.venue.timeZone;

  Worker _smMe() {
    final id = _me.workerId;
    final w = id == null ? null : _workers[id];
    if (w == null) throw const AppFailure('No staff record is linked to this sign-in');
    if (w.status != 'active') throw const AppFailure('Your staff record is not active');
    return w;
  }

  String _smName(String? workerId) => workerId == null ? '' : (_workers[workerId]?.displayName ?? '');

  Storefront? _smStorefront(String id) => _arena.storefronts.where((f) => f.id == id).firstOrNull;

  String _smRoleName(String code) => _arena.jobRoles.where((r) => r.code == code).firstOrNull?.name ?? code;

  static const _smDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _smMonths = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// "Fri Nov 6, 5:30 PM" at the venue.
  String _smWhen(DateTime utc) {
    final l = atVenue(utc, _smZone);
    final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
    return '${_smDays[l.weekday - 1]} ${_smMonths[l.month - 1]} ${l.day}, $h:${l.minute.toString().padLeft(2, '0')} ${l.hour < 12 ? 'AM' : 'PM'}';
  }

  String _smLabel(Shift s) =>
      '${_events[s.eventId]!.name} · ${_smStorefront(s.storefrontId)?.name ?? ''} · ${_smRoleName(s.jobRoleCode)} · ${_smWhen(s.callTime)}';

  bool _smUpcoming(Event e) => e.status == EventStatus.scheduled || e.status == EventStatus.live;

  bool _smClockedIn(String workerId, String eventId) =>
      _punches.any((p) => p.eventId == eventId && p.workerId == workerId && p.status != PunchStatus.voided);

  bool _smHolds(String workerId, String eventId) => _shifts.values.any((s) =>
      s.eventId == eventId && s.workerId == workerId && (s.status == ShiftStatus.assigned || s.status == ShiftStatus.released));

  void _smNotifySchedulers(Shift s, String kind, String title) {
    for (final session in _sessionsByPin.values) {
      if (session.userId == _session?.userId) continue;
      if (_scope(session, {'manage_schedule'}).contains(s.storefrontId)) {
        _notifyUser(session.userId, kind: kind, title: title, body: _smLabel(s), link: '/requests');
      }
    }
  }

  /// Assigns or clears a position for the shift market and logs it like assign/unassign.
  void _smSetWorker(Shift s, String? workerId, String reason) {
    var current = s;
    if (current.workerId != null) {
      final after = current.copyWith(clearWorker: true, status: ShiftStatus.open);
      _shifts[s.id] = after;
      _log(after, 'unassigned', current.workerId, current, reason);
      current = after;
    }
    if (workerId != null) {
      final after = current.copyWith(workerId: workerId, status: ShiftStatus.assigned);
      _shifts[s.id] = after;
      _log(after, 'assigned', workerId, current, reason);
    }
  }

  void _smExpire() {
    final now = _smNow;
    for (final q in _smRequests.values) {
      if (q.isOpen && !_shifts[q.shiftId]!.callTime.isAfter(now)) {
        q.status = ShiftRequestStatus.expired;
        q.decisionNote = 'The shift started before a decision.';
      }
    }
  }

  ShiftRequest _smView(_SmRequest q, {bool rules = false}) {
    final s = _shifts[q.shiftId]!;
    final e = _events[s.eventId]!;
    return ShiftRequest(
      id: q.id,
      kind: q.kind,
      status: q.status,
      shift: s,
      event: e,
      storefrontName: _smStorefront(s.storefrontId)?.name ?? '',
      roleName: _smRoleName(s.jobRoleCode),
      requesterWorkerId: q.requesterId,
      requesterName: _smName(q.requesterId),
      targetWorkerId: q.targetId,
      targetName: _smName(q.targetId),
      note: q.note,
      warnings: q.warnings,
      createdAt: q.createdAt,
      decidedAt: q.decidedAt,
      decisionNote: q.decisionNote,
      decidedByName: q.decidedByName,
      shiftWorkerName: rules ? _smName(s.workerId) : '',
      requester: rules ? _boardWorker(_workers[q.requesterId]!, e) : null,
      target: rules && q.targetId != null ? _boardWorker(_workers[q.targetId]!, e) : null,
    );
  }

  bool _smHasOpen(String shiftId, String workerId) =>
      _smRequests.values.any((q) => q.shiftId == shiftId && q.requesterId == workerId && q.isOpen);

  CandidateAvailability _smCandidate(String eventId, String workerId) {
    final a = _smAvailability[eventId]?[workerId];
    final day = venueDate(_events[eventId]!.callTime, _smZone);
    return CandidateAvailability(
      status: a?.$1,
      note: a?.$2 ?? '',
      blackout: _smBlackouts.values.any((b) => b.$1 == workerId && b.$2.covers(day)),
    );
  }

  // ---- Sample state ----

  /// Small deterministic hash, so the sample answers are the same on every run.
  int _smHash(String s) {
    var h = 17;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }

  void _smEnsure() {
    if (_smSeeded) return;
    _smSeeded = true;
    final now = _smNow;
    final upcoming = [for (final e in _events.values) if (e.status == EventStatus.scheduled && e.callTime.isAfter(now)) e]
      ..sort((a, b) => a.callTime.compareTo(b.callTime));
    if (upcoming.isEmpty) return;
    final personaWorkers = {for (final s in _sessionsByPin.values) ?s.workerId};
    final me = _workers[_sessionsByPin['400004']?.workerId];
    final active = [for (final w in _workers.values) if (w.status == 'active') w]..sort((a, b) => a.id.compareTo(b.id));
    DateTime ago(int hours) => now.subtract(Duration(hours: hours));
    final used = <String>{};

    // Availability for the next six events: most people answered, a few cannot come.
    const notes = ['Class that night', 'Second job', 'Family dinner', ''];
    for (final e in upcoming.take(6)) {
      final answers = _smAvailability.putIfAbsent(e.id, () => {});
      for (final w in active) {
        if (personaWorkers.contains(w.id)) continue;
        final h = _smHash('${e.id}:${w.id}') % 100;
        if (h < 48) {
          answers[w.id] = (AvailabilityStatus.available, '');
        } else if (h < 60) {
          answers[w.id] = (AvailabilityStatus.unavailable, notes[h % notes.length]);
        }
      }
    }

    // The sample employee: has at least one future shift to drop or give away, and has
    // answered for the next event only.
    if (me != null) {
      final mine = _shifts.values.where((s) => s.workerId == me.id && s.status == ShiftStatus.assigned && s.callTime.isAfter(now.add(const Duration(days: 2))));
      if (mine.isEmpty) {
        for (final e in upcoming.skip(1)) {
          final open = _shifts.values
              .where((s) => s.eventId == e.id && s.isOpen && me.jobRoles.contains(s.jobRoleCode) && _blockReason(me, e, s.jobRoleCode, s.id) == null)
              .firstOrNull;
          if (open != null && !_smHolds(me.id, e.id)) {
            _shifts[open.id] = open.copyWith(workerId: me.id, status: ShiftStatus.assigned);
            break;
          }
        }
      }
      _smAvailability.putIfAbsent(upcoming.first.id, () => {})[me.id] = (AvailabilityStatus.available, '');
      final start = venueDate(now, _smZone).add(const Duration(days: 35));
      _smBlackouts['demo-blackout-me'] = (me.id, Blackout(id: 'demo-blackout-me', startsOn: start, endsOn: start.add(const Duration(days: 3)), note: 'Family trip'));
    }

    // Someone is away for the second upcoming event.
    final away = active.where((w) => !personaWorkers.contains(w.id) && w.jobRoles.contains('cashier')).skip(3).firstOrNull;
    if (away != null && upcoming.length > 1) {
      final day = venueDate(upcoming[1].callTime, _smZone);
      _smBlackouts['demo-blackout-1'] =
          (away.id, Blackout(id: 'demo-blackout-1', startsOn: day.subtract(const Duration(days: 1)), endsOn: day.add(const Duration(days: 2)), note: 'Out of town'));
      _smAvailability[upcoming[1].id]?.remove(away.id);
    }

    final future = [for (final e in upcoming) if (e.callTime.isAfter(now.add(const Duration(hours: 48)))) e];
    Shift? assignedIn(Event e, bool Function(Shift s) test) => _shifts.values
        .where((s) => s.eventId == e.id && s.status == ShiftStatus.assigned && !used.contains(s.id) && !personaWorkers.contains(s.workerId) && test(s))
        .firstOrNull;
    void add(_SmRequest q) {
      _smRequests[q.id] = q;
      used.add(q.shiftId);
    }

    // 1. A coworker offers the sample employee one of their shifts.
    if (me != null) {
      for (final e in future) {
        if (_smHolds(me.id, e.id)) continue;
        final s = assignedIn(e, (s) => me.jobRoles.contains(s.jobRoleCode) && _blockReason(me, e, s.jobRoleCode, s.id) == null);
        if (s == null) continue;
        add(_SmRequest(
          id: _id(),
          kind: ShiftRequestKind.swap,
          shiftId: s.id,
          requesterId: s.workerId!,
          targetId: me.id,
          status: ShiftRequestStatus.offered,
          note: 'Can you cover for me? My sister\'s graduation is that night.',
          createdAt: ago(3),
        ));
        break;
      }
    }

    // 2. Pickups waiting for a manager: an adult, then a 14- or 15-year-old (the rules
    // engine warns about the late finish).
    var pickups = 0;
    for (final wantMinor in [false, true]) {
      outer:
      for (final e in upcoming.take(4)) {
        for (final s in _shifts.values.where((s) => s.eventId == e.id && s.isOpen && !used.contains(s.id))) {
          for (final w in active) {
            if (personaWorkers.contains(w.id) || !w.jobRoles.contains(s.jobRoleCode) || _smHolds(w.id, e.id)) continue;
            final age = _ageOn(w, e);
            if (wantMinor ? !(age != null && age < 16) : (age == null || age < 18)) continue;
            if (_blockReason(w, e, s.jobRoleCode, s.id) != null) continue;
            if (_smRequests.values.any((q) => q.requesterId == w.id)) continue;
            add(_SmRequest(id: _id(), kind: ShiftRequestKind.pickup, shiftId: s.id, requesterId: w.id, note: wantMinor ? 'I can stay until 10' : 'Happy to work this one', createdAt: ago(5 + pickups)));
            pickups++;
            break outer;
          }
        }
      }
    }

    // 3. A drop request.
    for (final e in future) {
      final s = assignedIn(e, (s) => s.jobRoleCode != 'lead');
      if (s == null) continue;
      add(_SmRequest(id: _id(), kind: ShiftRequestKind.drop, shiftId: s.id, requesterId: s.workerId!, note: 'School exam the next morning', createdAt: ago(20)));
      break;
    }

    // 4. A swap the coworker accepted, at the sample lead's storefront when possible.
    final leadStore = _sessionsByPin['300003']?.grants.first.scopeId;
    for (final preferLead in [true, false]) {
      var done = false;
      for (final e in future) {
        final s = assignedIn(e, (s) => s.jobRoleCode != 'lead' && (!preferLead || s.storefrontId == leadStore));
        if (s == null) continue;
        final to = active.where((w) =>
            w.id != s.workerId &&
            !personaWorkers.contains(w.id) &&
            w.jobRoles.contains(s.jobRoleCode) &&
            !_smHolds(w.id, e.id) &&
            _blockReason(w, e, s.jobRoleCode, s.id) == null).firstOrNull;
        if (to == null) continue;
        add(_SmRequest(id: _id(), kind: ShiftRequestKind.swap, shiftId: s.id, requesterId: s.workerId!, targetId: to.id, note: 'Trading for a family wedding', createdAt: ago(26)));
        done = true;
        break;
      }
      if (done) break;
    }

    // 5. History: a pickup approved and a drop denied yesterday; the sample employee's
    // earlier pickup that was denied.
    for (final (kind, approve) in [(ShiftRequestKind.pickup, true), (ShiftRequestKind.drop, false)]) {
      for (final e in upcoming) {
        final s = assignedIn(e, (s) => s.jobRoleCode != 'lead');
        if (s == null) continue;
        add(_SmRequest(id: _id(), kind: kind, shiftId: s.id, requesterId: s.workerId!, createdAt: ago(40), note: approve ? '' : 'Concert tickets')
          ..status = approve ? ShiftRequestStatus.approved : ShiftRequestStatus.denied
          ..decidedAt = ago(30)
          ..decidedByName = 'Marcus Bell'
          ..decisionNote = approve ? '' : 'We are short that night. Try a swap.');
        break;
      }
    }
    if (me != null) {
      final s = _shifts.values
          .where((s) => s.isOpen && !used.contains(s.id) && me.jobRoles.contains(s.jobRoleCode) && _events[s.eventId]!.callTime.isAfter(now))
          .firstOrNull;
      if (s != null) {
        add(_SmRequest(id: _id(), kind: ShiftRequestKind.pickup, shiftId: s.id, requesterId: me.id, createdAt: ago(50))
          ..status = ShiftRequestStatus.denied
          ..decidedAt = ago(46)
          ..decidedByName = 'Marcus Bell'
          ..decisionNote = 'Enough cashiers that night. Thank you for asking!');
      }
    }
  }

  // ---- Employee ----

  @override
  Future<List<OpenShift>> openShiftsForMe() => _delay(() {
        _smEnsure();
        final w = _smMe();
        final now = _smNow;
        final busy = {
          for (final s in _shifts.values)
            if (s.workerId == w.id && (s.status == ShiftStatus.assigned || s.status == ShiftStatus.released)) s.eventId,
        };
        final rows = <OpenShift>[];
        for (final s in _shifts.values) {
          final e = _events[s.eventId]!;
          if (!s.isOpen || !s.callTime.isAfter(now) || !_smUpcoming(e) || !w.jobRoles.contains(s.jobRoleCode) || busy.contains(e.id)) continue;
          final f = _smStorefront(s.storefrontId);
          rows.add(OpenShift(
            shift: s,
            event: e,
            storefrontName: f?.name ?? '',
            storefrontCode: f?.code ?? '',
            section: f?.section ?? '',
            roleName: _smRoleName(s.jobRoleCode),
            blocked: _blockReason(w, e, s.jobRoleCode, s.id),
            myRequestId: _smRequests.values
                .where((q) => q.shiftId == s.id && q.requesterId == w.id && q.kind == ShiftRequestKind.pickup && q.status == ShiftRequestStatus.pending)
                .firstOrNull
                ?.id,
            availability: _smAvailability[e.id]?[w.id]?.$1,
          ));
        }
        rows.sort((a, b) {
          final c = a.shift.callTime.compareTo(b.shift.callTime);
          return c != 0 ? c : a.storefrontName.compareTo(b.storefrontName);
        });
        return rows;
      });

  @override
  Future<ShiftRequest> requestPickup(String shiftId, {String note = ''}) => _delay(() {
        _smEnsure();
        final w = _smMe();
        final s = _shifts[shiftId];
        if (s == null) throw const AppFailure('Shift not found');
        final e = _events[s.eventId]!;
        final cfg = _smSettings;
        if (!cfg.allowPickups) throw const AppFailure('Picking up shifts is turned off at this venue');
        if (!s.isOpen) throw const AppFailure('This shift is already filled');
        if (!s.callTime.isAfter(_smNow) || !_smUpcoming(e)) throw const AppFailure('This shift is no longer available');
        if (!w.jobRoles.contains(s.jobRoleCode)) throw const AppFailure('You are not trained for this role');
        final block = _blockReason(w, e, s.jobRoleCode, s.id);
        if (block != null) throw AppFailure(block);
        if (_smHasOpen(s.id, w.id)) throw const AppFailure('You already asked for this shift');
        final q = _SmRequest(id: _id(), kind: ShiftRequestKind.pickup, shiftId: s.id, requesterId: w.id, note: note, createdAt: _smNow);
        _smRequests[q.id] = q;
        if (cfg.pickupsNeedApproval) {
          _smNotifySchedulers(s, 'shift_request', 'Pickup request: ${w.displayName}');
        } else {
          q
            ..status = ShiftRequestStatus.approved
            ..decidedAt = _smNow
            ..decisionNote = 'Approved automatically';
          _smSetWorker(s, w.id, 'Picked up by employee');
          _smNotifySchedulers(s, 'schedule_changed', 'Shift picked up: ${w.displayName}');
        }
        return _smView(q);
      });

  Shift _smMine(Worker w, String shiftId) {
    final s = _shifts[shiftId];
    if (s == null || s.workerId != w.id || s.status != ShiftStatus.assigned) throw const AppFailure('This is not one of your shifts');
    return s;
  }

  @override
  Future<void> requestDrop(String shiftId, {String reason = ''}) => _delay(() {
        _smEnsure();
        final w = _smMe();
        final s = _smMine(w, shiftId);
        final cfg = _smSettings;
        if (!cfg.allowDrops) throw const AppFailure('Dropping shifts is turned off at this venue. Talk to your manager.');
        if (_smClockedIn(w.id, s.eventId)) throw const AppFailure('You have already clocked in for this event');
        if (_smNow.isAfter(cfg.dropDeadline(s.callTime))) {
          throw AppFailure('Drops close ${cfg.dropCutoffHours} hours before call time. Talk to your manager.');
        }
        if (_smHasOpen(s.id, w.id)) throw const AppFailure('You already have a request open for this shift');
        final q = _SmRequest(id: _id(), kind: ShiftRequestKind.drop, shiftId: s.id, requesterId: w.id, note: reason, createdAt: _smNow);
        _smRequests[q.id] = q;
        _smNotifySchedulers(s, 'shift_request', 'Drop request: ${w.displayName}');
      });

  bool _smCanTake(Worker c, Shift s) =>
      c.status == 'active' && c.jobRoles.contains(s.jobRoleCode) && _blockReason(c, _events[s.eventId]!, s.jobRoleCode, s.id) == null;

  @override
  Future<List<SwapCandidate>> swapCandidates(String shiftId) => _delay(() {
        _smEnsure();
        final w = _smMe();
        final s = _smMine(w, shiftId);
        // In the demo nobody has a sign-in of their own, so everyone eligible is listed.
        return [
          for (final c in _workers.values)
            if (c.id != w.id && _smCanTake(c, s))
              SwapCandidate(id: c.id, name: c.displayName, availability: _smAvailability[s.eventId]?[c.id]?.$1),
        ]..sort((a, b) => a.name.compareTo(b.name));
      });

  @override
  Future<void> offerSwap(String shiftId, String toWorkerId, {String note = ''}) => _delay(() {
        _smEnsure();
        final w = _smMine(_smMe(), shiftId).workerId!;
        final s = _shifts[shiftId]!;
        if (!_smSettings.allowSwaps) throw const AppFailure('Swapping shifts is turned off at this venue');
        if (!s.callTime.isAfter(_smNow) || _smClockedIn(w, s.eventId)) throw const AppFailure('This shift has already started');
        final t = _workers[toWorkerId];
        if (t == null || t.id == w) throw const AppFailure('Choose a coworker');
        if (!t.jobRoles.contains(s.jobRoleCode)) throw const AppFailure('This coworker is not trained for this role');
        final block = _blockReason(t, _events[s.eventId]!, s.jobRoleCode, s.id);
        if (block != null) throw AppFailure(block);
        if (_smHasOpen(s.id, w)) throw const AppFailure('You already have a request open for this shift');
        final q = _SmRequest(
          id: _id(),
          kind: ShiftRequestKind.swap,
          shiftId: s.id,
          requesterId: w,
          targetId: t.id,
          status: ShiftRequestStatus.offered,
          note: note,
          createdAt: _smNow,
        );
        _smRequests[q.id] = q;
        _notifyWorker(t.id, kind: 'shift_offered', title: '${_smName(w)} offered you a shift', body: _smLabel(s), link: '/schedule');
      });

  @override
  Future<void> respondSwap(String requestId, {required bool accept}) => _delay(() {
        _smEnsure();
        final w = _smMe();
        final q = _smRequests[requestId];
        if (q == null || q.targetId != w.id) throw const AppFailure('This offer is not for you');
        if (q.status != ShiftRequestStatus.offered) throw const AppFailure('This offer is no longer open');
        final s = _shifts[q.shiftId]!;
        if (accept) {
          if (s.workerId != q.requesterId || s.status != ShiftStatus.assigned || !s.callTime.isAfter(_smNow)) {
            throw const AppFailure('This offer is no longer open');
          }
          final block = _blockReason(w, _events[s.eventId]!, s.jobRoleCode, s.id);
          if (block != null) throw AppFailure(block);
          q.status = ShiftRequestStatus.pending;
          _notifyWorker(q.requesterId, kind: 'request_update', title: '${w.displayName} accepted your swap. A manager will approve it.', body: _smLabel(s), link: '/schedule');
          _smNotifySchedulers(s, 'shift_request', 'Swap request: ${_smName(q.requesterId)} → ${w.displayName}');
        } else {
          q
            ..status = ShiftRequestStatus.denied
            ..decidedAt = _smNow
            ..decidedByName = w.displayName
            ..decisionNote = 'Declined by coworker';
          _notifyWorker(q.requesterId, kind: 'request_update', title: '${w.displayName} declined your swap', body: _smLabel(s), link: '/schedule');
        }
      });

  @override
  Future<void> cancelShiftRequest(String requestId) => _delay(() {
        _smEnsure();
        final w = _smMe();
        final q = _smRequests[requestId];
        if (q == null || q.requesterId != w.id) throw const AppFailure('This is not your request');
        if (!q.isOpen) throw const AppFailure('This request was already decided');
        q.status = ShiftRequestStatus.cancelled;
        if (q.targetId != null) {
          _notifyWorker(q.targetId, kind: 'request_update', title: '${w.displayName} withdrew the shift offer', body: _smLabel(_shifts[q.shiftId]!), link: '/schedule');
        }
      });

  @override
  Future<List<ShiftRequest>> myShiftRequests() => _delay(() {
        _smEnsure();
        _smExpire();
        final w = _smMe();
        final since = _smNow.subtract(const Duration(days: 60));
        return [
          for (final q in _smRequests.values)
            if ((q.requesterId == w.id || q.targetId == w.id) && (q.isOpen || q.createdAt.isAfter(since))) _smView(q),
        ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      });

  @override
  Future<MyAvailability> myAvailability() => _delay(() {
        _smEnsure();
        final w = _smMe();
        final now = _smNow;
        final until = now.add(const Duration(days: 90));
        final events = [
          for (final e in _events.values)
            if (_smUpcoming(e) && e.callTime.isAfter(now) && e.callTime.isBefore(until))
              EventAvailability(
                event: e,
                status: _smAvailability[e.id]?[w.id]?.$1,
                note: _smAvailability[e.id]?[w.id]?.$2 ?? '',
                scheduled: _smHolds(w.id, e.id),
              ),
        ]..sort((a, b) => a.event.callTime.compareTo(b.event.callTime));
        final today = venueDate(now, _smZone);
        final blackouts = [
          for (final b in _smBlackouts.values)
            if (b.$1 == w.id && !b.$2.endsOn.isBefore(today)) b.$2,
        ]..sort((a, b) => a.startsOn.compareTo(b.startsOn));
        return MyAvailability(events: events, blackouts: blackouts);
      });

  @override
  Future<void> setEventAvailability(String eventId, AvailabilityStatus? status, {String note = ''}) => _delay(() {
        _smEnsure();
        final w = _smMe();
        final e = _events[eventId];
        if (e == null) throw const AppFailure('Event not found');
        if (!_smUpcoming(e) || !e.callTime.isAfter(_smNow)) throw const AppFailure('This event has already started');
        final answers = _smAvailability.putIfAbsent(eventId, () => {});
        if (status == null) {
          answers.remove(w.id);
        } else {
          answers[w.id] = (status, note);
        }
      });

  @override
  Future<Blackout> setBlackout(DateTime startsOn, DateTime endsOn, {String note = '', String? id}) => _delay(() {
        _smEnsure();
        final w = _smMe();
        final start = DateTime.utc(startsOn.year, startsOn.month, startsOn.day);
        final end = DateTime.utc(endsOn.year, endsOn.month, endsOn.day);
        if (end.isBefore(start)) throw const AppFailure('The end date must be on or after the start date');
        if (end.difference(start).inDays > 366) throw const AppFailure('A blackout can be at most a year');
        if (end.isBefore(venueDate(_smNow, _smZone))) throw const AppFailure('These dates are in the past');
        if (id != null && _smBlackouts[id]?.$1 != w.id) throw const AppFailure('Blackout not found');
        final b = Blackout(id: id ?? _id(), startsOn: start, endsOn: end, note: note);
        _smBlackouts[b.id] = (w.id, b);
        return b;
      });

  @override
  Future<void> deleteBlackout(String id) => _delay(() {
        _smEnsure();
        final w = _smMe();
        if (_smBlackouts[id]?.$1 != w.id) throw const AppFailure('Blackout not found');
        _smBlackouts.remove(id);
      });

  // ---- Manager ----

  @override
  Future<List<ShiftRequest>> reviewShiftRequests({bool history = false}) => _delay(() {
        _smEnsure();
        _smExpire();
        final scope = _scope(_me, {'manage_schedule'});
        if (scope.isEmpty) throw const AppFailure('Not authorized');
        final rows = [
          for (final q in _smRequests.values)
            if (scope.contains(_shifts[q.shiftId]!.storefrontId) && q.isOpen != history) _smView(q, rules: true),
        ];
        if (history) {
          rows.sort((a, b) => (b.decidedAt ?? b.createdAt).compareTo(a.decidedAt ?? a.createdAt));
        } else {
          rows.sort((a, b) => a.shift.callTime.compareTo(b.shift.callTime));
        }
        return rows.take(200).toList();
      });

  @override
  Future<void> decideShiftRequest(String requestId, {required bool approve, String note = '', List<String> warnings = const []}) => _delay(() {
        _smEnsure();
        final q = _smRequests[requestId];
        if (q == null) throw const AppFailure('Request not found');
        final s = _shifts[q.shiftId]!;
        _requireManage(s.storefrontId);
        if (q.status == ShiftRequestStatus.offered) throw const AppFailure('The coworker has not accepted this swap yet');
        if (q.status != ShiftRequestStatus.pending) throw const AppFailure('This request was already decided');
        final e = _events[s.eventId]!;
        final text = note.trim();
        final label = _smLabel(s);
        final kindName = switch (q.kind) {
          ShiftRequestKind.pickup => 'Pickup',
          ShiftRequestKind.drop => 'Drop',
          ShiftRequestKind.swap => 'Swap',
        };
        if (approve) {
          if (!s.callTime.isAfter(_smNow)) throw const AppFailure('This shift has already started');
          if (warnings.isNotEmpty && text.isEmpty) throw const AppFailure('Give a reason to approve despite warnings');
          final suffix = text.isEmpty ? '' : ': $text';
          switch (q.kind) {
            case ShiftRequestKind.pickup:
              if (!s.isOpen) throw const AppFailure('This position is already filled. Deny the request.');
              final block = _blockReason(_workers[q.requesterId]!, e, s.jobRoleCode, s.id);
              if (block != null) throw AppFailure(block);
              _smSetWorker(s, q.requesterId, 'Pickup approved$suffix');
              for (final other in _smRequests.values.where((o) => o.shiftId == s.id && o.id != q.id && o.isOpen)) {
                other
                  ..status = ShiftRequestStatus.expired
                  ..decisionNote = 'Filled by someone else';
                _notifyWorker(other.requesterId, kind: 'request_decided', title: 'Shift filled', body: label, link: '/schedule');
              }
            case ShiftRequestKind.drop:
            case ShiftRequestKind.swap:
              if (s.workerId != q.requesterId || s.status != ShiftStatus.assigned) throw const AppFailure('This person no longer holds this position');
              if (_smClockedIn(q.requesterId, s.eventId)) throw const AppFailure('This person has already clocked in. Move or release them instead.');
              if (q.kind == ShiftRequestKind.drop) {
                _smSetWorker(s, null, 'Drop approved$suffix${q.note.isEmpty ? '' : ' (employee: ${q.note})'}');
              } else {
                final block = _blockReason(_workers[q.targetId]!, e, s.jobRoleCode, s.id);
                if (block != null) throw AppFailure(block);
                _smSetWorker(s, q.targetId, 'Swap approved: ${_smName(q.requesterId)} → ${_smName(q.targetId)}$suffix');
              }
          }
        }
        q
          ..status = approve ? ShiftRequestStatus.approved : ShiftRequestStatus.denied
          ..decidedAt = _smNow
          ..decidedByName = _me.displayName
          ..decisionNote = text
          ..warnings = approve ? List.of(warnings) : const [];
        final title = '$kindName ${approve ? 'approved' : 'denied'}';
        final body = text.isEmpty ? label : '$label\n$text';
        _notifyWorker(q.requesterId, kind: 'request_decided', title: title, body: body, link: '/schedule');
        if (q.targetId != null) _notifyWorker(q.targetId, kind: 'request_decided', title: title, body: body, link: '/schedule');
      });

  @override
  Future<List<MarketCandidate>> candidatesWithAvailability(String eventId, String jobRole) async {
    _smEnsure();
    final list = await candidates(eventId, jobRole);
    return [for (final c in list) MarketCandidate(worker: c, availability: _smCandidate(eventId, c.id))];
  }
}
