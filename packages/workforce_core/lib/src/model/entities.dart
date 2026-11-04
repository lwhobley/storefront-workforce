/// Plain data records shared by the app, the rules engine, and the sample data.
/// Field names in JSON match the database columns.
library;

import 'enums.dart';

DateTime? _instant(Object? v) => v == null ? null : DateTime.parse(v as String).toUtc();
DateTime _instantReq(Object? v) => DateTime.parse(v as String).toUtc();
String? _iso(DateTime? d) => d?.toUtc().toIso8601String();

/// A calendar date with no time of day (birth dates, expirations).
DateTime? _date(Object? v) {
  if (v == null) return null;
  final d = DateTime.parse(v as String);
  return DateTime.utc(d.year, d.month, d.day);
}

String? _dateStr(DateTime? d) => d == null
    ? null
    : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

List<String> _strings(Object? v) => v == null ? const [] : (v as List).map((e) => e as String).toList();

class Venue {
  const Venue({
    required this.id,
    required this.organizationId,
    required this.name,
    required this.timeZone,
    this.settings = const {},
    this.branding = const {},
  });

  final String id;
  final String organizationId;
  final String name;

  /// IANA zone, for example America/Chicago.
  final String timeZone;

  /// Venue rules as stored. Read through `VenueRules.fromJson`.
  final Map<String, dynamic> settings;
  final Map<String, dynamic> branding;

  factory Venue.fromJson(Map<String, dynamic> j) => Venue(
        id: j['id'] as String,
        organizationId: j['organization_id'] as String,
        name: j['name'] as String,
        timeZone: j['time_zone'] as String,
        settings: (j['settings'] as Map?)?.cast<String, dynamic>() ?? const {},
        branding: (j['branding'] as Map?)?.cast<String, dynamic>() ?? const {},
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'organization_id': organizationId,
        'name': name,
        'time_zone': timeZone,
        'settings': settings,
        'branding': branding,
      };
}

class VenueLevel {
  const VenueLevel({required this.id, required this.venueId, required this.name, required this.sort});

  final String id;
  final String venueId;
  final String name;
  final int sort;

  factory VenueLevel.fromJson(Map<String, dynamic> j) => VenueLevel(
        id: j['id'] as String,
        venueId: j['venue_id'] as String,
        name: j['name'] as String,
        sort: (j['sort'] as num).toInt(),
      );

  Map<String, dynamic> toJson() => {'id': id, 'venue_id': venueId, 'name': name, 'sort': sort};
}

class Storefront {
  const Storefront({
    required this.id,
    required this.venueId,
    required this.levelId,
    required this.code,
    required this.name,
    required this.kind,
    required this.section,
    required this.mapX,
    required this.mapY,
    this.active = true,
  });

  final String id;
  final String venueId;
  final String levelId;

  /// Short label staff use, for example "214".
  final String code;
  final String name;
  final StorefrontKind kind;
  final String section;

  /// Position on the level map, 0 to 1 from the left and top edges.
  final double mapX;
  final double mapY;
  final bool active;

  factory Storefront.fromJson(Map<String, dynamic> j) => Storefront(
        id: j['id'] as String,
        venueId: j['venue_id'] as String,
        levelId: j['level_id'] as String,
        code: j['code'] as String,
        name: j['name'] as String,
        kind: StorefrontKind.fromCode(j['kind'] as String?),
        section: (j['section'] as String?) ?? '',
        mapX: (j['map_x'] as num?)?.toDouble() ?? 0.5,
        mapY: (j['map_y'] as num?)?.toDouble() ?? 0.5,
        active: (j['active'] as bool?) ?? true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'venue_id': venueId,
        'level_id': levelId,
        'code': code,
        'name': name,
        'kind': kind.code,
        'section': section,
        'map_x': mapX,
        'map_y': mapY,
        'active': active,
      };
}

class Station {
  const Station({
    required this.id,
    required this.venueId,
    required this.storefrontId,
    required this.name,
    this.jobRoleCode,
  });

  final String id;
  final String venueId;
  final String storefrontId;
  final String name;
  final String? jobRoleCode;

  factory Station.fromJson(Map<String, dynamic> j) => Station(
        id: j['id'] as String,
        venueId: j['venue_id'] as String,
        storefrontId: j['storefront_id'] as String,
        name: j['name'] as String,
        jobRoleCode: j['job_role_code'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'venue_id': venueId,
        'storefront_id': storefrontId,
        'name': name,
        'job_role_code': jobRoleCode,
      };
}

/// A position a person works: cashier, cook, runner, bartender, lead.
class JobRole {
  const JobRole({
    required this.venueId,
    required this.code,
    required this.name,
    this.requiredCertifications = const [],
    this.minimumAge,
    this.tipped = false,
    this.sort = 0,
  });

  final String venueId;
  final String code;
  final String name;

  /// Certification type codes needed to work this role.
  final List<String> requiredCertifications;
  final int? minimumAge;
  final bool tipped;
  final int sort;

  factory JobRole.fromJson(Map<String, dynamic> j) => JobRole(
        venueId: j['venue_id'] as String,
        code: j['code'] as String,
        name: j['name'] as String,
        requiredCertifications: _strings(j['required_certifications']),
        minimumAge: (j['minimum_age'] as num?)?.toInt(),
        tipped: (j['tipped'] as bool?) ?? false,
        sort: (j['sort'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'venue_id': venueId,
        'code': code,
        'name': name,
        'required_certifications': requiredCertifications,
        'minimum_age': minimumAge,
        'tipped': tipped,
        'sort': sort,
      };
}

class CertificationType {
  const CertificationType({required this.venueId, required this.code, required this.name, this.validityMonths});

  final String venueId;
  final String code;
  final String name;
  final int? validityMonths;

  factory CertificationType.fromJson(Map<String, dynamic> j) => CertificationType(
        venueId: j['venue_id'] as String,
        code: j['code'] as String,
        name: j['name'] as String,
        validityMonths: (j['validity_months'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() =>
      {'venue_id': venueId, 'code': code, 'name': name, 'validity_months': validityMonths};
}

class WorkerCertification {
  const WorkerCertification({
    required this.id,
    required this.workerId,
    required this.typeCode,
    this.number = '',
    this.issuedOn,
    this.expiresOn,
  });

  final String id;
  final String workerId;
  final String typeCode;
  final String number;
  final DateTime? issuedOn;

  /// Last valid day. Null means it does not expire.
  final DateTime? expiresOn;

  factory WorkerCertification.fromJson(Map<String, dynamic> j) => WorkerCertification(
        id: j['id'] as String,
        workerId: j['worker_id'] as String,
        typeCode: j['cert_type_code'] as String,
        number: (j['number'] as String?) ?? '',
        issuedOn: _date(j['issued_on']),
        expiresOn: _date(j['expires_on']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'worker_id': workerId,
        'cert_type_code': typeCode,
        'number': number,
        'issued_on': _dateStr(issuedOn),
        'expires_on': _dateStr(expiresOn),
      };
}

class TempAgency {
  const TempAgency({required this.id, required this.venueId, required this.name, this.contactName = ''});

  final String id;
  final String venueId;
  final String name;
  final String contactName;

  factory TempAgency.fromJson(Map<String, dynamic> j) => TempAgency(
        id: j['id'] as String,
        venueId: j['venue_id'] as String,
        name: j['name'] as String,
        contactName: (j['contact_name'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {'id': id, 'venue_id': venueId, 'name': name, 'contact_name': contactName};
}

class NpoGroup {
  const NpoGroup({
    required this.id,
    required this.venueId,
    required this.legalName,
    required this.displayName,
    this.coordinatorName = '',
    this.w9OnFile = false,
  });

  final String id;
  final String venueId;
  final String legalName;
  final String displayName;
  final String coordinatorName;
  final bool w9OnFile;

  factory NpoGroup.fromJson(Map<String, dynamic> j) => NpoGroup(
        id: j['id'] as String,
        venueId: j['venue_id'] as String,
        legalName: j['legal_name'] as String,
        displayName: j['display_name'] as String,
        coordinatorName: (j['coordinator_name'] as String?) ?? '',
        w9OnFile: (j['w9_on_file'] as bool?) ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'venue_id': venueId,
        'legal_name': legalName,
        'display_name': displayName,
        'coordinator_name': coordinatorName,
        'w9_on_file': w9OnFile,
      };
}

class Worker {
  const Worker({
    required this.id,
    required this.venueId,
    required this.type,
    required this.employeeNumber,
    required this.firstName,
    required this.lastName,
    this.preferredName = '',
    this.dateOfBirth,
    this.phone = '',
    this.email = '',
    this.photoPath,
    this.uniformSize = '',
    this.emergencyContactName = '',
    this.emergencyContactPhone = '',
    this.preferredLanguage = 'en',
    this.agencyId,
    this.npoGroupId,
    this.paycomEmployeeCode = '',
    this.hireDate,
    this.status = 'active',
    this.userId,
    this.jobRoles = const [],
    this.certifications = const [],
  });

  final String id;
  final String venueId;
  final WorkerType type;
  final String employeeNumber;
  final String firstName;
  final String lastName;
  final String preferredName;
  final DateTime? dateOfBirth;
  final String phone;
  final String email;
  final String? photoPath;
  final String uniformSize;
  final String emergencyContactName;
  final String emergencyContactPhone;

  /// 'en' or 'es'.
  final String preferredLanguage;
  final String? agencyId;
  final String? npoGroupId;
  final String paycomEmployeeCode;
  final DateTime? hireDate;
  final String status;
  final String? userId;

  /// Job role codes this person is trained for.
  final List<String> jobRoles;
  final List<WorkerCertification> certifications;

  String get displayName => '${preferredName.isNotEmpty ? preferredName : firstName} $lastName';

  /// Age in whole years on [day] (a calendar date). Null when no birth date is on file.
  int? ageOn(DateTime day) {
    final dob = dateOfBirth;
    if (dob == null) return null;
    var age = day.year - dob.year;
    if (day.month < dob.month || (day.month == dob.month && day.day < dob.day)) age--;
    return age;
  }

  Worker copyWith({List<String>? jobRoles, List<WorkerCertification>? certifications, String? status}) => Worker(
        id: id,
        venueId: venueId,
        type: type,
        employeeNumber: employeeNumber,
        firstName: firstName,
        lastName: lastName,
        preferredName: preferredName,
        dateOfBirth: dateOfBirth,
        phone: phone,
        email: email,
        photoPath: photoPath,
        uniformSize: uniformSize,
        emergencyContactName: emergencyContactName,
        emergencyContactPhone: emergencyContactPhone,
        preferredLanguage: preferredLanguage,
        agencyId: agencyId,
        npoGroupId: npoGroupId,
        paycomEmployeeCode: paycomEmployeeCode,
        hireDate: hireDate,
        status: status ?? this.status,
        userId: userId,
        jobRoles: jobRoles ?? this.jobRoles,
        certifications: certifications ?? this.certifications,
      );

  factory Worker.fromJson(Map<String, dynamic> j) => Worker(
        id: j['id'] as String,
        venueId: j['venue_id'] as String,
        type: WorkerType.fromCode(j['worker_type'] as String?),
        employeeNumber: j['employee_number'] as String,
        firstName: j['first_name'] as String,
        lastName: j['last_name'] as String,
        preferredName: (j['preferred_name'] as String?) ?? '',
        dateOfBirth: _date(j['date_of_birth']),
        phone: (j['phone'] as String?) ?? '',
        email: (j['email'] as String?) ?? '',
        photoPath: j['photo_path'] as String?,
        uniformSize: (j['uniform_size'] as String?) ?? '',
        emergencyContactName: (j['emergency_contact_name'] as String?) ?? '',
        emergencyContactPhone: (j['emergency_contact_phone'] as String?) ?? '',
        preferredLanguage: (j['preferred_language'] as String?) ?? 'en',
        agencyId: j['agency_id'] as String?,
        npoGroupId: j['npo_group_id'] as String?,
        paycomEmployeeCode: (j['paycom_employee_code'] as String?) ?? '',
        hireDate: _date(j['hire_date']),
        status: (j['status'] as String?) ?? 'active',
        userId: j['user_id'] as String?,
        jobRoles: _strings(j['job_roles']),
        certifications: [
          for (final c in (j['certifications'] as List?) ?? const [])
            WorkerCertification.fromJson((c as Map).cast<String, dynamic>()),
        ],
      );

  /// Columns of the workers table (job roles and certifications live in their own tables).
  Map<String, dynamic> toRow() => {
        'id': id,
        'venue_id': venueId,
        'worker_type': type.code,
        'employee_number': employeeNumber,
        'first_name': firstName,
        'last_name': lastName,
        'preferred_name': preferredName,
        'date_of_birth': _dateStr(dateOfBirth),
        'phone': phone,
        'email': email,
        'photo_path': photoPath,
        'uniform_size': uniformSize,
        'emergency_contact_name': emergencyContactName,
        'emergency_contact_phone': emergencyContactPhone,
        'preferred_language': preferredLanguage,
        'agency_id': agencyId,
        'npo_group_id': npoGroupId,
        'paycom_employee_code': paycomEmployeeCode,
        'hire_date': _dateStr(hireDate),
        'status': status,
      };

  Map<String, dynamic> toJson() => {
        ...toRow(),
        'user_id': userId,
        'job_roles': jobRoles,
        'certifications': [for (final c in certifications) c.toJson()],
      };
}

class Event {
  const Event({
    required this.id,
    required this.venueId,
    required this.name,
    required this.eventTypeCode,
    required this.startTime,
    required this.callTime,
    required this.doorsTime,
    this.endTime,
    this.expectedAttendance = 0,
    this.actualAttendance,
    this.status = EventStatus.scheduled,
    this.source = 'manual',
    this.externalId,
    this.notes = '',
  });

  final String id;
  final String venueId;
  final String name;
  final String eventTypeCode;

  /// Game time, show time, or curtain.
  final DateTime startTime;

  /// Default staff call time for the event. Each shift can carry its own.
  final DateTime callTime;
  final DateTime doorsTime;
  final DateTime? endTime;
  final int expectedAttendance;
  final int? actualAttendance;
  final EventStatus status;

  /// Where the event came from: manual, premium_command, or csv.
  final String source;
  final String? externalId;
  final String notes;

  Event copyWith({EventStatus? status, int? actualAttendance, int? expectedAttendance}) => Event(
        id: id,
        venueId: venueId,
        name: name,
        eventTypeCode: eventTypeCode,
        startTime: startTime,
        callTime: callTime,
        doorsTime: doorsTime,
        endTime: endTime,
        expectedAttendance: expectedAttendance ?? this.expectedAttendance,
        actualAttendance: actualAttendance ?? this.actualAttendance,
        status: status ?? this.status,
        source: source,
        externalId: externalId,
        notes: notes,
      );

  factory Event.fromJson(Map<String, dynamic> j) => Event(
        id: j['id'] as String,
        venueId: j['venue_id'] as String,
        name: j['name'] as String,
        eventTypeCode: j['event_type_code'] as String,
        startTime: _instantReq(j['start_time']),
        callTime: _instantReq(j['call_time']),
        doorsTime: _instantReq(j['doors_time']),
        endTime: _instant(j['end_time']),
        expectedAttendance: (j['expected_attendance'] as num?)?.toInt() ?? 0,
        actualAttendance: (j['actual_attendance'] as num?)?.toInt(),
        status: EventStatus.fromCode(j['status'] as String?),
        source: (j['source'] as String?) ?? 'manual',
        externalId: j['external_id'] as String?,
        notes: (j['notes'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'venue_id': venueId,
        'name': name,
        'event_type_code': eventTypeCode,
        'start_time': _iso(startTime),
        'call_time': _iso(callTime),
        'doors_time': _iso(doorsTime),
        'end_time': _iso(endTime),
        'expected_attendance': expectedAttendance,
        'actual_attendance': actualAttendance,
        'status': status.code,
        'source': source,
        'external_id': externalId,
        'notes': notes,
      };
}

/// A storefront that is open for one event.
class EventStorefront {
  const EventStorefront({required this.eventId, required this.storefrontId, this.isOpen = true});

  final String eventId;
  final String storefrontId;
  final bool isOpen;

  factory EventStorefront.fromJson(Map<String, dynamic> j) => EventStorefront(
        eventId: j['event_id'] as String,
        storefrontId: j['storefront_id'] as String,
        isOpen: (j['is_open'] as bool?) ?? true,
      );

  Map<String, dynamic> toJson() => {'event_id': eventId, 'storefront_id': storefrontId, 'is_open': isOpen};
}

/// How many people of a role a storefront needs. With [eventId] null it is the storefront's default.
class StaffingNeed {
  const StaffingNeed({required this.storefrontId, required this.jobRoleCode, required this.count, this.eventId});

  final String? eventId;
  final String storefrontId;
  final String jobRoleCode;
  final int count;

  factory StaffingNeed.fromJson(Map<String, dynamic> j) => StaffingNeed(
        eventId: j['event_id'] as String?,
        storefrontId: j['storefront_id'] as String,
        jobRoleCode: j['job_role_code'] as String,
        count: (j['count'] as num).toInt(),
      );

  Map<String, dynamic> toJson() => {
        if (eventId != null) 'event_id': eventId,
        'storefront_id': storefrontId,
        'job_role_code': jobRoleCode,
        'count': count,
      };
}

/// One position at one storefront for one event. With no worker it is an open position.
class Shift {
  const Shift({
    required this.id,
    required this.venueId,
    required this.eventId,
    required this.storefrontId,
    required this.jobRoleCode,
    required this.callTime,
    this.stationId,
    this.workerId,
    this.scheduledEnd,
    this.status = ShiftStatus.open,
    this.releasedAt,
    this.releaseOrder,
    this.releaseReason = '',
    this.version = 1,
  });

  final String id;
  final String venueId;
  final String eventId;
  final String storefrontId;
  final String? stationId;
  final String jobRoleCode;
  final String? workerId;
  final DateTime callTime;
  final DateTime? scheduledEnd;
  final ShiftStatus status;
  final DateTime? releasedAt;

  /// 1 for the first person sent home at this event, 2 for the next, and so on.
  final int? releaseOrder;
  final String releaseReason;
  final int version;

  bool get isOpen => workerId == null && status == ShiftStatus.open;

  Shift copyWith({
    String? storefrontId,
    String? stationId,
    bool clearStation = false,
    String? jobRoleCode,
    String? workerId,
    bool clearWorker = false,
    DateTime? callTime,
    ShiftStatus? status,
    DateTime? releasedAt,
    int? releaseOrder,
    String? releaseReason,
  }) =>
      Shift(
        id: id,
        venueId: venueId,
        eventId: eventId,
        storefrontId: storefrontId ?? this.storefrontId,
        stationId: clearStation ? null : (stationId ?? this.stationId),
        jobRoleCode: jobRoleCode ?? this.jobRoleCode,
        workerId: clearWorker ? null : (workerId ?? this.workerId),
        callTime: callTime ?? this.callTime,
        scheduledEnd: scheduledEnd,
        status: status ?? this.status,
        releasedAt: releasedAt ?? this.releasedAt,
        releaseOrder: releaseOrder ?? this.releaseOrder,
        releaseReason: releaseReason ?? this.releaseReason,
        version: version + 1,
      );

  factory Shift.fromJson(Map<String, dynamic> j) => Shift(
        id: j['id'] as String,
        venueId: j['venue_id'] as String,
        eventId: j['event_id'] as String,
        storefrontId: j['storefront_id'] as String,
        stationId: j['station_id'] as String?,
        jobRoleCode: j['job_role_code'] as String,
        workerId: j['worker_id'] as String?,
        callTime: _instantReq(j['call_time']),
        scheduledEnd: _instant(j['scheduled_end']),
        status: ShiftStatus.fromCode(j['status'] as String?),
        releasedAt: _instant(j['released_at']),
        releaseOrder: (j['release_order'] as num?)?.toInt(),
        releaseReason: (j['release_reason'] as String?) ?? '',
        version: (j['version'] as num?)?.toInt() ?? 1,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'venue_id': venueId,
        'event_id': eventId,
        'storefront_id': storefrontId,
        'station_id': stationId,
        'job_role_code': jobRoleCode,
        'worker_id': workerId,
        'call_time': _iso(callTime),
        'scheduled_end': _iso(scheduledEnd),
        'status': status.code,
        'released_at': _iso(releasedAt),
        'release_order': releaseOrder,
        'release_reason': releaseReason,
        'version': version,
      };
}

/// One clock action. [id] is created on the device, so a punch sent twice is stored once.
class Punch {
  const Punch({
    required this.id,
    required this.venueId,
    required this.workerId,
    required this.kind,
    required this.occurredAt,
    this.eventId,
    this.shiftId,
    this.breakKind,
    this.receivedAt,
    this.source = PunchSource.phone,
    this.deviceId = '',
    this.latitude,
    this.longitude,
    this.accuracyMeters,
    this.withinGeofence,
    this.photoPath,
    this.status = PunchStatus.accepted,
  });

  final String id;
  final String venueId;
  final String workerId;
  final String? eventId;
  final String? shiftId;
  final PunchKind kind;
  final BreakKind? breakKind;

  /// When it happened, by the device clock.
  final DateTime occurredAt;

  /// When the server stored it. A large gap after [occurredAt] means it was made offline.
  final DateTime? receivedAt;
  final PunchSource source;
  final String deviceId;
  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;
  final bool? withinGeofence;
  final String? photoPath;
  final PunchStatus status;

  factory Punch.fromJson(Map<String, dynamic> j) => Punch(
        id: j['id'] as String,
        venueId: j['venue_id'] as String,
        workerId: j['worker_id'] as String,
        eventId: j['event_id'] as String?,
        shiftId: j['shift_id'] as String?,
        kind: PunchKind.fromCode(j['kind'] as String?),
        breakKind: j['break_kind'] == null ? null : BreakKind.fromCode(j['break_kind'] as String?),
        occurredAt: _instantReq(j['occurred_at']),
        receivedAt: _instant(j['received_at']),
        source: PunchSource.fromCode(j['source'] as String?),
        deviceId: (j['device_id'] as String?) ?? '',
        latitude: (j['latitude'] as num?)?.toDouble(),
        longitude: (j['longitude'] as num?)?.toDouble(),
        accuracyMeters: (j['accuracy_m'] as num?)?.toDouble(),
        withinGeofence: j['within_geofence'] as bool?,
        photoPath: j['photo_path'] as String?,
        status: PunchStatus.fromCode(j['status'] as String?),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'venue_id': venueId,
        'worker_id': workerId,
        'event_id': eventId,
        'shift_id': shiftId,
        'kind': kind.code,
        'break_kind': breakKind?.code,
        'occurred_at': _iso(occurredAt),
        'received_at': _iso(receivedAt),
        'source': source.code,
        'device_id': deviceId,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy_m': accuracyMeters,
        'within_geofence': withinGeofence,
        'photo_path': photoPath,
        'status': status.code,
      };
}

/// One logged move of a person during an event.
class AssignmentChange {
  const AssignmentChange({
    required this.id,
    required this.eventId,
    required this.shiftId,
    required this.action,
    required this.changedAt,
    this.workerId,
    this.fromStorefrontId,
    this.toStorefrontId,
    this.fromJobRoleCode,
    this.toJobRoleCode,
    this.reason = '',
    this.changedByName = '',
  });

  final String id;
  final String eventId;
  final String shiftId;

  /// assigned, unassigned, moved, released.
  final String action;
  final DateTime changedAt;
  final String? workerId;
  final String? fromStorefrontId;
  final String? toStorefrontId;
  final String? fromJobRoleCode;
  final String? toJobRoleCode;
  final String reason;
  final String changedByName;

  factory AssignmentChange.fromJson(Map<String, dynamic> j) => AssignmentChange(
        id: j['id'].toString(),
        eventId: j['event_id'] as String,
        shiftId: j['shift_id'] as String,
        action: j['action'] as String,
        changedAt: _instantReq(j['changed_at']),
        workerId: j['worker_id'] as String?,
        fromStorefrontId: j['from_storefront_id'] as String?,
        toStorefrontId: j['to_storefront_id'] as String?,
        fromJobRoleCode: j['from_job_role_code'] as String?,
        toJobRoleCode: j['to_job_role_code'] as String?,
        reason: (j['reason'] as String?) ?? '',
        changedByName: (j['changed_by_name'] as String?) ?? '',
      );
}
