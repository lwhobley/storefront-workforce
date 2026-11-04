import 'dart:typed_data';

import 'package:workforce_core/workforce_core.dart';

import 'models.dart';

/// Phase 4: opening and closing checklists per storefront (photo proof, manager
/// sign-off, works offline) and incidents (injuries, safety, employee incidents, with
/// photos and follow-up). Server side: 0021_checklists_incidents.sql.
///
/// Changes made on the floor carry an id made on the device ([ChecklistItemChange.id],
/// [IncidentDraft.id], [IncidentNoteDraft.id]); sending one again stores it once, so the
/// offline queue can retry freely.
abstract interface class OperationsRepository {
  // ---- Checklists ----

  /// Templates, open storefronts in scope, and runs so far for one event.
  Future<EventChecklists> loadEventChecklists(AppSession session, String eventId);

  /// Ticks or unticks one item (starting the run if needed), uploading [photos] to the
  /// run's folder first. Safe to repeat with the same change id.
  Future<ChecklistRun> recordChecklistItem(AppSession session, ChecklistItemChange change, {List<Uint8List> photos = const []});

  /// A manager for the venue or the storefront's level signs off a finished run.
  Future<ChecklistRun> signOffChecklist(String runId, {String note = ''});
  Future<ChecklistRun> reopenChecklist(String runId, String reason);
  Future<Uint8List?> downloadChecklistPhoto(String path);

  /// The venue's checklist templates, for the editor.
  Future<List<ChecklistTemplate>> listChecklistTemplates(AppSession session);

  /// Creates the template when its id is empty. Items left out are turned off.
  Future<void> saveChecklistTemplate(AppSession session, ChecklistTemplate template);

  // ---- Incidents ----

  /// Incidents the person can see, newest first.
  Future<List<Incident>> listIncidents(AppSession session);

  /// Logs an incident, then uploads [photos] to its folder. Safe to repeat.
  Future<Incident> logIncident(AppSession session, IncidentDraft draft, {List<Uint8List> photos = const []});

  /// Adds photos taken later. [batchId] names the files, so a retry does not add them twice.
  Future<Incident> addIncidentPhotos(AppSession session, String incidentId, String batchId, List<Uint8List> photos);
  Future<Incident> addIncidentNote(AppSession session, IncidentNoteDraft note);

  /// Managers: status, follow-up owner, closing note (required to close).
  Future<Incident> updateIncident(String incidentId, {IncidentStatus? status, String? assignedTo, bool unassign = false, String? closingNote});

  /// Who can own the follow-up on an incident of this kind.
  Future<List<IncidentAssignee>> incidentAssignees(AppSession session, IncidentKind kind);
  Future<Uint8List?> downloadIncidentPhoto(String path);
}

DateTime? _time(Object? v) => v == null ? null : DateTime.parse(v as String).toUtc();
List<String> _strings(Object? v) => [for (final s in (v as List?) ?? const []) s as String];

// ---------------------------------------------------------------------------
// Checklists
// ---------------------------------------------------------------------------

enum ChecklistKind {
  opening('Opening'),
  closing('Closing'),
  custom('Other');

  const ChecklistKind(this.label);
  final String label;

  static ChecklistKind fromCode(String? c) => values.firstWhere((v) => v.name == c, orElse: () => custom);
}

class ChecklistTemplateItem {
  const ChecklistTemplateItem({this.id = '', required this.label, this.help = '', this.photoRequired = false, this.storefrontKinds = const [], this.sort = 0});

  final String id;
  final String label;
  final String help;
  final bool photoRequired;

  /// Storefront kind codes (bar, permanent_stand, portable_cart, kiosk); empty = all.
  final List<String> storefrontKinds;
  final int sort;

  bool appliesTo(StorefrontKind kind) => storefrontKinds.isEmpty || storefrontKinds.contains(kind.code);

  factory ChecklistTemplateItem.fromJson(Map<String, dynamic> j) => ChecklistTemplateItem(
        id: j['id'] as String,
        label: j['label'] as String,
        help: (j['help'] as String?) ?? '',
        photoRequired: (j['photo_required'] as bool?) ?? false,
        storefrontKinds: _strings(j['storefront_kinds']),
        sort: (j['sort'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        if (id.isNotEmpty) 'id': id,
        'label': label,
        'help': help,
        'photo_required': photoRequired,
        'storefront_kinds': storefrontKinds,
        'sort': sort,
      };

  ChecklistTemplateItem copyWith({String? label, String? help, bool? photoRequired, List<String>? storefrontKinds}) => ChecklistTemplateItem(
        id: id,
        label: label ?? this.label,
        help: help ?? this.help,
        photoRequired: photoRequired ?? this.photoRequired,
        storefrontKinds: storefrontKinds ?? this.storefrontKinds,
        sort: sort,
      );
}

class ChecklistTemplate {
  const ChecklistTemplate({this.id = '', required this.kind, required this.name, this.sort = 0, this.active = true, this.items = const []});

  final String id;
  final ChecklistKind kind;
  final String name;
  final int sort;
  final bool active;
  final List<ChecklistTemplateItem> items;

  List<ChecklistTemplateItem> itemsFor(StorefrontKind kind) => [for (final i in items) if (i.appliesTo(kind)) i];

  factory ChecklistTemplate.fromJson(Map<String, dynamic> j) => ChecklistTemplate(
        id: j['id'] as String,
        kind: ChecklistKind.fromCode(j['kind'] as String?),
        name: j['name'] as String,
        sort: (j['sort'] as num?)?.toInt() ?? 0,
        active: (j['active'] as bool?) ?? true,
        items: [for (final i in (j['items'] as List?) ?? const []) ChecklistTemplateItem.fromJson((i as Map).cast())],
      );

  Map<String, dynamic> toJson(String venueId) => {
        if (id.isNotEmpty) 'id': id,
        'venue_id': venueId,
        'kind': kind.name,
        'name': name,
        'sort': sort,
        'active': active,
        'items': [for (final i in items) i.toJson()],
      };
}

enum ChecklistStatus {
  notStarted('not_started', 'Not started'),
  inProgress('in_progress', 'In progress'),
  complete('complete', 'Ready to sign off'),
  signedOff('signed_off', 'Signed off');

  const ChecklistStatus(this.code, this.label);
  final String code;
  final String label;

  static ChecklistStatus fromCode(String? c) => values.firstWhere((v) => v.code == c, orElse: () => inProgress);
}

class ChecklistRunItem {
  const ChecklistRunItem({
    this.id = '',
    required this.templateItemId,
    required this.label,
    this.help = '',
    this.photoRequired = false,
    this.sort = 0,
    this.done = false,
    this.doneByName = '',
    this.doneAt,
    this.note = '',
    this.photoPaths = const [],
    this.lastChangeAt,
    this.pendingPhotos = 0,
    this.pending = false,
  });

  final String id;
  final String templateItemId;
  final String label;
  final String help;
  final bool photoRequired;
  final int sort;
  final bool done;
  final String doneByName;
  final DateTime? doneAt;
  final String note;
  final List<String> photoPaths;
  final DateTime? lastChangeAt;

  /// Photos taken on this device that have not reached the server yet.
  final int pendingPhotos;

  /// A change on this device is waiting to be sent.
  final bool pending;

  int get photoCount => photoPaths.length + pendingPhotos;
  bool get finished => done && (!photoRequired || photoCount > 0);

  factory ChecklistRunItem.fromJson(Map<String, dynamic> j) => ChecklistRunItem(
        id: j['id'] as String,
        templateItemId: j['template_item_id'] as String,
        label: j['label'] as String,
        help: (j['help'] as String?) ?? '',
        photoRequired: (j['photo_required'] as bool?) ?? false,
        sort: (j['sort'] as num?)?.toInt() ?? 0,
        done: (j['done'] as bool?) ?? false,
        doneByName: (j['done_by_name'] as String?) ?? '',
        doneAt: _time(j['done_at']),
        note: (j['note'] as String?) ?? '',
        photoPaths: _strings(j['photo_paths']),
        lastChangeAt: _time(j['last_change_at']),
      );

  factory ChecklistRunItem.fromTemplate(ChecklistTemplateItem t) =>
      ChecklistRunItem(templateItemId: t.id, label: t.label, help: t.help, photoRequired: t.photoRequired, sort: t.sort);

  ChecklistRunItem copyWith({bool? done, String? doneByName, DateTime? doneAt, bool clearDoneAt = false, String? note, int? pendingPhotos, bool? pending, DateTime? lastChangeAt}) =>
      ChecklistRunItem(
        id: id,
        templateItemId: templateItemId,
        label: label,
        help: help,
        photoRequired: photoRequired,
        sort: sort,
        done: done ?? this.done,
        doneByName: doneByName ?? this.doneByName,
        doneAt: clearDoneAt ? null : (doneAt ?? this.doneAt),
        note: note ?? this.note,
        photoPaths: photoPaths,
        lastChangeAt: lastChangeAt ?? this.lastChangeAt,
        pendingPhotos: pendingPhotos ?? this.pendingPhotos,
        pending: pending ?? this.pending,
      );
}

/// One checklist at one storefront for one event. Before anyone ticks an item it exists
/// only on the device ([id] empty, [status] not started), built from the template.
class ChecklistRun {
  const ChecklistRun({
    this.id = '',
    required this.eventId,
    required this.storefrontId,
    required this.templateId,
    required this.templateName,
    required this.templateKind,
    required this.status,
    this.items = const [],
    this.signedOffByName = '',
    this.signedOffAt,
    this.signOffNote = '',
    this.reopenedByName = '',
    this.reopenedAt,
    this.reopenReason = '',
  });

  final String id;
  final String eventId;
  final String storefrontId;
  final String templateId;
  final String templateName;
  final ChecklistKind templateKind;
  final ChecklistStatus status;
  final List<ChecklistRunItem> items;
  final String signedOffByName;
  final DateTime? signedOffAt;
  final String signOffNote;
  final String reopenedByName;
  final DateTime? reopenedAt;
  final String reopenReason;

  int get total => items.length;
  int get doneCount => items.where((i) => i.finished).length;
  bool get allDone => items.isNotEmpty && items.every((i) => i.finished);
  bool get hasPending => items.any((i) => i.pending);
  bool get signedOff => status == ChecklistStatus.signedOff;

  /// Short label for chips: "Opening 5/7".
  String get chipLabel => signedOff ? '$templateName signed off' : '$templateName $doneCount/$total';

  /// The server answers a resent change id with only {id, stored: true} when the person
  /// can no longer see the run, so every other field may be missing.
  factory ChecklistRun.fromJson(Map<String, dynamic> j) => ChecklistRun(
        id: j['id'] as String,
        eventId: (j['event_id'] as String?) ?? '',
        storefrontId: (j['storefront_id'] as String?) ?? '',
        templateId: (j['template_id'] as String?) ?? '',
        templateName: (j['template_name'] as String?) ?? '',
        templateKind: ChecklistKind.fromCode(j['template_kind'] as String?),
        status: ChecklistStatus.fromCode(j['status'] as String?),
        items: [for (final i in (j['items'] as List?) ?? const []) ChecklistRunItem.fromJson((i as Map).cast())]
          ..sort((a, b) => a.sort.compareTo(b.sort)),
        signedOffByName: (j['signed_off_by_name'] as String?) ?? '',
        signedOffAt: _time(j['signed_off_at']),
        signOffNote: (j['sign_off_note'] as String?) ?? '',
        reopenedByName: (j['reopened_by_name'] as String?) ?? '',
        reopenedAt: _time(j['reopened_at']),
        reopenReason: (j['reopen_reason'] as String?) ?? '',
      );

  ChecklistRun copyWith({ChecklistStatus? status, List<ChecklistRunItem>? items}) => ChecklistRun(
        id: id,
        eventId: eventId,
        storefrontId: storefrontId,
        templateId: templateId,
        templateName: templateName,
        templateKind: templateKind,
        status: status ?? this.status,
        items: items ?? this.items,
        signedOffByName: signedOffByName,
        signedOffAt: signedOffAt,
        signOffNote: signOffNote,
        reopenedByName: reopenedByName,
        reopenedAt: reopenedAt,
        reopenReason: reopenReason,
      );
}

/// Everything the Checklists screen shows for one event, limited to the person's scope.
class EventChecklists {
  const EventChecklists({
    required this.eventId,
    required this.storefrontIds,
    required this.templates,
    required this.runs,
    this.editStorefrontIds = const {},
    this.signOffStorefrontIds = const {},
  });

  final String eventId;

  /// Open storefronts in scope, in display order.
  final List<String> storefrontIds;
  final List<ChecklistTemplate> templates;
  final List<ChecklistRun> runs;

  /// Where the person can tick items, and where they can sign off.
  final Set<String> editStorefrontIds;
  final Set<String> signOffStorefrontIds;

  bool canEdit(String storefrontId) => editStorefrontIds.contains(storefrontId);
  bool canSignOff(String storefrontId) => signOffStorefrontIds.contains(storefrontId);

  /// The run for one template at one storefront: the stored one, or a not-started one
  /// built from the template's items for the storefront's kind.
  ChecklistRun runFor(String storefrontId, ChecklistTemplate template, StorefrontKind kind) {
    for (final r in runs) {
      if (r.storefrontId == storefrontId && r.templateId == template.id) return r;
    }
    return ChecklistRun(
      eventId: eventId,
      storefrontId: storefrontId,
      templateId: template.id,
      templateName: template.name,
      templateKind: template.kind,
      status: ChecklistStatus.notStarted,
      items: [for (final i in template.itemsFor(kind)) ChecklistRunItem.fromTemplate(i)],
    );
  }

  /// Every checklist at a storefront: one per active template with items for its kind,
  /// plus any run of a template since turned off.
  List<ChecklistRun> runsAt(String storefrontId, StorefrontKind kind) {
    final out = <ChecklistRun>[
      for (final t in templates)
        if (t.itemsFor(kind).isNotEmpty || runs.any((r) => r.storefrontId == storefrontId && r.templateId == t.id)) runFor(storefrontId, t, kind),
    ];
    for (final r in runs) {
      if (r.storefrontId == storefrontId && !templates.any((t) => t.id == r.templateId)) out.add(r);
    }
    return out;
  }

  EventChecklists copyWith({List<ChecklistRun>? runs}) => EventChecklists(
        eventId: eventId,
        storefrontIds: storefrontIds,
        templates: templates,
        runs: runs ?? this.runs,
        editStorefrontIds: editStorefrontIds,
        signOffStorefrontIds: signOffStorefrontIds,
      );

  factory EventChecklists.fromJson(Map<String, dynamic> j) => EventChecklists(
        eventId: j['event_id'] as String,
        storefrontIds: _strings(j['storefront_ids']),
        templates: [for (final t in (j['templates'] as List?) ?? const []) ChecklistTemplate.fromJson((t as Map).cast())],
        runs: [for (final r in (j['runs'] as List?) ?? const []) ChecklistRun.fromJson((r as Map).cast())],
        editStorefrontIds: {..._strings(j['edit_storefront_ids'])},
        signOffStorefrontIds: {..._strings(j['sign_off_storefront_ids'])},
      );
}

/// One tick or untick, made on the device. [id] is made on the device, so the change is
/// stored once however often it is sent.
class ChecklistItemChange {
  const ChecklistItemChange({
    required this.id,
    required this.eventId,
    required this.storefrontId,
    required this.templateId,
    required this.templateItemId,
    required this.done,
    required this.occurredAt,
    this.note,
  });

  final String id;
  final String eventId;
  final String storefrontId;
  final String templateId;
  final String templateItemId;
  final bool done;
  final DateTime occurredAt;

  /// Null leaves the note as it is.
  final String? note;

  Map<String, dynamic> toJson() => {
        'id': id,
        'event_id': eventId,
        'storefront_id': storefrontId,
        'template_id': templateId,
        'template_item_id': templateItemId,
        'done': done,
        'occurred_at': occurredAt.toUtc().toIso8601String(),
        'note': ?note,
      };

  factory ChecklistItemChange.fromJson(Map<String, dynamic> j) => ChecklistItemChange(
        id: j['id'] as String,
        eventId: j['event_id'] as String,
        storefrontId: j['storefront_id'] as String,
        templateId: j['template_id'] as String,
        templateItemId: j['template_item_id'] as String,
        done: (j['done'] as bool?) ?? false,
        occurredAt: DateTime.parse(j['occurred_at'] as String).toUtc(),
        note: j['note'] as String?,
      );
}

// ---------------------------------------------------------------------------
// Incidents
// ---------------------------------------------------------------------------

enum IncidentKind {
  injury('Injury'),
  safety('Safety'),
  employee('Employee'),
  other('Other');

  const IncidentKind(this.label);
  final String label;

  static IncidentKind fromCode(String? c) => values.firstWhere((v) => v.name == c, orElse: () => other);
}

enum IncidentSeverity {
  low('Low'),
  medium('Medium'),
  high('High');

  const IncidentSeverity(this.label);
  final String label;

  static IncidentSeverity fromCode(String? c) => values.firstWhere((v) => v.name == c, orElse: () => low);
}

enum IncidentStatus {
  open('open', 'Open'),
  followingUp('following_up', 'Following up'),
  closed('closed', 'Closed');

  const IncidentStatus(this.code, this.label);
  final String code;
  final String label;

  static IncidentStatus fromCode(String? c) => values.firstWhere((v) => v.code == c, orElse: () => open);
}

class IncidentPerson {
  const IncidentPerson({required this.id, required this.name, this.employeeNumber = ''});

  final String id;
  final String name;
  final String employeeNumber;

  factory IncidentPerson.fromJson(Map<String, dynamic> j) =>
      IncidentPerson(id: j['id'] as String, name: (j['name'] as String?) ?? '', employeeNumber: (j['employee_number'] as String?) ?? '');
}

class IncidentNote {
  const IncidentNote({required this.id, required this.kind, required this.body, required this.authorName, required this.createdAt, this.pending = false});

  final String id;

  /// note, status, assigned, photos.
  final String kind;
  final String body;
  final String authorName;
  final DateTime createdAt;
  final bool pending;

  factory IncidentNote.fromJson(Map<String, dynamic> j) => IncidentNote(
        id: j['id'] as String,
        kind: (j['kind'] as String?) ?? 'note',
        body: j['body'] as String,
        authorName: (j['author_name'] as String?) ?? '',
        createdAt: _time(j['created_at'])!,
      );
}

class Incident {
  const Incident({
    required this.id,
    required this.venueId,
    required this.kind,
    required this.severity,
    required this.occurredAt,
    required this.description,
    required this.status,
    this.eventId,
    this.eventName = '',
    this.storefrontId,
    this.photoPaths = const [],
    this.assignedTo,
    this.assignedToName = '',
    this.closingNote = '',
    this.closedAt,
    this.closedByName = '',
    this.reportedBy = '',
    this.reportedByName = '',
    this.createdAt,
    this.people = const [],
    this.notes = const [],
    this.pending = false,
    this.pendingPhotos = 0,
  });

  final String id;
  final String venueId;
  final IncidentKind kind;
  final IncidentSeverity severity;
  final DateTime occurredAt;
  final String description;
  final IncidentStatus status;
  final String? eventId;
  final String eventName;
  final String? storefrontId;
  final List<String> photoPaths;
  final String? assignedTo;
  final String assignedToName;
  final String closingNote;
  final DateTime? closedAt;
  final String closedByName;
  final String reportedBy;
  final String reportedByName;
  final DateTime? createdAt;
  final List<IncidentPerson> people;
  final List<IncidentNote> notes;

  /// Logged on this device and not sent yet.
  final bool pending;
  final int pendingPhotos;

  String get summary {
    final first = description.trim().split('\n').first;
    return first.length > 90 ? '${first.substring(0, 87)}...' : first;
  }

  /// May be the bare {id, stored: true} acknowledgement (see [ChecklistRun.fromJson]).
  factory Incident.fromJson(Map<String, dynamic> j) => Incident(
        id: j['id'] as String,
        venueId: (j['venue_id'] as String?) ?? '',
        kind: IncidentKind.fromCode(j['kind'] as String?),
        severity: IncidentSeverity.fromCode(j['severity'] as String?),
        occurredAt: _time(j['occurred_at']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        description: (j['description'] as String?) ?? '',
        status: IncidentStatus.fromCode(j['status'] as String?),
        eventId: j['event_id'] as String?,
        eventName: (j['event_name'] as String?) ?? '',
        storefrontId: j['storefront_id'] as String?,
        photoPaths: _strings(j['photo_paths']),
        assignedTo: j['assigned_to'] as String?,
        assignedToName: (j['assigned_to_name'] as String?) ?? '',
        closingNote: (j['closing_note'] as String?) ?? '',
        closedAt: _time(j['closed_at']),
        closedByName: (j['closed_by_name'] as String?) ?? '',
        reportedBy: (j['reported_by'] as String?) ?? '',
        reportedByName: (j['reported_by_name'] as String?) ?? '',
        createdAt: _time(j['created_at']),
        people: [for (final p in (j['people'] as List?) ?? const []) IncidentPerson.fromJson((p as Map).cast())],
        notes: [for (final n in (j['notes'] as List?) ?? const []) IncidentNote.fromJson((n as Map).cast())],
      );

  Incident copyWith({List<IncidentNote>? notes, int? pendingPhotos}) => Incident(
        id: id,
        venueId: venueId,
        kind: kind,
        severity: severity,
        occurredAt: occurredAt,
        description: description,
        status: status,
        eventId: eventId,
        eventName: eventName,
        storefrontId: storefrontId,
        photoPaths: photoPaths,
        assignedTo: assignedTo,
        assignedToName: assignedToName,
        closingNote: closingNote,
        closedAt: closedAt,
        closedByName: closedByName,
        reportedBy: reportedBy,
        reportedByName: reportedByName,
        createdAt: createdAt,
        people: people,
        notes: notes ?? this.notes,
        pending: pending,
        pendingPhotos: pendingPhotos ?? this.pendingPhotos,
      );
}

/// A new incident, made on the device. [id] is made on the device so a resend is stored once.
class IncidentDraft {
  const IncidentDraft({
    required this.id,
    required this.venueId,
    required this.kind,
    required this.severity,
    required this.occurredAt,
    required this.description,
    this.eventId,
    this.storefrontId,
    this.people = const [],
  });

  final String id;
  final String venueId;
  final IncidentKind kind;
  final IncidentSeverity severity;
  final DateTime occurredAt;
  final String description;
  final String? eventId;
  final String? storefrontId;
  final List<IncidentPerson> people;

  Map<String, dynamic> toJson() => {
        'id': id,
        'venue_id': venueId,
        'kind': kind.name,
        'severity': severity.name,
        'occurred_at': occurredAt.toUtc().toIso8601String(),
        'description': description,
        'event_id': eventId,
        'storefront_id': storefrontId,
        'worker_ids': [for (final p in people) p.id],
        // Kept for showing the report while it waits to be sent.
        'people': [for (final p in people) {'id': p.id, 'name': p.name, 'employee_number': p.employeeNumber}],
      };

  factory IncidentDraft.fromJson(Map<String, dynamic> j) => IncidentDraft(
        id: j['id'] as String,
        venueId: j['venue_id'] as String,
        kind: IncidentKind.fromCode(j['kind'] as String?),
        severity: IncidentSeverity.fromCode(j['severity'] as String?),
        occurredAt: DateTime.parse(j['occurred_at'] as String).toUtc(),
        description: (j['description'] as String?) ?? '',
        eventId: j['event_id'] as String?,
        storefrontId: j['storefront_id'] as String?,
        people: [for (final p in (j['people'] as List?) ?? const []) IncidentPerson.fromJson((p as Map).cast())],
      );

  /// How the report shows before the server has it.
  Incident toPendingIncident({String reportedByName = '', int photos = 0}) => Incident(
        id: id,
        venueId: venueId,
        kind: kind,
        severity: severity,
        occurredAt: occurredAt,
        description: description,
        status: IncidentStatus.open,
        eventId: eventId,
        storefrontId: storefrontId,
        people: people,
        reportedByName: reportedByName,
        pending: true,
        pendingPhotos: photos,
      );
}

class IncidentNoteDraft {
  const IncidentNoteDraft({required this.id, required this.incidentId, required this.body, required this.createdAt});

  final String id;
  final String incidentId;
  final String body;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {'id': id, 'incident_id': incidentId, 'body': body, 'created_at': createdAt.toUtc().toIso8601String()};

  factory IncidentNoteDraft.fromJson(Map<String, dynamic> j) => IncidentNoteDraft(
        id: j['id'] as String,
        incidentId: j['incident_id'] as String,
        body: (j['body'] as String?) ?? '',
        createdAt: DateTime.parse(j['created_at'] as String).toUtc(),
      );
}

class IncidentAssignee {
  const IncidentAssignee({required this.userId, required this.name});

  final String userId;
  final String name;

  factory IncidentAssignee.fromJson(Map<String, dynamic> j) => IncidentAssignee(userId: j['user_id'] as String, name: (j['name'] as String?) ?? '');
}
