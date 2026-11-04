import 'models.dart';

/// Phase 5: venue admin (name, time zone, branding), data retention, and removing a
/// person's personal data on request.
///
/// Deleting personal data never deletes a time record: wage and hour history has to be
/// kept for the retention period. Approving a request anonymises the person instead, so
/// their hours and pay stay attached to a record with no personal details.
abstract interface class AdminRepository {
  /// Venue name, time zone and branding. Needs manage_settings.
  Future<void> saveVenueProfile(AppSession session, {String? name, String? timeZone, Map<String, dynamic>? branding});

  /// The venue's retention periods, or the defaults when none are saved.
  Future<RetentionPolicy> loadRetention(AppSession session);

  /// Needs manage_settings. Throws [AppFailure] when a period is out of range.
  Future<void> saveRetention(AppSession session, RetentionPolicy policy);

  /// How many records are past their retention period right now.
  Future<RetentionDue> retentionDue(AppSession session);

  /// Clears clock-in photos older than the photo retention period. Returns how many.
  Future<int> purgeOldPunchPhotos(AppSession session);

  /// Deletion requests, newest first. Needs manage_workers.
  Future<List<DeletionRequest>> loadDeletionRequests(AppSession session);

  /// Records a request to remove someone's personal data. Needs manage_workers.
  Future<void> requestDataDeletion(AppSession session, String workerId, {String note = ''});

  /// Approves and carries out a request: the person is anonymised, their work history
  /// stays. Needs manage_settings, and cannot be done by whoever asked.
  Future<void> approveDataDeletion(AppSession session, String requestId, {String note = ''});

  /// Refuses a request, with a reason. Needs manage_settings.
  Future<void> refuseDataDeletion(AppSession session, String requestId, String reason);
}

/// How long records are kept, in months.
class RetentionPolicy {
  const RetentionPolicy({
    this.timeRecordsMonths = 48,
    this.punchPhotoMonths = 12,
    this.inactiveWorkerMonths = 48,
  });

  /// Four years, the window chosen for this venue. Two years is the floor.
  final int timeRecordsMonths;
  final int punchPhotoMonths;
  final int inactiveWorkerMonths;

  static const defaults = RetentionPolicy();

  factory RetentionPolicy.fromRow(Map<String, dynamic>? j) => j == null
      ? defaults
      : RetentionPolicy(
          timeRecordsMonths: (j['time_records_months'] as num?)?.toInt() ?? 48,
          punchPhotoMonths: (j['punch_photos_months'] as num?)?.toInt() ?? 12,
          inactiveWorkerMonths: (j['inactive_worker_months'] as num?)?.toInt() ?? 48,
        );

  Map<String, dynamic> toRow(String venueId) => {
        'venue_id': venueId,
        'time_records_months': timeRecordsMonths,
        'punch_photos_months': punchPhotoMonths,
        'inactive_worker_months': inactiveWorkerMonths,
      };

  RetentionPolicy copyWith({int? timeRecordsMonths, int? punchPhotoMonths, int? inactiveWorkerMonths}) => RetentionPolicy(
        timeRecordsMonths: timeRecordsMonths ?? this.timeRecordsMonths,
        punchPhotoMonths: punchPhotoMonths ?? this.punchPhotoMonths,
        inactiveWorkerMonths: inactiveWorkerMonths ?? this.inactiveWorkerMonths,
      );

  /// A plain message when a period is out of range, else null. Matches the database
  /// checks in 0023: time and worker periods 24 to 120 months, photos 1 to 120.
  String? validate() {
    if (timeRecordsMonths < 24 || timeRecordsMonths > 120) {
      return 'Keep time records between 24 and 120 months. Two years is the legal floor.';
    }
    if (inactiveWorkerMonths < 24 || inactiveWorkerMonths > 120) return 'Keep staff records between 24 and 120 months.';
    if (punchPhotoMonths < 1 || punchPhotoMonths > 120) return 'Keep clock-in photos between 1 and 120 months.';
    return null;
  }
}

/// Counts of what is past its retention period.
class RetentionDue {
  const RetentionDue({this.punchPhotos = 0, this.inactiveWorkers = 0});

  final int punchPhotos;
  final int inactiveWorkers;

  bool get isEmpty => punchPhotos == 0 && inactiveWorkers == 0;

  factory RetentionDue.fromJson(Map<String, dynamic> j) => RetentionDue(
        punchPhotos: (j['punch_photos'] as num?)?.toInt() ?? 0,
        inactiveWorkers: (j['inactive_workers'] as num?)?.toInt() ?? 0,
      );
}

/// One request to remove a person's personal data.
class DeletionRequest {
  const DeletionRequest({
    required this.id,
    required this.workerId,
    required this.status,
    required this.requestedAt,
    this.note = '',
    this.decisionNote = '',
    this.requestedByMe = false,
  });

  final String id;
  final String workerId;

  /// pending, approved, refused or completed.
  final String status;
  final DateTime requestedAt;
  final String note;
  final String decisionNote;

  /// True when the signed-in person asked; they cannot approve their own request.
  final bool requestedByMe;

  bool get isPending => status == 'pending';

  factory DeletionRequest.fromRow(Map<String, dynamic> j, {String? myUserId}) => DeletionRequest(
        id: j['id'] as String,
        workerId: j['worker_id'] as String,
        status: j['status'] as String,
        requestedAt: DateTime.parse(j['requested_at'] as String).toUtc(),
        note: (j['note'] as String?) ?? '',
        decisionNote: (j['decision_note'] as String?) ?? '',
        requestedByMe: myUserId != null && j['requested_by'] == myUserId,
      );
}
