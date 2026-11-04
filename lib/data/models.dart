import 'package:workforce_core/workforce_core.dart';

/// Permission codes, matching the database catalog.
abstract final class Perm {
  static const viewLive = 'view_live';
  static const manageEvents = 'manage_events';
  static const manageSchedule = 'manage_schedule';
  static const viewWorkers = 'view_workers';
  static const manageWorkers = 'manage_workers';
  static const punchSelf = 'punch_self';
  static const kioskPunch = 'kiosk_punch';
  static const manageSettings = 'manage_settings';
  static const manageUsers = 'manage_users';
  static const viewReports = 'view_reports';
}

/// One role a user holds, and where it applies.
class RoleGrant {
  const RoleGrant({required this.roleCode, required this.permissions, this.scopeType = 'venue', this.scopeId});

  final String roleCode;
  final Set<String> permissions;

  /// venue, level, storefront, npo_group, agency.
  final String scopeType;
  final String? scopeId;
}

/// Who is signed in, at which venue, and what they may do.
class AppSession {
  const AppSession({
    required this.userId,
    required this.displayName,
    required this.venue,
    required this.grants,
    this.workerId,
    this.isKiosk = false,
    this.language = 'en',
  });

  final String userId;
  final String displayName;
  final Venue venue;
  final List<RoleGrant> grants;

  /// The staff record of the signed-in person, when they work shifts.
  final String? workerId;
  final bool isKiosk;
  final String language;

  VenueRules get rules => VenueRules.fromJson(venue.settings);

  /// Holds the permission anywhere at the venue.
  bool can(String permission) => grants.any((g) => g.permissions.contains(permission));

  /// Holds the permission for the whole venue.
  bool canVenueWide(String permission) =>
      grants.any((g) => g.scopeType == 'venue' && g.permissions.contains(permission));

  /// Managers see the event tools; everyone else starts on their own clock screen.
  bool get isManagerView => can(Perm.viewLive) || can(Perm.manageSchedule) || can(Perm.manageEvents);

  String get roleLabel {
    if (isKiosk) return 'Kiosk';
    final codes = grants.map((g) => g.roleCode).toSet();
    for (final (code, label) in const [
      ('admin', 'Admin'),
      ('concessions_manager', 'Concessions Manager'),
      ('assistant_manager', 'Assistant Manager'),
      ('storefront_lead', 'Storefront Lead'),
      ('npo_coordinator', 'NPO Coordinator'),
      ('agency_contact', 'Agency Contact'),
      ('employee', 'Employee'),
    ]) {
      if (codes.contains(code)) return label;
    }
    return codes.isEmpty ? 'No role' : codes.first;
  }
}

/// The venue's layout and configuration, loaded once per session.
class VenueContext {
  const VenueContext({
    required this.venue,
    required this.levels,
    required this.storefronts,
    required this.stations,
    required this.jobRoles,
    required this.certificationTypes,
    required this.eventTypes,
    this.defaultNeeds = const [],
    this.agencies = const [],
    this.npoGroups = const [],
  });

  final Venue venue;
  final List<VenueLevel> levels;
  final List<Storefront> storefronts;
  final List<Station> stations;
  final List<JobRole> jobRoles;
  final List<CertificationType> certificationTypes;

  /// code -> display name.
  final Map<String, String> eventTypes;
  final List<StaffingNeed> defaultNeeds;
  final List<TempAgency> agencies;
  final List<NpoGroup> npoGroups;

  VenueRules get rules => VenueRules.fromJson(venue.settings);

  Storefront? storefront(String id) {
    for (final s in storefronts) {
      if (s.id == id) return s;
    }
    return null;
  }

  JobRole? jobRole(String code) {
    for (final r in jobRoles) {
      if (r.code == code) return r;
    }
    return null;
  }

  String roleName(String code) => jobRole(code)?.name ?? code;

  Station? station(String? id) {
    if (id == null) return null;
    for (final s in stations) {
      if (s.id == id) return s;
    }
    return null;
  }

  String certName(String code) {
    for (final c in certificationTypes) {
      if (c.code == code) return c.name;
    }
    return code;
  }

  String agencyName(String? id) => agencies.where((a) => a.id == id).firstOrNull?.name ?? '';
  String npoName(String? id) => npoGroups.where((g) => g.id == id).firstOrNull?.displayName ?? '';
}

/// A worker as the live board and schedule see them: age on the event date instead of a
/// birth date.
class BoardWorker {
  const BoardWorker({required this.worker, this.ageOnEvent});

  final Worker worker;
  final int? ageOnEvent;

  String get id => worker.id;

  bool isMinor(int adultAge) => ageOnEvent != null && ageOnEvent! < adultAge;

  factory BoardWorker.fromJson(Map<String, dynamic> j) => BoardWorker(
        worker: Worker.fromJson({
          ...j,
          'employee_number': j['employee_number'] ?? '',
          'worker_type': j['worker_type'] ?? 'regular',
        }),
        ageOnEvent: (j['age_on_event'] as num?)?.toInt(),
      );
}

/// Everything the schedule builder and live view need for one event, limited to the
/// signed-in person's scope.
class EventBoard {
  const EventBoard({
    required this.event,
    required this.timeZone,
    required this.weekStart,
    required this.storefrontIds,
    required this.openStorefrontIds,
    required this.needs,
    required this.shifts,
    required this.workers,
    required this.punches,
    required this.changes,
    required this.canManageAll,
  });

  final Event event;
  final String timeZone;
  final DateTime weekStart;

  /// Storefronts this person can see.
  final Set<String> storefrontIds;

  /// Of those, the ones open for this event.
  final Set<String> openStorefrontIds;
  final List<StaffingNeed> needs;
  final List<Shift> shifts;
  final Map<String, BoardWorker> workers;
  final List<Punch> punches;
  final List<AssignmentChange> changes;
  final bool canManageAll;

  List<Shift> shiftsAt(String storefrontId) => [for (final s in shifts) if (s.storefrontId == storefrontId) s];

  int needAt(String storefrontId) =>
      needs.where((n) => n.storefrontId == storefrontId).fold(0, (sum, n) => sum + n.count);

  /// Punches at this event for one worker, oldest first.
  List<Punch> eventPunches(String workerId) =>
      [for (final p in punches) if (p.workerId == workerId && p.eventId == event.id) p];

  /// Punches earlier in the same workweek, for overtime.
  List<Punch> priorWeekPunches(String workerId) =>
      [for (final p in punches) if (p.workerId == workerId && p.eventId != event.id) p];

  factory EventBoard.fromJson(Map<String, dynamic> j) {
    final storefronts = {for (final s in (j['storefront_ids'] as List? ?? const [])) s as String};
    return EventBoard(
      event: Event.fromJson((j['event'] as Map).cast<String, dynamic>()),
      timeZone: j['time_zone'] as String,
      weekStart: DateTime.parse(j['week_start'] as String).toUtc(),
      storefrontIds: storefronts,
      openStorefrontIds: {
        for (final e in (j['event_storefronts'] as List? ?? const []))
          if ((e as Map)['is_open'] == true) e['storefront_id'] as String,
      },
      needs: [for (final n in (j['needs'] as List? ?? const [])) StaffingNeed.fromJson((n as Map).cast())],
      shifts: [for (final s in (j['shifts'] as List? ?? const [])) Shift.fromJson((s as Map).cast())],
      workers: {
        for (final w in (j['workers'] as List? ?? const []))
          (w as Map)['id'] as String: BoardWorker.fromJson(w.cast()),
      },
      punches: [for (final p in (j['punches'] as List? ?? const [])) Punch.fromJson((p as Map).cast())],
      changes: [for (final c in (j['changes'] as List? ?? const [])) AssignmentChange.fromJson((c as Map).cast())],
      canManageAll: (j['can_manage_all'] as bool?) ?? false,
    );
  }
}

/// A position held by the signed-in person, with names resolved for display.
class MyShift {
  const MyShift({required this.shift, required this.event, required this.storefront, this.stationName = '', this.roleName = ''});

  final Shift shift;
  final Event event;
  final Storefront? storefront;
  final String stationName;
  final String roleName;
}

/// The employee clock screen's data.
class MyDay {
  const MyDay({required this.worker, required this.shifts, required this.punches});

  final Worker? worker;

  /// Upcoming and current positions, soonest first.
  final List<MyShift> shifts;

  /// This person's punches for the current or next event.
  final List<Punch> punches;

  MyShift? get current => shifts.isEmpty ? null : shifts.first;
}

/// What a kiosk learns from a PIN before recording a punch.
class KioskIdentity {
  const KioskIdentity({required this.workerId, required this.name, this.shiftId, this.eventId, this.storefrontLabel = '', this.callTime, this.punches = const []});

  final String workerId;
  final String name;
  final String? shiftId;
  final String? eventId;
  final String storefrontLabel;
  final DateTime? callTime;
  final List<Punch> punches;
}

/// A punch being recorded, before the server has it.
class PunchDraft {
  const PunchDraft({
    required this.id,
    required this.kind,
    required this.occurredAt,
    this.eventId,
    this.shiftId,
    this.breakKind,
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.withinGeofence,
  });

  final String id;
  final PunchKind kind;
  final DateTime occurredAt;
  final String? eventId;
  final String? shiftId;
  final BreakKind? breakKind;
  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;
  final bool? withinGeofence;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.code,
        'occurred_at': occurredAt.toUtc().toIso8601String(),
        'event_id': eventId,
        'shift_id': shiftId,
        'break_kind': breakKind?.code,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy_m': accuracyMeters,
        'within_geofence': withinGeofence,
      };

  factory PunchDraft.fromJson(Map<String, dynamic> j) => PunchDraft(
        id: j['id'] as String,
        kind: PunchKind.fromCode(j['kind'] as String?),
        occurredAt: DateTime.parse(j['occurred_at'] as String).toUtc(),
        eventId: j['event_id'] as String?,
        shiftId: j['shift_id'] as String?,
        breakKind: j['break_kind'] == null ? null : BreakKind.fromCode(j['break_kind'] as String?),
        latitude: (j['latitude'] as num?)?.toDouble(),
        longitude: (j['longitude'] as num?)?.toDouble(),
        accuracyMeters: (j['accuracy_m'] as num?)?.toDouble(),
        withinGeofence: j['within_geofence'] as bool?,
      );
}

/// An error the person can act on, with a plain message.
class AppFailure implements Exception {
  const AppFailure(this.message, {this.offline = false});

  final String message;

  /// True when the server could not be reached; the change was kept on the device.
  final bool offline;

  @override
  String toString() => message;
}
