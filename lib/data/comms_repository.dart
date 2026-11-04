import 'dart:typed_data';

import 'app_notification.dart';
import 'models.dart';

/// Who a message goes to.
enum MessageAudience {
  /// Everyone at the venue.
  everyone,

  /// Anyone who runs events: managers and leads (view_live or manage_schedule).
  managers,

  /// People working one level at an event, plus its leads and managers.
  level,

  /// People working one storefront at an event, plus its lead and managers.
  storefront,

  /// One person.
  worker;

  static MessageAudience fromCode(String? code) =>
      MessageAudience.values.firstWhere((a) => a.name == code, orElse: () => MessageAudience.everyone);
}

DateTime? _time(Object? v) => v == null ? null : DateTime.parse(v as String).toUtc();

/// A message or alert (the messages table), as its recipient or sender sees it.
class CommsMessage {
  const CommsMessage({
    required this.id,
    required this.senderName,
    required this.audience,
    required this.body,
    required this.createdAt,
    this.senderId,
    this.audienceId,
    this.audienceLabel = '',
    this.eventId,
    this.urgent = false,
    this.readAt,
    this.recipientCount = 0,
    this.readCount = 0,
    this.mine = false,
  });

  final String id;
  final String? senderId;
  final String senderName;
  final MessageAudience audience;
  final String? audienceId;

  /// For example 'Everyone', 'Stand 104 · Ice Hawks vs. Wranglers'.
  final String audienceLabel;
  final String? eventId;
  final String body;
  final bool urgent;
  final DateTime createdAt;

  /// When the signed-in person read it (inbox view).
  final DateTime? readAt;

  /// Sender view: how many people it went to, and how many have read it.
  final int recipientCount;
  final int readCount;
  final bool mine;

  bool get isRead => readAt != null;

  CommsMessage copyWith({DateTime? readAt, int? readCount, int? recipientCount}) => CommsMessage(
        id: id,
        senderId: senderId,
        senderName: senderName,
        audience: audience,
        audienceId: audienceId,
        audienceLabel: audienceLabel,
        eventId: eventId,
        body: body,
        urgent: urgent,
        createdAt: createdAt,
        readAt: readAt ?? this.readAt,
        recipientCount: recipientCount ?? this.recipientCount,
        readCount: readCount ?? this.readCount,
        mine: mine,
      );

  factory CommsMessage.fromJson(Map<String, dynamic> j) => CommsMessage(
        id: j['id'] as String,
        senderId: j['sender_id'] as String?,
        senderName: (j['sender_name'] as String?) ?? '',
        audience: MessageAudience.fromCode(j['audience'] as String?),
        audienceId: j['audience_id'] as String?,
        audienceLabel: (j['audience_label'] as String?) ?? '',
        eventId: j['event_id'] as String?,
        body: (j['body'] as String?) ?? '',
        urgent: (j['urgent'] as bool?) ?? false,
        createdAt: _time(j['created_at'])!,
        readAt: _time(j['read_at']),
        recipientCount: (j['recipient_count'] as num?)?.toInt() ?? 0,
        readCount: (j['read_count'] as num?)?.toInt() ?? 0,
        mine: (j['mine'] as bool?) ?? false,
      );
}

/// A message being written. [eventId] narrows a storefront or level audience to the
/// people working that event (the current event when left out).
class MessageDraft {
  const MessageDraft({required this.audience, required this.body, this.audienceId, this.eventId, this.urgent = false});

  final MessageAudience audience;
  final String? audienceId;
  final String? eventId;
  final String body;
  final bool urgent;

  Map<String, dynamic> toJson(String venueId) => {
        'venue_id': venueId,
        'audience': audience.name,
        'audience_id': ?audienceId,
        'event_id': ?eventId,
        'body': body,
        'urgent': urgent,
      };
}

/// Who an announcement is for. Empty lists mean no limit; every non-empty list must
/// match (worker type, any of the job roles, any of the venue roles).
class AnnouncementAudience {
  const AnnouncementAudience({this.workerTypes = const [], this.jobRoles = const [], this.roles = const []});

  static const everyone = AnnouncementAudience();

  /// regular, temp, npo.
  final List<String> workerTypes;

  /// Job role codes, for example bartender, lead.
  final List<String> jobRoles;

  /// Venue role codes, for example storefront_lead.
  final List<String> roles;

  bool get isEveryone => workerTypes.isEmpty && jobRoles.isEmpty && roles.isEmpty;

  Map<String, dynamic> toJson() => {
        if (workerTypes.isNotEmpty) 'worker_types': workerTypes,
        if (jobRoles.isNotEmpty) 'job_roles': jobRoles,
        if (roles.isNotEmpty) 'roles': roles,
      };

  static List<String> _list(Object? v) => [for (final x in (v is List ? v : const [])) x as String];

  factory AnnouncementAudience.fromJson(Map<String, dynamic>? j) => j == null
      ? everyone
      : AnnouncementAudience(workerTypes: _list(j['worker_types']), jobRoles: _list(j['job_roles']), roles: _list(j['roles']));
}

class Announcement {
  const Announcement({
    required this.id,
    required this.title,
    required this.publishedAt,
    this.body = '',
    this.audience = AnnouncementAudience.everyone,
    this.requiresAck = false,
    this.isPolicy = false,
    this.documentPath,
    this.expiresAt,
    this.createdByName = '',
    this.ackedAt,
    this.typedName = '',
    this.audienceCount = 0,
    this.ackCount = 0,
  });

  final String id;
  final String title;
  final String body;
  final AnnouncementAudience audience;
  final bool requiresAck;

  /// A policy is acknowledged with the person's typed name.
  final bool isPolicy;

  /// Attached document (storage path in the documents bucket).
  final String? documentPath;
  final DateTime publishedAt;
  final DateTime? expiresAt;
  final String createdByName;

  /// The signed-in person's acknowledgment.
  final DateTime? ackedAt;
  final String typedName;

  /// Manager view: people it is for, and how many have acknowledged.
  final int audienceCount;
  final int ackCount;

  bool get needsMyAck => requiresAck && ackedAt == null;

  factory Announcement.fromJson(Map<String, dynamic> j) => Announcement(
        id: j['id'] as String,
        title: j['title'] as String,
        body: (j['body'] as String?) ?? '',
        audience: AnnouncementAudience.fromJson((j['audience'] as Map?)?.cast<String, dynamic>()),
        requiresAck: (j['requires_ack'] as bool?) ?? false,
        isPolicy: (j['is_policy'] as bool?) ?? false,
        documentPath: j['document_path'] as String?,
        publishedAt: _time(j['published_at'])!,
        expiresAt: _time(j['expires_at']),
        createdByName: (j['created_by_name'] as String?) ?? '',
        ackedAt: _time(j['acked_at']),
        typedName: (j['typed_name'] as String?) ?? '',
        audienceCount: (j['audience_count'] as num?)?.toInt() ?? 0,
        ackCount: (j['ack_count'] as num?)?.toInt() ?? 0,
      );
}

class AnnouncementDraft {
  const AnnouncementDraft({
    required this.title,
    this.body = '',
    this.audience = AnnouncementAudience.everyone,
    this.requiresAck = false,
    this.isPolicy = false,
    this.documentPath,
    this.expiresAt,
  });

  final String title;
  final String body;
  final AnnouncementAudience audience;
  final bool requiresAck;
  final bool isPolicy;
  final String? documentPath;
  final DateTime? expiresAt;

  Map<String, dynamic> toJson(String venueId) => {
        'venue_id': venueId,
        'title': title,
        'body': body,
        'audience': audience.toJson(),
        'requires_ack': requiresAck || isPolicy,
        'is_policy': isPolicy,
        'document_path': ?documentPath,
        if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String(),
      };
}

/// One person an announcement is for, and whether they have acknowledged it.
class AckPerson {
  const AckPerson({required this.name, this.userId, this.workerId, this.employeeNumber = '', this.workerType, this.ackedAt, this.typedName = ''});

  final String? userId;
  final String? workerId;
  final String name;
  final String employeeNumber;
  final String? workerType;
  final DateTime? ackedAt;
  final String typedName;

  bool get acked => ackedAt != null;

  factory AckPerson.fromJson(Map<String, dynamic> j) => AckPerson(
        userId: j['user_id'] as String?,
        workerId: j['worker_id'] as String?,
        name: (j['name'] as String?) ?? '',
        employeeNumber: (j['employee_number'] as String?) ?? '',
        workerType: j['worker_type'] as String?,
        ackedAt: _time(j['acked_at']),
        typedName: (j['typed_name'] as String?) ?? '',
      );
}

class AckReport {
  const AckReport({required this.announcement, required this.people});

  final Announcement announcement;

  /// Not yet acknowledged first.
  final List<AckPerson> people;

  int get acked => people.where((p) => p.acked).length;
}

/// How a person wants push and email copies of notifications. (There are no text
/// messages.) Push is on by default; email is opt-in.
class NotificationPrefs {
  const NotificationPrefs({
    this.push = true,
    this.email = false,
    this.quietStart,
    this.quietEnd,
    this.hasStaffRecord = false,
    this.emailAddress = '',
  });

  final bool push;
  final bool email;

  /// 'HH:MM', venue local time. Both set or both null.
  final String? quietStart;
  final String? quietEnd;

  /// Staff email addresses come from the staff record (a manager changes them).
  final bool hasStaffRecord;
  final String emailAddress;

  bool get hasQuietHours => quietStart != null && quietEnd != null;

  NotificationPrefs copyWith({bool? push, bool? email, String? emailAddress}) => NotificationPrefs(
        push: push ?? this.push,
        email: email ?? this.email,
        quietStart: quietStart,
        quietEnd: quietEnd,
        hasStaffRecord: hasStaffRecord,
        emailAddress: emailAddress ?? this.emailAddress,
      );

  NotificationPrefs withQuietHours(String? start, String? end) => NotificationPrefs(
        push: push,
        email: email,
        quietStart: start == null || end == null ? null : start,
        quietEnd: start == null || end == null ? null : end,
        hasStaffRecord: hasStaffRecord,
        emailAddress: emailAddress,
      );

  Map<String, dynamic> toJson() => {
        'push': push,
        'email': email,
        'quiet_start': quietStart,
        'quiet_end': quietEnd,
        if (!hasStaffRecord) 'email_address': emailAddress,
      };

  factory NotificationPrefs.fromJson(Map<String, dynamic> j) => NotificationPrefs(
        push: (j['push'] as bool?) ?? true,
        email: (j['email'] as bool?) ?? false,
        quietStart: j['quiet_start'] as String?,
        quietEnd: j['quiet_end'] as String?,
        hasStaffRecord: (j['has_staff_record'] as bool?) ?? false,
        emailAddress: (j['email_address'] as String?) ?? '',
      );
}

/// An attached document, ready to open: a link (signed, short-lived) or the bytes.
class DocumentFile {
  const DocumentFile({required this.name, required this.mimeType, this.url, this.bytes});

  final String name;
  final String mimeType;
  final String? url;
  final Uint8List? bytes;
}

/// Phase 3: messages and alerts, announcements and policy acknowledgments, the
/// notification inbox, and delivery preferences (in-app, push, email; no text messages).
abstract interface class CommsRepository {
  // ---- Messages ----

  /// Messages to me (not the ones I sent), newest first.
  Future<List<CommsMessage>> myMessages(AppSession session);

  /// Messages I sent (venue managers: every message at the venue), with read counts.
  Future<List<CommsMessage>> sentMessages(AppSession session);
  Future<CommsMessage> sendMessage(AppSession session, MessageDraft draft);
  Future<void> markMessagesRead(AppSession session, List<String> ids);

  // ---- Announcements ----

  /// Announcements for me: ones I still need to acknowledge first.
  Future<List<Announcement>> myAnnouncements(AppSession session);

  /// Manager view: every announcement with its acknowledgment counts.
  Future<List<Announcement>> announcementSummaries(AppSession session);
  Future<Announcement> publishAnnouncement(AppSession session, AnnouncementDraft draft);
  Future<void> acknowledgeAnnouncement(AppSession session, String id, {String typedName = ''});
  Future<AckReport> ackReport(AppSession session, String id);

  /// Reminds everyone who has not acknowledged. Returns how many were reminded.
  Future<int> remindUnacknowledged(AppSession session, String id);

  /// Uploads a policy document and returns its storage path.
  Future<String> uploadDocument(AppSession session, String fileName, Uint8List bytes, String mimeType);
  Future<DocumentFile> openDocument(AppSession session, String path);

  // ---- Notifications ----
  Future<List<AppNotification>> myNotifications(AppSession session, {int limit = 100});

  /// Marks the given notifications read, or all of them.
  Future<void> markNotificationsRead(AppSession session, {List<String>? ids});

  /// Emits when a message, announcement, or notification for this person arrives or
  /// changes. The inbox reloads.
  Stream<void> commsChanges(AppSession session);

  // ---- Delivery preferences and devices ----
  Future<NotificationPrefs> notificationPrefs(AppSession session);
  Future<NotificationPrefs> saveNotificationPrefs(AppSession session, NotificationPrefs prefs);
  Future<void> registerPushToken(AppSession session, String token, String platform);
  Future<void> removePushToken(AppSession session, String token);
}
