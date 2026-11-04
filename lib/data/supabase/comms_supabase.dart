part of '../supabase_repository.dart';

/// Supabase implementation of [CommsRepository]. Reads and writes go through the
/// functions in 0013_comms.sql, which check who may send and who may see what.
mixin _SupabaseComms on _SupabaseCore implements CommsRepository {
  static Map<String, dynamic> _row(Object? r) => (r as Map).cast<String, dynamic>();
  static List<Map<String, dynamic>> _rows(Object? data) => [for (final r in (data as List? ?? const [])) _row(r)];

  // ---- Messages ----

  @override
  Future<List<CommsMessage>> myMessages(AppSession session) => _guard(() async {
        final data = await client.rpc('my_messages', params: {'p_limit': 100});
        return [for (final r in _rows(data)) CommsMessage.fromJson(r)];
      });

  @override
  Future<List<CommsMessage>> sentMessages(AppSession session) => _guard(() async {
        final data = await client.rpc('sent_messages', params: {'p_venue': session.venue.id, 'p_limit': 100});
        return [for (final r in _rows(data)) CommsMessage.fromJson(r)];
      });

  @override
  Future<CommsMessage> sendMessage(AppSession session, MessageDraft draft) => _guard(() async {
        final data = await client.rpc('send_message', params: {'p': draft.toJson(session.venue.id)});
        return CommsMessage.fromJson(_row(data));
      });

  @override
  Future<void> markMessagesRead(AppSession session, List<String> ids) => _guard(() async {
        if (ids.isEmpty) return;
        await client.rpc('mark_messages_read', params: {'p_ids': ids});
      });

  // ---- Announcements ----

  @override
  Future<List<Announcement>> myAnnouncements(AppSession session) => _guard(() async {
        final data = await client.rpc('my_announcements');
        return [for (final r in _rows(data)) Announcement.fromJson(r)];
      });

  @override
  Future<List<Announcement>> announcementSummaries(AppSession session) => _guard(() async {
        final data = await client.rpc('announcement_summaries', params: {'p_venue': session.venue.id});
        return [for (final r in _rows(data)) Announcement.fromJson(r)];
      });

  @override
  Future<Announcement> publishAnnouncement(AppSession session, AnnouncementDraft draft) => _guard(() async {
        final data = await client.rpc('publish_announcement', params: {'p': draft.toJson(session.venue.id)});
        return Announcement.fromJson(_row(data));
      });

  @override
  Future<void> acknowledgeAnnouncement(AppSession session, String id, {String typedName = ''}) =>
      _guard(() => client.rpc('acknowledge_announcement', params: {'p_id': id, 'p_typed_name': typedName}));

  @override
  Future<AckReport> ackReport(AppSession session, String id) => _guard(() async {
        final data = _row(await client.rpc('announcement_ack_report', params: {'p_id': id}));
        return AckReport(
          announcement: Announcement.fromJson(_row(data['announcement'])),
          people: [for (final p in _rows(data['people'])) AckPerson.fromJson(p)],
        );
      });

  @override
  Future<int> remindUnacknowledged(AppSession session, String id) =>
      _guard(() async => ((await client.rpc('remind_unacknowledged', params: {'p_id': id})) as num).toInt());

  @override
  Future<String> uploadDocument(AppSession session, String fileName, Uint8List bytes, String mimeType) => _guard(() async {
        if (bytes.length > 10 * 1024 * 1024) throw const AppFailure('Documents are limited to 10 MB');
        final safe = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
        final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
        final path = '${session.venue.id}/announcements/$stamp-$safe';
        await client.storage.from('documents').uploadBinary(path, bytes, fileOptions: FileOptions(contentType: mimeType));
        return path;
      });

  @override
  Future<DocumentFile> openDocument(AppSession session, String path) => _guard(() async {
        final url = await client.storage.from('documents').createSignedUrl(path, 3600);
        final name = path.split('/').last.replaceFirst(RegExp(r'^\d+-'), '');
        return DocumentFile(name: name, mimeType: name.toLowerCase().endsWith('.pdf') ? 'application/pdf' : 'image/*', url: url);
      });

  // ---- Notifications ----

  @override
  Future<List<AppNotification>> myNotifications(AppSession session, {int limit = 100}) => _guard(() async {
        final rows = await client
            .from('notifications')
            .select('id, kind, title, body, link, data, created_at, read_at')
            .eq('user_id', session.userId)
            .order('created_at', ascending: false)
            .limit(limit);
        return [for (final r in rows) AppNotification.fromJson(r)];
      });

  @override
  Future<void> markNotificationsRead(AppSession session, {List<String>? ids}) =>
      _guard(() => client.rpc('mark_notifications_read', params: {'p_ids': ids}));

  @override
  Stream<void> commsChanges(AppSession session) {
    late final StreamController<void> controller;
    RealtimeChannel? channel;
    controller = StreamController<void>(
      onListen: () {
        channel = client
            .channel('comms-${session.userId}')
            .onPostgresChanges(
              event: PostgresChangeEvent.all,
              schema: 'public',
              table: 'notifications',
              filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: session.userId),
              callback: (_) => controller.add(null),
            )
            .onPostgresChanges(
              event: PostgresChangeEvent.insert,
              schema: 'public',
              table: 'messages',
              filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'venue_id', value: session.venue.id),
              callback: (_) => controller.add(null),
            )
            .subscribe();
      },
      onCancel: () async {
        if (channel != null) await client.removeChannel(channel!);
      },
    );
    return controller.stream;
  }

  // ---- Delivery preferences and devices ----

  @override
  Future<NotificationPrefs> notificationPrefs(AppSession session) =>
      _guard(() async => NotificationPrefs.fromJson(_row(await client.rpc('my_notification_prefs'))));

  @override
  Future<NotificationPrefs> saveNotificationPrefs(AppSession session, NotificationPrefs prefs) =>
      _guard(() async => NotificationPrefs.fromJson(_row(await client.rpc('set_notification_prefs', params: {'p': prefs.toJson()}))));

  @override
  Future<void> registerPushToken(AppSession session, String token, String platform) =>
      _guard(() => client.rpc('register_push_token', params: {'p_token': token, 'p_platform': platform}));

  @override
  Future<void> removePushToken(AppSession session, String token) =>
      _guard(() => client.rpc('remove_push_token', params: {'p_token': token}));
}
