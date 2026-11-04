/// One in-app notification (the notifications table). Push, SMS, and email copies are
/// sent separately when the venue has those set up.
class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.createdAt,
    this.body = '',
    this.link = '',
    this.readAt,
    this.data = const {},
  });

  final String id;
  final String kind;
  final String title;
  final String body;

  /// In-app route to open, for example '/schedule'.
  final String link;
  final DateTime createdAt;
  final DateTime? readAt;
  final Map<String, dynamic> data;

  bool get isRead => readAt != null;

  /// Messages and announcements have their own tabs in the inbox.
  bool get isMessage => kind == 'message';
  bool get isAnnouncement => kind == 'announcement';

  AppNotification copyWith({DateTime? readAt}) => AppNotification(
        id: id,
        kind: kind,
        title: title,
        createdAt: createdAt,
        body: body,
        link: link,
        readAt: readAt ?? this.readAt,
        data: data,
      );

  factory AppNotification.fromJson(Map<String, dynamic> j) => AppNotification(
        id: j['id'] as String,
        kind: j['kind'] as String,
        title: j['title'] as String,
        body: (j['body'] as String?) ?? '',
        link: (j['link'] as String?) ?? '',
        createdAt: DateTime.parse(j['created_at'] as String).toUtc(),
        readAt: j['read_at'] == null ? null : DateTime.parse(j['read_at'] as String).toUtc(),
        data: (j['data'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
}
