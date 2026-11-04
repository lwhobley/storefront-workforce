import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/app_notification.dart';
import '../../data/comms_repository.dart';

final commsRepoProvider = Provider<CommsRepository>((ref) => ref.watch(repositoryProvider) as CommsRepository);

/// Counts up whenever a message, announcement, or notification for the signed-in person
/// arrives or changes (Supabase realtime, or the demo's in-memory stream), and once a
/// minute in case realtime dropped. The lists below reload on every tick.
final commsTickProvider = StreamProvider<int>((ref) {
  final session = ref.watch(sessionProvider);
  if (session == null || session.isKiosk) return Stream.value(0);
  final controller = StreamController<int>();
  var n = 0;
  controller.add(n);
  Timer? debounce;
  void bump() {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 300), () {
      if (!controller.isClosed) controller.add(++n);
    });
  }

  final sub = ref.read(commsRepoProvider).commsChanges(session).listen((_) => bump());
  final poll = Timer.periodic(const Duration(minutes: 1), (_) => bump());
  ref.onDispose(() {
    debounce?.cancel();
    poll.cancel();
    sub.cancel();
    controller.close();
  });
  return controller.stream;
});

final myMessagesProvider = FutureProvider<List<CommsMessage>>((ref) async {
  ref.watch(commsTickProvider);
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  return ref.read(commsRepoProvider).myMessages(session);
});

final myAnnouncementsProvider = FutureProvider<List<Announcement>>((ref) async {
  ref.watch(commsTickProvider);
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  return ref.read(commsRepoProvider).myAnnouncements(session);
});

final myNotificationsProvider = FutureProvider<List<AppNotification>>((ref) async {
  ref.watch(commsTickProvider);
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  return ref.read(commsRepoProvider).myNotifications(session);
});

final sentMessagesProvider = FutureProvider.autoDispose<List<CommsMessage>>((ref) async {
  ref.watch(commsTickProvider);
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  return ref.read(commsRepoProvider).sentMessages(session);
});

final announcementSummariesProvider = FutureProvider.autoDispose<List<Announcement>>((ref) async {
  ref.watch(commsTickProvider);
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  return ref.read(commsRepoProvider).announcementSummaries(session);
});

/// Unread counts for the inbox tabs and the nav badge.
class InboxCounts {
  const InboxCounts({this.messages = 0, this.announcements = 0, this.notifications = 0});

  /// Unread messages.
  final int messages;

  /// Announcements to acknowledge, plus new ones that need no acknowledgment.
  final int announcements;

  /// Unread notifications other than messages and announcements.
  final int notifications;

  int get total => messages + announcements + notifications;
}

final inboxCountsProvider = Provider<InboxCounts>((ref) {
  final messages = ref.watch(myMessagesProvider).value ?? const [];
  final announcements = ref.watch(myAnnouncementsProvider).value ?? const [];
  final notifications = ref.watch(myNotificationsProvider).value ?? const [];
  final needAck = {for (final a in announcements) if (a.needsMyAck) a.id};
  final current = {for (final a in announcements) a.id};
  final newInfo = {
    for (final n in notifications)
      if (n.isAnnouncement && !n.isRead && current.contains(n.data['announcement_id']) && !needAck.contains(n.data['announcement_id']))
        n.data['announcement_id'] as String,
  };
  return InboxCounts(
    messages: messages.where((m) => !m.isRead).length,
    announcements: needAck.length + newInfo.length,
    notifications: notifications.where((n) => !n.isRead && !n.isMessage && !n.isAnnouncement).length,
  );
});

/// Everything new in the inbox, for a badge on the Inbox nav item.
final unreadCountProvider = Provider<int>((ref) => ref.watch(inboxCountsProvider).total);
