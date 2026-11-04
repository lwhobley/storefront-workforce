import 'dart:async';
import 'dart:typed_data';

import 'package:workforce_core/workforce_core.dart';

import '../core/time/venue_time.dart';
import 'models.dart';
import 'workforce_repository.dart';

/// A demo persona: a PIN that signs in as one role in the sample arena.
class DemoPersona {
  const DemoPersona(this.pin, this.label, this.description);

  final String pin;
  final String label;
  final String description;
}

/// Runs the fictional Pecan Valley Arena in memory, with one game live right now. Every
/// action works (assign, move, send home, clock in) and follows the same rules as the
/// real database, but nothing is saved after the page closes.
class DemoWorkforceRepository implements WorkforceRepository {
  DemoWorkforceRepository({DateTime? now}) : _arena = SampleArena.generate(now: now ?? DateTime.now().toUtc()) {
    _shifts = {for (final s in _arena.shifts) s.id: s};
    _punches = [..._arena.punches];
    _events = {for (final e in _arena.events) e.id: e};
    _openStorefronts = {};
    for (final es in _arena.eventStorefronts) {
      if (es.isOpen) _openStorefronts.putIfAbsent(es.eventId, () => {}).add(es.storefrontId);
    }
    _needs = [..._arena.eventStaffingNeeds];
    _workers = {for (final w in _arena.workers) w.id: w};
    _pickPersonas();
  }

  final SampleArena _arena;
  late Map<String, Shift> _shifts;
  late List<Punch> _punches;
  late Map<String, Event> _events;
  late Map<String, Set<String>> _openStorefronts;
  late List<StaffingNeed> _needs;
  late Map<String, Worker> _workers;
  final List<AssignmentChange> _changes = [];
  final Map<String, StreamController<void>> _streams = {};
  final Map<String, AppSession> _sessionsByPin = {};
  AppSession? _session;
  int _seq = 0;

  static const personas = [
    DemoPersona('100001', 'Admin / GM', 'Sees everything'),
    DemoPersona('200002', 'Concessions Manager', 'Runs the event, all storefronts'),
    DemoPersona('300003', 'Storefront Lead', 'Sees only their storefront'),
    DemoPersona('400004', 'Employee', 'Own schedule and clock-in'),
    DemoPersona('400005', 'Empleado (español)', 'Employee who prefers Spanish'),
    DemoPersona('500005', 'Kiosk', 'Shared clock-in tablet'),
  ];

  /// In the demo, a kiosk PIN is 90 followed by the 4 digits of the employee number
  /// (E1023 is 901023).
  static String kioskPinFor(Worker w) => '90${w.employeeNumber.replaceAll(RegExp(r'[^0-9]'), '').padLeft(4, '0')}';

  @override
  bool get isDemo => true;

  Event? get liveEvent => _arena.liveEvent;

  RoleGrant _grant(String role, Set<String> perms, {String scopeType = 'venue', String? scopeId}) =>
      RoleGrant(roleCode: role, permissions: perms, scopeType: scopeType, scopeId: scopeId);

  static const _managerPerms = {
    'view_live', 'manage_events', 'manage_schedule', 'view_workers', 'manage_workers', 'edit_time', 'approve_time',
    'view_pay', 'export_payroll', 'view_reports', 'view_audit', 'punch_self',
  };

  void _pickPersonas() {
    final venue = _arena.venue;
    final live = _arena.liveEvent;
    final liveShifts = live == null ? <Shift>[] : _shifts.values.where((s) => s.eventId == live.id).toList();

    // Lead: the lead at a storefront that has someone missing, so their view has work.
    Shift? leadShift;
    for (final s in liveShifts.where((s) => s.jobRoleCode == 'lead' && s.workerId != null)) {
      final others = liveShifts.where((o) => o.storefrontId == s.storefrontId);
      if (others.any((o) => o.workerId == null)) {
        leadShift = s;
        break;
      }
      leadShift ??= s;
    }
    // Employees: regular staff at the live event who have not clocked in yet, so the
    // clock-in flow can be tried; fall back to anyone working.
    final clockedIn = {for (final p in _punches) if (p.eventId == live?.id) p.workerId};
    Worker? pickEmployee(String lang) {
      for (final s in liveShifts) {
        final w = _workers[s.workerId];
        if (w != null && w.preferredLanguage == lang && !clockedIn.contains(w.id) &&
            s.status == ShiftStatus.assigned && s.jobRoleCode != 'lead') {
          return w;
        }
      }
      for (final s in liveShifts) {
        final w = _workers[s.workerId];
        if (w != null && w.preferredLanguage == lang && s.status == ShiftStatus.assigned) return w;
      }
      return null;
    }

    final en = pickEmployee('en');
    final es = pickEmployee('es');
    final leadWorker = _workers[leadShift?.workerId];

    _sessionsByPin['100001'] = AppSession(
      userId: 'demo-admin',
      displayName: 'Dana Whitfield',
      venue: venue,
      grants: [_grant('admin', {..._managerPerms, 'manage_settings', 'manage_users', 'kiosk_punch'})],
    );
    _sessionsByPin['200002'] = AppSession(
      userId: 'demo-manager',
      displayName: 'Marcus Bell',
      venue: venue,
      grants: [_grant('concessions_manager', _managerPerms)],
    );
    if (leadShift != null && leadWorker != null) {
      _sessionsByPin['300003'] = AppSession(
        userId: 'demo-lead',
        displayName: leadWorker.displayName,
        venue: venue,
        workerId: leadWorker.id,
        grants: [
          _grant('storefront_lead', {'view_live', 'manage_schedule', 'punch_self'}, scopeType: 'storefront', scopeId: leadShift.storefrontId),
          _grant('employee', {'punch_self'}),
        ],
      );
    }
    for (final (pin, w) in [('400004', en), ('400005', es)]) {
      if (w == null) continue;
      _sessionsByPin[pin] = AppSession(
        userId: 'demo-${w.id}',
        displayName: w.displayName,
        venue: venue,
        workerId: w.id,
        language: w.preferredLanguage,
        grants: [_grant('employee', {'punch_self'})],
      );
    }
    _sessionsByPin['500005'] = AppSession(
      userId: 'demo-kiosk',
      displayName: 'North Entrance Kiosk',
      venue: venue,
      isKiosk: true,
      grants: [_grant('kiosk', {'kiosk_punch'})],
    );
  }

  Future<T> _delay<T>(T Function() body) async {
    await Future<void>.delayed(const Duration(milliseconds: 120));
    return body();
  }

  String _id() {
    _seq++;
    final n = _seq.toRadixString(16).padLeft(12, '0');
    return 'dddddddd-0000-4000-8000-$n';
  }

  void _changed(String eventId) => _streams[eventId]?.add(null);

  // ---- Sign-in ----

  @override
  Future<AppSession> signInWithPin(String pin) => _delay(() {
        final s = _sessionsByPin[pin];
        if (s == null) throw const AppFailure('That PIN is not recognized.');
        return _session = s;
      });

  @override
  Future<AppSession?> restoreSession() async => _session;

  @override
  Future<void> signOut() async => _session = null;

  // ---- Venue ----

  @override
  Future<VenueContext> loadVenue(AppSession session) => _delay(() => VenueContext(
        venue: _arena.venue,
        levels: _arena.levels,
        storefronts: _arena.storefronts,
        stations: _arena.stations,
        jobRoles: _arena.jobRoles,
        certificationTypes: _arena.certificationTypes,
        eventTypes: const {'hockey': 'Hockey game', 'concert': 'Concert', 'family_show': 'Family show', 'other': 'Other event'},
        defaultNeeds: _arena.staffingNeeds,
        agencies: _arena.agencies,
        npoGroups: _arena.npoGroups,
      ));

  @override
  Future<List<Worker>> listWorkers(AppSession session) => _delay(() {
        if (session.canVenueWide(Perm.viewWorkers)) return _workers.values.toList()..sort((a, b) => a.lastName.compareTo(b.lastName));
        return [for (final w in _workers.values) if (w.id == session.workerId) w];
      });

  @override
  Future<String> issuePin(AppSession session, Worker worker) => _delay(() => kioskPinFor(worker));

  // ---- Events ----

  @override
  Future<List<Event>> listEvents(AppSession session) => _delay(() => _events.values.toList()..sort((a, b) => a.startTime.compareTo(b.startTime)));

  @override
  Future<Event> updateEvent(Event event, {DateTime? callTime, DateTime? doorsTime, int? expectedAttendance, int? actualAttendance, EventStatus? status}) =>
      _delay(() {
        final e = _events[event.id]!;
        final updated = Event(
          id: e.id,
          venueId: e.venueId,
          name: e.name,
          eventTypeCode: e.eventTypeCode,
          startTime: e.startTime,
          callTime: callTime ?? e.callTime,
          doorsTime: doorsTime ?? e.doorsTime,
          endTime: e.endTime,
          expectedAttendance: expectedAttendance ?? e.expectedAttendance,
          actualAttendance: actualAttendance ?? e.actualAttendance,
          status: status ?? e.status,
          source: e.source,
          externalId: e.externalId,
          notes: e.notes,
        );
        if (!(updated.callTime.isAfter(updated.doorsTime)) && !updated.doorsTime.isAfter(updated.startTime)) {
          _events[e.id] = updated;
          return updated;
        }
        throw const AppFailure('Call time must be before doors, and doors before start.');
      });

  @override
  Future<String> syncEvents(AppSession session) =>
      _delay(() => 'Demo mode: events come from the sample calendar. With a backend, this pulls from Premium Command.');

  // ---- Board ----

  Set<String> _scope(AppSession s, Set<String> perms) {
    final all = {for (final f in _arena.storefronts) f.id};
    final result = <String>{};
    for (final g in s.grants) {
      if (!g.permissions.any(perms.contains)) continue;
      if (g.scopeType == 'venue') return all;
      if (g.scopeType == 'storefront' && g.scopeId != null) result.add(g.scopeId!);
      if (g.scopeType == 'level') {
        result.addAll([for (final f in _arena.storefronts) if (f.levelId == g.scopeId) f.id]);
      }
    }
    return result;
  }

  AppSession get _me {
    final s = _session;
    if (s == null) throw const AppFailure('Not signed in');
    return s;
  }

  int? _ageOn(Worker w, Event e) => w.ageOn(venueDate(e.callTime, _arena.venue.timeZone));

  BoardWorker _boardWorker(Worker w, Event e) => BoardWorker(worker: w, ageOnEvent: _ageOn(w, e));

  @override
  Future<EventBoard> loadBoard(String eventId) => _delay(() {
        final me = _me;
        final event = _events[eventId]!;
        final scope = _scope(me, {'view_live', 'manage_schedule'});
        if (scope.isEmpty) throw const AppFailure('Not authorized');
        final shifts = [for (final s in _shifts.values) if (s.eventId == eventId && scope.contains(s.storefrontId) && s.status != ShiftStatus.cancelled) s];
        final workerIds = {for (final s in shifts) ?s.workerId};
        final tz = _arena.venue.timeZone;
        final weekStart = workweekStart(event.callTime, tz, me.rules.overtime.workweekStartDay);
        return EventBoard(
          event: event,
          timeZone: tz,
          weekStart: weekStart,
          storefrontIds: scope,
          openStorefrontIds: {...(_openStorefronts[eventId] ?? const {})}.intersection(scope),
          needs: [for (final n in _needs) if (n.eventId == eventId && scope.contains(n.storefrontId)) n],
          shifts: shifts,
          workers: {for (final id in workerIds) id: _boardWorker(_workers[id]!, event)},
          punches: [
            for (final p in _punches)
              if (workerIds.contains(p.workerId) &&
                  p.status != PunchStatus.voided &&
                  (p.eventId == eventId || (!p.occurredAt.isBefore(weekStart) && p.occurredAt.isBefore(event.callTime))))
                p,
          ],
          changes: [
            for (final c in _changes.reversed)
              if (c.eventId == eventId && (scope.contains(c.fromStorefrontId) || scope.contains(c.toStorefrontId))) c,
          ],
          canManageAll: me.canVenueWide(Perm.manageSchedule),
        );
      });

  @override
  Stream<void> boardChanges(String eventId) => (_streams[eventId] ??= StreamController<void>.broadcast()).stream;

  void _requireManage(String storefrontId) {
    if (!_scope(_me, {'manage_schedule'}).contains(storefrontId)) throw const AppFailure('Not authorized for this storefront');
  }

  @override
  Future<void> setOpenStorefronts(String eventId, List<String> storefrontIds) => _delay(() {
        if (!_me.canVenueWide(Perm.manageEvents)) throw const AppFailure('Not authorized');
        final before = _openStorefronts[eventId] ?? {};
        _openStorefronts[eventId] = {...storefrontIds};
        for (final id in storefrontIds.where((id) => !before.contains(id))) {
          if (_needs.any((n) => n.eventId == eventId && n.storefrontId == id)) continue;
          for (final d in _arena.staffingNeeds.where((n) => n.storefrontId == id)) {
            _needs.add(StaffingNeed(eventId: eventId, storefrontId: id, jobRoleCode: d.jobRoleCode, count: d.count));
          }
        }
        _changed(eventId);
      });

  @override
  Future<void> setStaffingNeed(String eventId, String storefrontId, String jobRole, int count) => _delay(() {
        _requireManage(storefrontId);
        _needs.removeWhere((n) => n.eventId == eventId && n.storefrontId == storefrontId && n.jobRoleCode == jobRole);
        _needs.add(StaffingNeed(eventId: eventId, storefrontId: storefrontId, jobRoleCode: jobRole, count: count));
        _changed(eventId);
      });

  @override
  Future<int> generateOpenShifts(String eventId) => _delay(() {
        final event = _events[eventId]!;
        final scope = _scope(_me, {'manage_schedule'});
        var created = 0;
        for (final n in _needs.where((n) => n.eventId == eventId && scope.contains(n.storefrontId))) {
          if (!(_openStorefronts[eventId]?.contains(n.storefrontId) ?? false)) continue;
          final have = _shifts.values
              .where((s) => s.eventId == eventId && s.storefrontId == n.storefrontId && s.jobRoleCode == n.jobRoleCode && s.status != ShiftStatus.cancelled)
              .length;
          for (var i = have; i < n.count; i++) {
            final id = _id();
            _shifts[id] = Shift(
              id: id,
              venueId: event.venueId,
              eventId: eventId,
              storefrontId: n.storefrontId,
              jobRoleCode: n.jobRoleCode,
              callTime: n.jobRoleCode == 'lead' ? event.callTime.subtract(const Duration(minutes: 30)) : event.callTime,
              scheduledEnd: (event.endTime ?? event.startTime.add(const Duration(hours: 3))).add(const Duration(minutes: 45)),
            );
            created++;
          }
        }
        _changed(eventId);
        return created;
      });

  /// Same hard checks as the database's assignment_block_reason().
  String? _blockReason(Worker w, Event e, String role, String shiftId) {
    final r = _arena.jobRoles.firstWhere((j) => j.code == role);
    if (w.status != 'active') return 'This person is inactive.';
    if (_shifts.values.any((s) => s.eventId == e.id && s.workerId == w.id && s.id != shiftId &&
        (s.status == ShiftStatus.assigned || s.status == ShiftStatus.released))) {
      return 'This person already has a position at this event.';
    }
    final age = _ageOn(w, e);
    if (age == null && r.minimumAge != null) return '${r.name} needs a birth date on file.';
    if (age != null && r.minimumAge != null && age < r.minimumAge!) return '${r.name} must be at least ${r.minimumAge}; this person is $age.';
    final rules = VenueRules.fromJson(_arena.venue.settings);
    if (rules.certifications.enforcement == CertificationEnforcement.block) {
      final check = checkCertifications(role: r, certs: w.certifications, onDate: venueDate(e.callTime, _arena.venue.timeZone), rules: rules.certifications);
      if (check.blocks) return '${r.name} needs a current certification.';
    }
    return null;
  }

  void _log(Shift after, String action, String? workerId, Shift before, String reason) {
    _changes.add(AssignmentChange(
      id: '${_changes.length + 1}',
      eventId: after.eventId,
      shiftId: after.id,
      action: action,
      changedAt: DateTime.now().toUtc(),
      workerId: workerId,
      fromStorefrontId: before.storefrontId,
      toStorefrontId: after.storefrontId,
      fromJobRoleCode: before.jobRoleCode,
      toJobRoleCode: after.jobRoleCode,
      reason: reason,
      changedByName: _me.displayName,
    ));
    _changed(after.eventId);
  }

  @override
  Future<List<BoardWorker>> candidates(String eventId, String jobRole) => _delay(() {
        final e = _events[eventId]!;
        final busy = {
          for (final s in _shifts.values)
            if (s.eventId == eventId && (s.status == ShiftStatus.assigned || s.status == ShiftStatus.released)) ?s.workerId,
        };
        return [
          for (final w in _workers.values)
            if (w.status == 'active' && w.jobRoles.contains(jobRole) && !busy.contains(w.id)) _boardWorker(w, e),
        ]..sort((a, b) => a.worker.lastName.compareTo(b.worker.lastName));
      });

  @override
  Future<void> assign(String shiftId, String workerId, {String reason = '', List<String> warnings = const []}) => _delay(() {
        final s = _shifts[shiftId]!;
        _requireManage(s.storefrontId);
        if (s.status != ShiftStatus.open) throw const AppFailure('This position is already filled');
        final block = _blockReason(_workers[workerId]!, _events[s.eventId]!, s.jobRoleCode, s.id);
        if (block != null) throw AppFailure(block);
        if (warnings.isNotEmpty && reason.trim().isEmpty) throw const AppFailure('Give a reason to assign despite warnings');
        final after = s.copyWith(workerId: workerId, status: ShiftStatus.assigned);
        _shifts[shiftId] = after;
        _log(after, 'assigned', workerId, s, reason);
      });

  @override
  Future<void> unassign(String shiftId, {String reason = ''}) => _delay(() {
        final s = _shifts[shiftId]!;
        _requireManage(s.storefrontId);
        if (_punches.any((p) => p.eventId == s.eventId && p.workerId == s.workerId)) {
          throw const AppFailure('This person has already clocked in. Move or release them instead.');
        }
        final after = s.copyWith(clearWorker: true, status: ShiftStatus.open);
        _shifts[shiftId] = after;
        _log(after, 'unassigned', s.workerId, s, reason);
      });

  @override
  Future<void> move(String shiftId, String storefrontId, {String? stationId, String? jobRole, required String reason, List<String> warnings = const []}) =>
      _delay(() {
        final s = _shifts[shiftId]!;
        _requireManage(s.storefrontId);
        _requireManage(storefrontId);
        if (reason.trim().isEmpty) throw const AppFailure('Give a reason for the move');
        final role = jobRole ?? s.jobRoleCode;
        if (role != s.jobRoleCode) {
          final block = _blockReason(_workers[s.workerId]!, _events[s.eventId]!, role, s.id);
          if (block != null) throw AppFailure(block);
        }
        final target = _shifts.values
            .where((o) => o.eventId == s.eventId && o.storefrontId == storefrontId && o.jobRoleCode == role && o.status == ShiftStatus.open)
            .firstOrNull;
        Shift after;
        if (target != null) {
          _shifts[s.id] = s.copyWith(clearWorker: true, status: ShiftStatus.open);
          after = target.copyWith(workerId: s.workerId, status: ShiftStatus.assigned, stationId: stationId);
        } else {
          after = s.copyWith(storefrontId: storefrontId, stationId: stationId, clearStation: stationId == null, jobRoleCode: role);
        }
        _shifts[after.id] = after;
        _log(after, 'moved', s.workerId, s, reason);
      });

  @override
  Future<void> release(String shiftId, String reason) => _delay(() {
        final s = _shifts[shiftId]!;
        _requireManage(s.storefrontId);
        if (s.status != ShiftStatus.assigned) throw const AppFailure('Only an assigned person can be sent home');
        final order = _shifts.values.where((o) => o.eventId == s.eventId).fold<int>(0, (m, o) => (o.releaseOrder ?? 0) > m ? o.releaseOrder! : m) + 1;
        final after = s.copyWith(status: ShiftStatus.released, releasedAt: DateTime.now().toUtc(), releaseOrder: order, releaseReason: reason);
        _shifts[shiftId] = after;
        _log(after, 'released', s.workerId, s, reason);
      });

  @override
  Future<void> unrelease(String shiftId, String reason) => _delay(() {
        final s = _shifts[shiftId]!;
        _requireManage(s.storefrontId);
        final after = Shift(
          id: s.id,
          venueId: s.venueId,
          eventId: s.eventId,
          storefrontId: s.storefrontId,
          stationId: s.stationId,
          jobRoleCode: s.jobRoleCode,
          workerId: s.workerId,
          callTime: s.callTime,
          scheduledEnd: s.scheduledEnd,
          status: ShiftStatus.assigned,
          version: s.version + 1,
        );
        _shifts[shiftId] = after;
        _log(after, 'unreleased', s.workerId, s, reason);
      });

  // ---- Employee ----

  MyDay _dayFor(String? workerId) {
    if (workerId == null) return const MyDay(worker: null, shifts: [], punches: []);
    final now = DateTime.now().toUtc();
    final mine = [
      for (final s in _shifts.values)
        if (s.workerId == workerId &&
            (s.status == ShiftStatus.assigned || s.status == ShiftStatus.released) &&
            s.callTime.isAfter(now.subtract(const Duration(hours: 14))) &&
            _events[s.eventId]!.status != EventStatus.completed &&
            _events[s.eventId]!.status != EventStatus.cancelled &&
            (_events[s.eventId]!.endTime ?? _events[s.eventId]!.startTime.add(const Duration(hours: 3)))
                .add(const Duration(hours: 2))
                .isAfter(now))
          s,
    ]..sort((a, b) => a.callTime.compareTo(b.callTime));
    final shifts = [
      for (final s in mine.take(8))
        MyShift(
          shift: s,
          event: _events[s.eventId]!,
          storefront: _arena.storefronts.where((f) => f.id == s.storefrontId).firstOrNull,
          stationName: _arena.stations.where((t) => t.id == s.stationId).firstOrNull?.name ?? '',
          roleName: _arena.jobRoles.where((r) => r.code == s.jobRoleCode).firstOrNull?.name ?? s.jobRoleCode,
        ),
    ];
    final eventId = shifts.isEmpty ? null : shifts.first.event.id;
    return MyDay(
      worker: _workers[workerId],
      shifts: shifts,
      punches: [for (final p in _punches) if (p.workerId == workerId && p.eventId == eventId) p]..sort((a, b) => a.occurredAt.compareTo(b.occurredAt)),
    );
  }

  @override
  Future<MyDay> loadMyDay(AppSession session) => _delay(() => _dayFor(session.workerId));

  Punch _store(String workerId, PunchDraft d, PunchSource source, {bool photo = false}) {
    final existing = _punches.where((p) => p.id == d.id).firstOrNull;
    if (existing != null) return existing;
    final p = Punch(
      id: d.id,
      venueId: _arena.venue.id,
      workerId: workerId,
      eventId: d.eventId,
      shiftId: d.shiftId,
      kind: d.kind,
      breakKind: d.breakKind,
      occurredAt: d.occurredAt,
      receivedAt: DateTime.now().toUtc(),
      source: source,
      latitude: d.latitude,
      longitude: d.longitude,
      withinGeofence: d.withinGeofence,
      photoPath: photo ? 'demo/${d.id}.jpg' : null,
    );
    _punches.add(p);
    if (d.eventId != null) _changed(d.eventId!);
    return p;
  }

  @override
  Future<Punch> sendPunch(AppSession session, PunchDraft draft, {Uint8List? photo}) => _delay(() {
        final workerId = session.workerId;
        if (workerId == null) throw const AppFailure('No staff record is linked to this sign-in');
        return _store(workerId, draft, PunchSource.phone, photo: photo != null);
      });

  // ---- Kiosk ----

  Worker _byKioskPin(String pin) {
    for (final w in _workers.values) {
      if (kioskPinFor(w) == pin) return w;
    }
    throw const AppFailure('That PIN is not recognized.');
  }

  @override
  Future<KioskIdentity> kioskIdentify(String pin) => _delay(() {
        final w = _byKioskPin(pin);
        final day = _dayFor(w.id);
        final current = day.current;
        return KioskIdentity(
          workerId: w.id,
          name: w.displayName,
          shiftId: current?.shift.id,
          eventId: current?.event.id,
          storefrontLabel: current?.storefront?.name ?? '',
          callTime: current?.shift.callTime,
          punches: day.punches,
        );
      });

  @override
  Future<void> kioskPunch(String pin, PunchDraft draft, {Uint8List? photo}) => _delay(() {
        final w = _byKioskPin(pin);
        _store(w.id, draft, PunchSource.kiosk, photo: photo != null);
      });

  /// A few workers at the live event with their kiosk PINs, shown on the demo kiosk.
  List<(String, String)> kioskSamples() {
    final live = _arena.liveEvent;
    if (live == null) return const [];
    final clockedIn = {for (final p in _punches) if (p.eventId == live.id) p.workerId};
    final out = <(String, String)>[];
    for (final s in _shifts.values.where((s) => s.eventId == live.id && s.status == ShiftStatus.assigned)) {
      final w = _workers[s.workerId]!;
      if (!clockedIn.contains(w.id)) out.add((w.displayName, kioskPinFor(w)));
      if (out.length >= 3) break;
    }
    for (final s in _shifts.values.where((s) => s.eventId == live.id && s.status == ShiftStatus.assigned)) {
      if (out.length >= 5) break;
      final w = _workers[s.workerId]!;
      if (clockedIn.contains(w.id)) out.add((w.displayName, kioskPinFor(w)));
    }
    return out;
  }
}
