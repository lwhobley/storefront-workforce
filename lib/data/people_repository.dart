import 'dart:typed_data';

import 'package:workforce_core/workforce_core.dart';

import 'models.dart';

/// Phase 3: onboarding, adding people and importing the roster, partner portals (NPO
/// coordinators, temp agencies), and employees' own hours and tips.
abstract interface class PeopleRepository {
  // ---- The signed-in person ----

  /// Own time records, the events they belong to, and own shifts, for punches between
  /// two instants. Times only: no rates or amounts.
  Future<MyHoursData> loadMyHours(AppSession session, DateTime from, DateTime to);

  /// Own tips from finished tip pools, newest first.
  Future<List<MyTip>> loadMyTips(AppSession session);

  /// Own onboarding checklist with the documents to read and own contact details.
  Future<OnboardingState> myOnboarding(AppSession session);

  /// Stores a file in the person's own onboarding folder and returns its path.
  Future<String> uploadOnboardingFile(AppSession session, String fileName, Uint8List bytes, {String contentType = 'image/jpeg'});

  Future<OnboardingState> submitOnboardingStep(AppSession session, String step, Map<String, dynamic> data, {List<String> files = const []});

  /// An uploaded file (card photo). Null when it cannot be shown.
  Future<Uint8List?> downloadOnboardingFile(String path);

  /// Own certifications with whether a manager has checked them.
  Future<List<CertRecord>> workerCertifications(String workerId);

  // ---- Managers ----

  Future<List<OnboardingState>> onboardingOverview(AppSession session);
  Future<OnboardingState> workerOnboarding(String workerId);
  Future<OnboardingState> reviewOnboardingStep(String workerId, String step, {required bool approve, String note = ''});

  /// Ticks training ({"items": [...]}) or marks Paycom done ({"completed_on": "yyyy-mm-dd"}).
  Future<OnboardingState> completeOnboardingStep(String workerId, String step, Map<String, dynamic> data);
  Future<void> sendOnboardingReminder(String workerId);
  Future<List<OnboardingDocument>> listOnboardingDocuments(AppSession session);

  /// Creates the document when its id is empty.
  Future<void> saveOnboardingDocument(AppSession session, OnboardingDocument document);

  /// Adds one person (and their trained roles). Their onboarding starts at once.
  Future<Worker> addWorker(AppSession session, NewPerson person);

  /// Adds the new rows and, when [updateExisting], updates people whose employee number
  /// is already on file. Rows must be valid (see parseRoster).
  Future<RosterImportResult> importRoster(AppSession session, List<NewPerson> rows, {required bool updateExisting});
  Future<void> verifyCertification(AppSession session, String certId);

  // ---- Partners ----

  Future<NpoPortalData> loadNpoPortal(AppSession session, DateTime from, DateTime to, {String? groupId});
  Future<AgencyPortalData> loadAgencyPortal(AppSession session, DateTime from, DateTime to, {String? agencyId});
}

// ---------------------------------------------------------------------------
// Employee: hours and tips
// ---------------------------------------------------------------------------

/// Own punches with the events and shifts they belong to. Never carries rates.
class MyHoursData {
  const MyHoursData({required this.punches, required this.events, required this.shifts});

  final List<Punch> punches;
  final Map<String, Event> events;
  final List<Shift> shifts;
}

class MyTip {
  const MyTip({required this.eventId, required this.eventName, required this.startTime, required this.storefrontName, required this.hoursHundredths, required this.amountCents});

  final String eventId;
  final String eventName;
  final DateTime startTime;
  final String storefrontName;
  final int hoursHundredths;
  final int amountCents;

  factory MyTip.fromJson(Map<String, dynamic> j) => MyTip(
        eventId: j['event_id'] as String,
        eventName: j['event_name'] as String,
        startTime: DateTime.parse(j['start_time'] as String).toUtc(),
        storefrontName: (j['storefront_name'] as String?) ?? '',
        hoursHundredths: j['hours'] == null ? 0 : parseScaled(j['hours'], 2),
        amountCents: parseCents(j['amount']),
      );
}

// ---------------------------------------------------------------------------
// Onboarding
// ---------------------------------------------------------------------------

enum StepKind {
  form,
  document,
  upload,
  checklist,
  external;

  static StepKind fromCode(String? c) => values.firstWhere((v) => v.name == c, orElse: () => form);
}

enum StepStatus {
  notStarted('not_started'),
  submitted('submitted'),
  approved('approved'),
  needsChanges('needs_changes'),
  complete('complete');

  const StepStatus(this.code);
  final String code;

  static StepStatus fromCode(String? c) => values.firstWhere((v) => v.code == c, orElse: () => notStarted);
}

class ChecklistItem {
  const ChecklistItem({required this.code, required this.label, this.roles = const []});

  final String code;
  final String label;

  /// Only for people trained in one of these roles; empty = everyone.
  final List<String> roles;

  factory ChecklistItem.fromJson(Map<String, dynamic> j) => ChecklistItem(
        code: j['code'] as String,
        label: (j['label'] as String?) ?? j['code'] as String,
        roles: [for (final r in (j['roles'] as List?) ?? const []) r as String],
      );

  Map<String, dynamic> toJson() => {'code': code, 'label': label, if (roles.isNotEmpty) 'roles': roles};
}

/// A card uploaded by the person and not yet checked by a manager.
class PendingCert {
  const PendingCert({required this.id, required this.typeCode, this.number = '', this.expiresOn, this.documentPath});

  final String id;
  final String typeCode;
  final String number;
  final DateTime? expiresOn;
  final String? documentPath;

  factory PendingCert.fromJson(Map<String, dynamic> j) => PendingCert(
        id: j['id'] as String,
        typeCode: j['cert_type_code'] as String,
        number: (j['number'] as String?) ?? '',
        expiresOn: _date(j['expires_on']),
        documentPath: j['document_path'] as String?,
      );
}

/// One step for one person, with what the step needs to show.
class OnboardingStepState {
  const OnboardingStepState({
    required this.code,
    required this.name,
    required this.kind,
    required this.status,
    this.description = '',
    this.required = true,
    this.sort = 0,
    this.done = false,
    this.note = '',
    this.submittedAt,
    this.reviewedAt,
    this.config = const {},
    this.data = const {},
    this.filePaths = const [],
    this.documentIds = const [],
    this.missingDocumentIds = const [],
    this.guardianRequired = false,
    this.birthDateOnFile = true,
    this.requiredCerts = const [],
    this.missingCerts = const [],
    this.pendingCerts = const [],
    this.items = const [],
  });

  final String code;
  final String name;
  final String description;
  final StepKind kind;
  final bool required;
  final int sort;
  final StepStatus status;
  final bool done;

  /// The manager's note when sent back.
  final String note;
  final DateTime? submittedAt;
  final DateTime? reviewedAt;
  final Map<String, dynamic> config;

  /// Answers, acknowledgments, uploaded cards, ticked items, Paycom date.
  final Map<String, dynamic> data;
  final List<String> filePaths;

  // Document steps.
  final List<String> documentIds;
  final List<String> missingDocumentIds;
  final bool guardianRequired;
  final bool birthDateOnFile;

  // Card step.
  final List<String> requiredCerts;
  final List<String> missingCerts;
  final List<PendingCert> pendingCerts;

  // Checklist steps.
  final List<ChecklistItem> items;

  Set<String> get itemsDone => {...((data['items'] as Map?) ?? const {}).keys.cast<String>()};

  bool get managerOnly => kind == StepKind.checklist || kind == StepKind.external || config['manager_only'] == true;
  bool get needsReview => status == StepStatus.submitted;

  List<Map<String, dynamic>> get acknowledgments =>
      [for (final a in (data['acknowledgments'] as List?) ?? const []) (a as Map).cast<String, dynamic>()];

  factory OnboardingStepState.fromJson(Map<String, dynamic> j) => OnboardingStepState(
        code: j['code'] as String,
        name: j['name'] as String,
        description: (j['description'] as String?) ?? '',
        kind: StepKind.fromCode(j['kind'] as String?),
        required: (j['required'] as bool?) ?? true,
        sort: (j['sort'] as num?)?.toInt() ?? 0,
        status: StepStatus.fromCode(j['status'] as String?),
        done: (j['done'] as bool?) ?? false,
        note: (j['note'] as String?) ?? '',
        submittedAt: _instant(j['submitted_at']),
        reviewedAt: _instant(j['reviewed_at']),
        config: ((j['config'] as Map?) ?? const {}).cast<String, dynamic>(),
        data: ((j['data'] as Map?) ?? const {}).cast<String, dynamic>(),
        filePaths: [for (final f in (j['file_paths'] as List?) ?? const []) f as String],
        documentIds: [for (final d in (j['documents'] as List?) ?? const []) (d as Map)['id'] as String],
        missingDocumentIds: [for (final d in (j['missing_documents'] as List?) ?? const []) (d as Map)['id'] as String],
        guardianRequired: (j['guardian_required'] as bool?) ?? false,
        birthDateOnFile: (j['birth_date_on_file'] as bool?) ?? true,
        requiredCerts: [for (final c in (j['required_certs'] as List?) ?? const []) c as String],
        missingCerts: [for (final c in (j['missing_certs'] as List?) ?? const []) c as String],
        pendingCerts: [for (final c in (j['pending_certs'] as List?) ?? const []) PendingCert.fromJson((c as Map).cast())],
        items: [for (final i in (j['items'] as List?) ?? const []) ChecklistItem.fromJson((i as Map).cast())],
      );
}

/// Where one person stands in onboarding.
class OnboardingState {
  const OnboardingState({
    required this.workerId,
    required this.firstName,
    required this.lastName,
    required this.employeeNumber,
    required this.workerType,
    required this.steps,
    this.preferredName = '',
    this.hasLogin = false,
    this.minor = false,
    this.startedAt,
    this.finishedAt,
    this.openSince,
    this.daysOpen = 0,
    this.done = 0,
    this.required = 0,
    this.percent = 0,
    this.missing = const [],
    this.needsReview = false,
    this.documents = const [],
    this.profile = const {},
  });

  final String workerId;
  final String firstName;
  final String lastName;
  final String preferredName;
  final String employeeNumber;
  final WorkerType workerType;
  final bool hasLogin;
  final bool minor;

  /// When the person was added; onboarding starts then.
  final DateTime? startedAt;

  /// When the last required step was done; null while open.
  final DateTime? finishedAt;

  /// While open: when the earliest outstanding requirement became outstanding (the day
  /// they were added, or later when a signed document changed or a card expired).
  final DateTime? openSince;

  /// Open: days since [openSince]. Finished: days it took.
  final int daysOpen;
  final int done;
  final int required;
  final int percent;

  /// Names of required steps not done.
  final List<String> missing;
  final bool needsReview;
  final List<OnboardingStepState> steps;

  /// Documents to read (own checklist and manager detail only).
  final List<OnboardingDocument> documents;

  /// Own contact details (own checklist only).
  final Map<String, dynamic> profile;

  bool get finished => finishedAt != null;
  bool get overdue => !finished && daysOpen > 7;
  String get displayName => '${preferredName.isNotEmpty ? preferredName : firstName} $lastName';

  OnboardingStepState? step(String code) => steps.where((s) => s.code == code).firstOrNull;
  OnboardingDocument? document(String id) => documents.where((d) => d.id == id).firstOrNull;

  factory OnboardingState.fromJson(Map<String, dynamic> j) => OnboardingState(
        workerId: j['worker_id'] as String,
        firstName: j['first_name'] as String,
        lastName: j['last_name'] as String,
        preferredName: (j['preferred_name'] as String?) ?? '',
        employeeNumber: (j['employee_number'] as String?) ?? '',
        workerType: WorkerType.fromCode(j['worker_type'] as String?),
        hasLogin: (j['has_login'] as bool?) ?? false,
        minor: (j['minor'] as bool?) ?? false,
        startedAt: _instant(j['started_at']),
        finishedAt: _instant(j['finished_at']),
        openSince: _instant(j['open_since']),
        daysOpen: (j['days_open'] as num?)?.toInt() ?? 0,
        done: (j['done'] as num?)?.toInt() ?? 0,
        required: (j['required'] as num?)?.toInt() ?? 0,
        percent: (j['percent'] as num?)?.toInt() ?? 0,
        missing: [for (final m in (j['missing'] as List?) ?? const []) m as String],
        needsReview: (j['needs_review'] as bool?) ?? false,
        steps: [for (final s in (j['steps'] as List?) ?? const []) OnboardingStepState.fromJson((s as Map).cast())],
        documents: [for (final d in (j['documents'] as List?) ?? const []) OnboardingDocument.fromJson((d as Map).cast())],
        profile: ((j['profile'] as Map?) ?? const {}).cast<String, dynamic>(),
      );
}

/// Totals for the top of the onboarding board.
class OnboardingSummary {
  const OnboardingSummary({required this.people, required this.finished, required this.needsReview, required this.overdue, this.averageDaysToComplete});

  final int people;
  final int finished;
  final int needsReview;
  final int overdue;

  /// Over people who finished; null when nobody has.
  final double? averageDaysToComplete;

  double get completionRate => people == 0 ? 1 : finished / people;

  factory OnboardingSummary.of(List<OnboardingState> list) {
    final done = [for (final s in list) if (s.finished) s];
    final days = [
      for (final s in done)
        if (s.startedAt != null) s.finishedAt!.difference(s.startedAt!).inMinutes / (60 * 24),
    ];
    return OnboardingSummary(
      people: list.length,
      finished: done.length,
      needsReview: list.where((s) => s.needsReview).length,
      overdue: list.where((s) => s.overdue).length,
      averageDaysToComplete: days.isEmpty ? null : days.reduce((a, b) => a + b) / days.length,
    );
  }
}

class OnboardingDocument {
  const OnboardingDocument({
    required this.id,
    required this.title,
    this.stepCode = 'policies',
    this.body = '',
    this.documentPath,
    this.version = 1,
    this.appliesTo = const ['regular', 'temp'],
    this.active = true,
    this.sort = 0,
  });

  /// Empty for a document not yet saved.
  final String id;
  final String stepCode;
  final String title;
  final String body;
  final String? documentPath;
  final int version;
  final List<String> appliesTo;
  final bool active;
  final int sort;

  factory OnboardingDocument.fromJson(Map<String, dynamic> j) => OnboardingDocument(
        id: j['id'] as String,
        stepCode: (j['step_code'] as String?) ?? 'policies',
        title: j['title'] as String,
        body: (j['body'] as String?) ?? '',
        documentPath: j['document_path'] as String?,
        version: (j['version'] as num?)?.toInt() ?? 1,
        appliesTo: [for (final a in (j['applies_to'] as List?) ?? const ['regular', 'temp']) a as String],
        active: (j['active'] as bool?) ?? true,
        sort: (j['sort'] as num?)?.toInt() ?? 0,
      );

  OnboardingDocument copyWith({String? id, String? stepCode, String? title, String? body, List<String>? appliesTo, bool? active, int? version}) => OnboardingDocument(
        id: id ?? this.id,
        stepCode: stepCode ?? this.stepCode,
        title: title ?? this.title,
        body: body ?? this.body,
        documentPath: documentPath,
        version: version ?? this.version,
        appliesTo: appliesTo ?? this.appliesTo,
        active: active ?? this.active,
        sort: sort,
      );
}

/// A certification with whether a manager has checked it.
class CertRecord {
  const CertRecord({required this.id, required this.workerId, required this.typeCode, this.number = '', this.issuedOn, this.expiresOn, this.documentPath, this.verified = true});

  final String id;
  final String workerId;
  final String typeCode;
  final String number;
  final DateTime? issuedOn;
  final DateTime? expiresOn;
  final String? documentPath;

  /// False for a card the person uploaded that no manager has checked yet.
  final bool verified;

  bool get awaitingCheck => !verified;

  factory CertRecord.fromJson(Map<String, dynamic> j) => CertRecord(
        id: j['id'] as String,
        workerId: j['worker_id'] as String,
        typeCode: j['cert_type_code'] as String,
        number: (j['number'] as String?) ?? '',
        issuedOn: _date(j['issued_on']),
        expiresOn: _date(j['expires_on']),
        documentPath: j['document_path'] as String?,
        // Cards entered by a manager have no upload to check.
        verified: j['verified_by'] != null || j['document_path'] == null,
      );
}

// ---------------------------------------------------------------------------
// Adding people and the roster import
// ---------------------------------------------------------------------------

/// A person to add (or update, by employee number).
class NewPerson {
  const NewPerson({
    required this.type,
    required this.employeeNumber,
    required this.firstName,
    required this.lastName,
    this.preferredName = '',
    this.dateOfBirth,
    this.phone = '',
    this.email = '',
    this.jobRoles = const [],
    this.agencyId,
    this.npoGroupId,
    this.paycomEmployeeCode = '',
    this.hireDate,
    this.preferredLanguage = 'en',
  });

  final WorkerType type;
  final String employeeNumber;
  final String firstName;
  final String lastName;
  final String preferredName;
  final DateTime? dateOfBirth;
  final String phone;
  final String email;
  final List<String> jobRoles;
  final String? agencyId;
  final String? npoGroupId;
  final String paycomEmployeeCode;
  final DateTime? hireDate;
  final String preferredLanguage;

  Map<String, dynamic> toRow(String venueId) => {
        'venue_id': venueId,
        'worker_type': type.code,
        'employee_number': employeeNumber,
        'first_name': firstName,
        'last_name': lastName,
        'preferred_name': preferredName,
        'date_of_birth': _dateStr(dateOfBirth),
        'phone': phone,
        'email': email,
        'agency_id': type == WorkerType.temp ? agencyId : null,
        'npo_group_id': type == WorkerType.npo ? npoGroupId : null,
        'paycom_employee_code': type == WorkerType.regular ? paycomEmployeeCode : '',
        'hire_date': _dateStr(hireDate),
        'preferred_language': preferredLanguage,
      };
}

class RosterImportResult {
  const RosterImportResult({required this.added, required this.updated, required this.skipped});

  final int added;
  final int updated;

  /// Rows whose employee number was already on file and updating was not confirmed.
  final int skipped;
}

// ---------------------------------------------------------------------------
// Partner portals
// ---------------------------------------------------------------------------

class PortalMember {
  const PortalMember({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.employeeNumber,
    this.preferredName = '',
    this.status = 'active',
    this.phone = '',
    this.minor = false,
    this.roles = const [],
    this.onboardingPercent = 0,
    this.onboardingMissing = const [],
    this.waiverStatus = 'not_required',
  });

  final String id;
  final String firstName;
  final String lastName;
  final String preferredName;
  final String employeeNumber;
  final String status;

  /// NPO members only.
  final String phone;
  final bool minor;
  final List<String> roles;
  final int onboardingPercent;
  final List<String> onboardingMissing;

  /// NPO members: not_started, complete, ... or not_required.
  final String waiverStatus;

  String get displayName => '${preferredName.isNotEmpty ? preferredName : firstName} $lastName';

  /// For the shared hours and billing engine.
  Worker toWorker(String venueId, WorkerType type, {String? agencyId, String? npoGroupId}) => Worker(
        id: id,
        venueId: venueId,
        type: type,
        employeeNumber: employeeNumber,
        firstName: firstName,
        lastName: lastName,
        preferredName: preferredName,
        agencyId: agencyId,
        npoGroupId: npoGroupId,
        status: status,
        jobRoles: roles,
      );

  factory PortalMember.fromJson(Map<String, dynamic> j) => PortalMember(
        id: j['id'] as String,
        firstName: j['first_name'] as String,
        lastName: j['last_name'] as String,
        preferredName: (j['preferred_name'] as String?) ?? '',
        employeeNumber: (j['employee_number'] as String?) ?? '',
        status: (j['status'] as String?) ?? 'active',
        phone: (j['phone'] as String?) ?? '',
        minor: (j['minor'] as bool?) ?? false,
        roles: [for (final r in (j['roles'] as List?) ?? const []) r as String],
        onboardingPercent: (j['onboarding_percent'] as num?)?.toInt() ?? 0,
        onboardingMissing: [for (final m in (j['onboarding_missing'] as List?) ?? const []) m as String],
        waiverStatus: (j['waiver_status'] as String?) ?? 'not_required',
      );
}

/// Shifts, events and time records of a partner's people.
class PartnerActivity {
  const PartnerActivity({required this.events, required this.shifts, required this.punches, this.storefrontNames = const {}});

  final Map<String, Event> events;
  final List<Shift> shifts;
  final List<Punch> punches;

  /// Shift id -> storefront name.
  final Map<String, String> storefrontNames;

  factory PartnerActivity.fromJson(Map<String, dynamic> j) => PartnerActivity(
        events: {
          for (final e in (j['events'] as List?) ?? const []) (e as Map)['id'] as String: Event.fromJson(e.cast()),
        },
        shifts: [for (final s in (j['shifts'] as List?) ?? const []) Shift.fromJson((s as Map).cast())],
        punches: [for (final p in (j['punches'] as List?) ?? const []) Punch.fromJson((p as Map).cast())],
        storefrontNames: {
          for (final s in (j['shifts'] as List?) ?? const []) (s as Map)['id'] as String: (s['storefront_name'] as String?) ?? '',
        },
      );
}

class NpoPortalData {
  const NpoPortalData({required this.groupId, required this.groupName, required this.legalName, required this.groups, required this.members, required this.activity, required this.payouts, this.eventNames = const {}});

  final String groupId;
  final String groupName;
  final String legalName;

  /// Every group the person coordinates: (id, name).
  final List<(String, String)> groups;
  final List<PortalMember> members;
  final PartnerActivity activity;
  final List<NpoPayout> payouts;

  /// Event id -> name, for payouts.
  final Map<String, String> eventNames;

  factory NpoPortalData.fromJson(Map<String, dynamic> j) {
    final g = (j['group'] as Map).cast<String, dynamic>();
    final payouts = [for (final p in (j['payouts'] as List?) ?? const []) (p as Map).cast<String, dynamic>()];
    return NpoPortalData(
      groupId: g['id'] as String,
      groupName: g['display_name'] as String,
      legalName: (g['legal_name'] as String?) ?? '',
      groups: [for (final x in (j['groups'] as List?) ?? const []) ((x as Map)['id'] as String, x['display_name'] as String)],
      members: [for (final m in (j['members'] as List?) ?? const []) PortalMember.fromJson((m as Map).cast())],
      activity: PartnerActivity.fromJson(j),
      payouts: [for (final p in payouts) NpoPayout.fromJson({...p, 'npo_group_id': g['id']})],
      eventNames: {for (final p in payouts) p['event_id'] as String: (p['event_name'] as String?) ?? ''},
    );
  }
}

class AgencyPortalData {
  const AgencyPortalData({required this.agencyId, required this.agencyName, required this.agencies, required this.members, required this.activity, required this.billRates});

  final String agencyId;
  final String agencyName;
  final List<(String, String)> agencies;
  final List<PortalMember> members;
  final PartnerActivity activity;

  /// This agency's bill rates only.
  final List<AgencyBillRate> billRates;

  factory AgencyPortalData.fromJson(Map<String, dynamic> j) {
    final a = (j['agency'] as Map).cast<String, dynamic>();
    return AgencyPortalData(
      agencyId: a['id'] as String,
      agencyName: a['name'] as String,
      agencies: [for (final x in (j['agencies'] as List?) ?? const []) ((x as Map)['id'] as String, x['name'] as String)],
      members: [for (final m in (j['members'] as List?) ?? const []) PortalMember.fromJson((m as Map).cast())],
      activity: PartnerActivity.fromJson(j),
      billRates: [for (final r in (j['bill_rates'] as List?) ?? const []) AgencyBillRate.fromJson((r as Map).cast())],
    );
  }
}

// ---------------------------------------------------------------------------

DateTime? _instant(Object? v) => v == null ? null : DateTime.parse(v as String).toUtc();

DateTime? _date(Object? v) {
  if (v == null) return null;
  final d = DateTime.parse(v as String);
  return DateTime.utc(d.year, d.month, d.day);
}

String? _dateStr(DateTime? d) => d == null
    ? null
    : '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// yyyy-mm-dd for a calendar date.
String dateOnly(DateTime d) => _dateStr(d)!;

/// Lower case with spaces collapsed, as the database's normalize_name().
String normalizeName(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// A typed signature matches the legal or preferred first name plus the last name.
bool typedNameMatches(String typed, {required String firstName, required String lastName, String preferredName = ''}) {
  final t = normalizeName(typed);
  if (t.isEmpty) return false;
  return t == normalizeName('$firstName $lastName') || (preferredName.trim().isNotEmpty && t == normalizeName('$preferredName $lastName'));
}
