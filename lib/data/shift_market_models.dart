import 'package:workforce_core/workforce_core.dart';

import 'models.dart';

/// The venue's self-service rules (venues.settings -> self_service).
class SelfServiceSettings {
  const SelfServiceSettings({
    this.allowPickups = true,
    this.allowDrops = true,
    this.allowSwaps = true,
    this.dropCutoffHours = 24,
    this.pickupsNeedApproval = true,
  });

  final bool allowPickups;
  final bool allowDrops;
  final bool allowSwaps;

  /// No drop requests closer than this to call time.
  final num dropCutoffHours;

  /// False: an eligible pickup is assigned right away.
  final bool pickupsNeedApproval;

  factory SelfServiceSettings.fromVenueSettings(Map<String, dynamic> settings) {
    final j = (settings['self_service'] as Map?)?.cast<String, dynamic>() ?? const {};
    return SelfServiceSettings(
      allowPickups: (j['allow_pickups'] as bool?) ?? true,
      allowDrops: (j['allow_drops'] as bool?) ?? true,
      allowSwaps: (j['allow_swaps'] as bool?) ?? true,
      dropCutoffHours: (j['drop_cutoff_hours'] as num?) ?? 24,
      pickupsNeedApproval: (j['pickups_need_approval'] as bool?) ?? true,
    );
  }

  /// When drop requests for a shift with this call time close.
  DateTime dropDeadline(DateTime callTime) => callTime.subtract(Duration(minutes: (dropCutoffHours * 60).round()));
}

enum ShiftRequestKind {
  pickup('pickup'),
  drop('drop'),
  swap('swap');

  const ShiftRequestKind(this.code);
  final String code;

  static ShiftRequestKind fromCode(String? code) => values.firstWhere((v) => v.code == code, orElse: () => pickup);
}

enum ShiftRequestStatus {
  /// Waiting for a manager.
  pending('pending'),

  /// A swap waiting for the coworker to accept.
  offered('offered'),
  approved('approved'),
  denied('denied'),
  cancelled('cancelled'),
  expired('expired');

  const ShiftRequestStatus(this.code);
  final String code;

  bool get isOpen => this == pending || this == offered;

  static ShiftRequestStatus fromCode(String? code) => values.firstWhere((v) => v.code == code, orElse: () => pending);
}

enum AvailabilityStatus {
  available('available'),
  unavailable('unavailable');

  const AvailabilityStatus(this.code);
  final String code;

  static AvailabilityStatus? fromCode(String? code) {
    for (final v in values) {
      if (v.code == code) return v;
    }
    return null;
  }
}

DateTime? _time(Object? v) => v == null ? null : DateTime.parse(v as String).toUtc();

DateTime _date(Object? v) {
  final d = DateTime.parse(v as String);
  return DateTime.utc(d.year, d.month, d.day);
}

/// An open position the signed-in person could pick up.
class OpenShift {
  const OpenShift({
    required this.shift,
    required this.event,
    required this.storefrontName,
    required this.roleName,
    this.storefrontCode = '',
    this.section = '',
    this.blocked,
    this.myRequestId,
    this.availability,
  });

  final Shift shift;
  final Event event;
  final String storefrontName;
  final String storefrontCode;
  final String section;
  final String roleName;

  /// Why this person cannot take it (age, certification...), or null.
  final String? blocked;

  /// Their pending pickup request for it, if any.
  final String? myRequestId;
  final AvailabilityStatus? availability;

  factory OpenShift.fromJson(Map<String, dynamic> j) => OpenShift(
        shift: Shift.fromJson((j['shift'] as Map).cast()),
        event: Event.fromJson((j['event'] as Map).cast()),
        storefrontName: (j['storefront_name'] as String?) ?? '',
        storefrontCode: (j['storefront_code'] as String?) ?? '',
        section: (j['section'] as String?) ?? '',
        roleName: (j['role_name'] as String?) ?? '',
        blocked: j['blocked'] as String?,
        myRequestId: j['my_request_id'] as String?,
        availability: AvailabilityStatus.fromCode(j['availability'] as String?),
      );
}

/// A pickup, drop, or swap request, with names resolved for display. [requester] and
/// [target] (rules-engine fields: age on the event date, roles, certifications) are
/// filled only in the manager's queue.
class ShiftRequest {
  const ShiftRequest({
    required this.id,
    required this.kind,
    required this.status,
    required this.shift,
    required this.event,
    required this.storefrontName,
    required this.roleName,
    required this.requesterWorkerId,
    required this.requesterName,
    required this.createdAt,
    this.targetWorkerId,
    this.targetName = '',
    this.note = '',
    this.warnings = const [],
    this.decidedAt,
    this.decisionNote = '',
    this.decidedByName = '',
    this.shiftWorkerName = '',
    this.requester,
    this.target,
  });

  final String id;
  final ShiftRequestKind kind;
  final ShiftRequestStatus status;
  final Shift shift;
  final Event event;
  final String storefrontName;
  final String roleName;
  final String requesterWorkerId;
  final String requesterName;
  final String? targetWorkerId;
  final String targetName;
  final String note;
  final List<String> warnings;
  final DateTime createdAt;
  final DateTime? decidedAt;
  final String decisionNote;
  final String decidedByName;

  /// Who holds the position now (manager view).
  final String shiftWorkerName;
  final BoardWorker? requester;
  final BoardWorker? target;

  /// The person who would hold the position if approved (pickup: requester; swap: target).
  BoardWorker? get incoming => switch (kind) {
        ShiftRequestKind.pickup => requester,
        ShiftRequestKind.swap => target,
        ShiftRequestKind.drop => null,
      };

  factory ShiftRequest.fromJson(Map<String, dynamic> j) => ShiftRequest(
        id: j['id'] as String,
        kind: ShiftRequestKind.fromCode(j['kind'] as String?),
        status: ShiftRequestStatus.fromCode(j['status'] as String?),
        shift: Shift.fromJson((j['shift'] as Map).cast()),
        event: Event.fromJson((j['event'] as Map).cast()),
        storefrontName: (j['storefront_name'] as String?) ?? '',
        roleName: (j['role_name'] as String?) ?? '',
        requesterWorkerId: j['requester_worker_id'] as String,
        requesterName: (j['requester_name'] as String?) ?? '',
        targetWorkerId: j['target_worker_id'] as String?,
        targetName: (j['target_name'] as String?) ?? '',
        note: (j['note'] as String?) ?? '',
        warnings: [for (final w in (j['warnings'] as List?) ?? const []) w as String],
        createdAt: _time(j['created_at'])!,
        decidedAt: _time(j['decided_at']),
        decisionNote: (j['decision_note'] as String?) ?? '',
        decidedByName: (j['decided_by_name'] as String?) ?? '',
        shiftWorkerName: (j['shift_worker_name'] as String?) ?? '',
        requester: j['requester'] == null ? null : BoardWorker.fromJson((j['requester'] as Map).cast()),
        target: j['target'] == null ? null : BoardWorker.fromJson((j['target'] as Map).cast()),
      );
}

/// A coworker who could take one of your shifts. Name only.
class SwapCandidate {
  const SwapCandidate({required this.id, required this.name, this.availability});

  final String id;
  final String name;
  final AvailabilityStatus? availability;

  factory SwapCandidate.fromJson(Map<String, dynamic> j) => SwapCandidate(
        id: j['id'] as String,
        name: j['name'] as String,
        availability: AvailabilityStatus.fromCode(j['availability'] as String?),
      );
}

/// Dates someone cannot work, inclusive (venue-local dates as UTC midnights).
class Blackout {
  const Blackout({required this.id, required this.startsOn, required this.endsOn, this.note = ''});

  final String id;
  final DateTime startsOn;
  final DateTime endsOn;
  final String note;

  bool covers(DateTime day) => !day.isBefore(startsOn) && !day.isAfter(endsOn);

  factory Blackout.fromJson(Map<String, dynamic> j) => Blackout(
        id: j['id'] as String,
        startsOn: _date(j['starts_on']),
        endsOn: _date(j['ends_on']),
        note: (j['note'] as String?) ?? '',
      );
}

/// One upcoming event with the signed-in person's answer.
class EventAvailability {
  const EventAvailability({required this.event, this.status, this.note = '', this.scheduled = false});

  final Event event;
  final AvailabilityStatus? status;
  final String note;

  /// They already hold a position at this event.
  final bool scheduled;

  factory EventAvailability.fromJson(Map<String, dynamic> j) => EventAvailability(
        event: Event.fromJson((j['event'] as Map).cast()),
        status: AvailabilityStatus.fromCode(j['status'] as String?),
        note: (j['note'] as String?) ?? '',
        scheduled: (j['scheduled'] as bool?) ?? false,
      );
}

class MyAvailability {
  const MyAvailability({required this.events, required this.blackouts});

  final List<EventAvailability> events;
  final List<Blackout> blackouts;

  factory MyAvailability.fromJson(Map<String, dynamic> j) => MyAvailability(
        events: [for (final e in (j['events'] as List?) ?? const []) EventAvailability.fromJson((e as Map).cast())],
        blackouts: [for (final b in (j['blackouts'] as List?) ?? const []) Blackout.fromJson((b as Map).cast())],
      );
}

/// What a candidate said about an event, for the assign sheet.
class CandidateAvailability {
  const CandidateAvailability({this.status, this.note = '', this.blackout = false});

  final AvailabilityStatus? status;
  final String note;

  /// The event date falls in one of their blackouts.
  final bool blackout;

  /// Sort order: said available, no answer, said unavailable, blackout.
  int get rank => blackout
      ? 3
      : switch (status) {
          AvailabilityStatus.available => 0,
          null => 1,
          AvailabilityStatus.unavailable => 2,
        };
}

class MarketCandidate {
  const MarketCandidate({required this.worker, this.availability = const CandidateAvailability()});

  final BoardWorker worker;
  final CandidateAvailability availability;

  factory MarketCandidate.fromJson(Map<String, dynamic> j) => MarketCandidate(
        worker: BoardWorker.fromJson(j),
        availability: CandidateAvailability(
          status: AvailabilityStatus.fromCode(j['availability'] as String?),
          note: (j['availability_note'] as String?) ?? '',
          blackout: (j['blackout'] as bool?) ?? false,
        ),
      );
}
