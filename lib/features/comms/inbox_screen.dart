import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/app_notification.dart';
import '../../data/comms_repository.dart';
import '../../data/models.dart';
import 'comms_providers.dart';
import 'comms_strings.dart';
import 'documents.dart';

/// Messages, announcements to acknowledge, and notifications, for everyone. Updates live.
class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void initState() {
    super.initState();
    // Open on what needs attention: announcements to acknowledge, else messages.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final counts = ref.read(inboxCountsProvider);
      if (counts.messages == 0 && counts.announcements > 0) _tabs.index = 1;
      if (counts.messages == 0 && counts.announcements == 0 && counts.notifications > 0) _tabs.index = 2;
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final session = ref.watch(sessionProvider)!;
    final counts = ref.watch(inboxCountsProvider);
    Widget tab(String label, int n) => Tab(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
            if (n > 0) ...[const SizedBox(width: 6), Badge(label: Text('$n'))],
          ]),
        );
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            ScreenHeader(
              kicker: session.venue.name,
              title: t.inbox,
              actions: [
                IconButton(
                  tooltip: t.notificationSettings,
                  icon: const Icon(Icons.tune),
                  onPressed: () => showNotificationSettings(context),
                ),
              ],
            ),
            TabBar(
              controller: _tabs,
              isScrollable: MediaQuery.sizeOf(context).width < 420,
              tabAlignment: MediaQuery.sizeOf(context).width < 420 ? TabAlignment.start : null,
              tabs: [
                tab(t.messagesTab, counts.messages),
                tab(t.announcementsTab, counts.announcements),
                tab(t.notificationsTab, counts.notifications),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: const [_MessagesTab(), _AnnouncementsTab(), _NotificationsTab()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

DateTime _local(WidgetRef ref, DateTime utc) => atVenue(utc, ref.read(sessionProvider)!.venue.timeZone);

Widget _centered(Widget child) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: SizedBox(width: double.infinity, child: child)),
    );

// ---- Messages ----

class _MessagesTab extends ConsumerStatefulWidget {
  const _MessagesTab();

  @override
  ConsumerState<_MessagesTab> createState() => _MessagesTabState();
}

class _MessagesTabState extends ConsumerState<_MessagesTab> {
  /// Messages that were new when this screen showed them; they keep their "New" label
  /// until the screen closes.
  final Set<String> _newHere = {};
  final Set<String> _marking = {};

  void _markShown(List<CommsMessage> messages) {
    final unread = [for (final m in messages) if (!m.isRead && !_marking.contains(m.id)) m.id];
    if (unread.isEmpty) return;
    _newHere.addAll(unread);
    _marking.addAll(unread);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final session = ref.read(sessionProvider);
      if (session == null) return;
      try {
        await ref.read(commsRepoProvider).markMessagesRead(session, unread);
        ref.invalidate(myMessagesProvider);
        ref.invalidate(myNotificationsProvider);
      } catch (_) {
        _marking.removeAll(unread);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final async = ref.watch(myMessagesProvider);
    final messages = async.value;
    if (messages == null) {
      return async.hasError
          ? ErrorNote(async.error!, onRetry: () => ref.invalidate(myMessagesProvider))
          : const Center(child: CircularProgressIndicator());
    }
    _markShown(messages);
    final now = _local(ref, (ref.watch(clockProvider).value ?? DateTime.now().toUtc()));
    return RefreshIndicator(
      onRefresh: () => ref.refresh(myMessagesProvider.future),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, AppSpace.xl),
        children: [
          if (messages.isEmpty) EmptyNote(t.noMessages),
          for (final m in messages)
            _centered(Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.s),
              child: _MessageCard(message: m, isNew: _newHere.contains(m.id) || !m.isRead, now: now),
            )),
        ],
      ),
    );
  }
}

class _MessageCard extends ConsumerWidget {
  const _MessageCard({required this.message, required this.isNew, required this.now});

  final CommsMessage message;
  final bool isNew;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final m = message;
    final card = Card(
      color: m.urgent ? AppColors.badSoft : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: m.urgent ? AppColors.bad : AppColors.divider, width: m.urgent ? 1.5 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (m.urgent) ...[StatusTag(t.urgent, Tone.bad, icon: Icons.priority_high), const SizedBox(width: 6)],
                if (isNew) ...[StatusTag(t.newLabel, Tone.info), const SizedBox(width: 6)],
                Expanded(
                  child: Text(t.fromName(m.senderName),
                      style: AppText.body.copyWith(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
                ),
                Text(t.ago(_local(ref, m.createdAt), now), style: AppText.meta),
              ],
            ),
            const SizedBox(height: 6),
            Text(m.body, style: AppText.body.copyWith(fontSize: 16, fontWeight: m.urgent ? FontWeight.w600 : null)),
            if (m.audienceLabel.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(t.toLabel(m.audienceLabel), style: AppText.meta),
            ],
          ],
        ),
      ),
    );
    return Semantics(label: m.urgent ? t.urgent : null, child: card);
  }
}

// ---- Announcements ----

class _AnnouncementsTab extends ConsumerStatefulWidget {
  const _AnnouncementsTab();

  @override
  ConsumerState<_AnnouncementsTab> createState() => _AnnouncementsTabState();
}

class _AnnouncementsTabState extends ConsumerState<_AnnouncementsTab> {
  bool _marked = false;

  /// Seeing an announcement that needs no acknowledgment counts as reading it.
  void _markSeen(List<Announcement> list) {
    if (_marked) return;
    final notifications = ref.read(myNotificationsProvider).value;
    if (notifications == null) return;
    final info = {for (final a in list) if (!a.requiresAck) a.id};
    final ids = [
      for (final n in notifications)
        if (n.isAnnouncement && !n.isRead && info.contains(n.data['announcement_id'])) n.id,
    ];
    _marked = true;
    if (ids.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final session = ref.read(sessionProvider);
      if (session == null) return;
      try {
        await ref.read(commsRepoProvider).markNotificationsRead(session, ids: ids);
        ref.invalidate(myNotificationsProvider);
      } catch (_) {
        _marked = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final async = ref.watch(myAnnouncementsProvider);
    final list = async.value;
    if (list == null) {
      return async.hasError
          ? ErrorNote(async.error!, onRetry: () => ref.invalidate(myAnnouncementsProvider))
          : const Center(child: CircularProgressIndicator());
    }
    ref.watch(myNotificationsProvider);
    _markSeen(list);
    return RefreshIndicator(
      onRefresh: () => ref.refresh(myAnnouncementsProvider.future),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, AppSpace.xl),
        children: [
          if (list.isEmpty) EmptyNote(t.noAnnouncements),
          for (final a in list) _centered(Padding(padding: const EdgeInsets.only(bottom: AppSpace.s), child: AnnouncementCard(announcement: a))),
        ],
      ),
    );
  }
}

/// One announcement, with its document and the acknowledgment button.
class AnnouncementCard extends ConsumerStatefulWidget {
  const AnnouncementCard({super.key, required this.announcement, this.preview = false});

  final Announcement announcement;

  /// Manager preview: no acknowledgment button.
  final bool preview;

  @override
  ConsumerState<AnnouncementCard> createState() => _AnnouncementCardState();
}

class _AnnouncementCardState extends ConsumerState<AnnouncementCard> {
  bool _busy = false;

  Future<void> _open(T t) async {
    final path = widget.announcement.documentPath;
    if (path == null) return;
    try {
      final session = ref.read(sessionProvider)!;
      final file = await ref.read(commsRepoProvider).openDocument(session, path);
      final opened = await openDocumentFile(file);
      if (!opened && mounted) showMessage(context, t.linkCopied);
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  Future<void> _ack(T t) async {
    final a = widget.announcement;
    var name = '';
    if (a.isPolicy) {
      final typed = await _askName(context, t, a.title);
      if (typed == null) return;
      name = typed;
    }
    setState(() => _busy = true);
    try {
      final session = ref.read(sessionProvider)!;
      await ref.read(commsRepoProvider).acknowledgeAnnouncement(session, a.id, typedName: name);
      ref.invalidate(myAnnouncementsProvider);
      ref.invalidate(myNotificationsProvider);
      if (mounted) showMessage(context, t.thanks);
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final a = widget.announcement;
    final needs = a.needsMyAck && !widget.preview;
    final zone = ref.watch(sessionProvider)!.venue.timeZone;
    final now = atVenue((ref.watch(clockProvider).value ?? DateTime.now().toUtc()), zone);
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: needs ? AppColors.warn : AppColors.divider, width: needs ? 1.5 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (a.isPolicy) StatusTag(t.policy, Tone.info, icon: Icons.gavel),
                if (needs) StatusTag(t.needsAck, Tone.warn, icon: Icons.edit_note),
                Text(t.ago(atVenue(a.publishedAt, zone), now), style: AppText.meta),
                if (a.expiresAt != null) Text('· ${t.expires(t.shortDate(atVenue(a.expiresAt!, zone)))}', style: AppText.meta),
              ],
            ),
            const SizedBox(height: 8),
            Text(a.title, style: AppText.sectionHeading),
            if (a.body.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(a.body, style: AppText.body),
            ],
            if (a.createdByName.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('— ${a.createdByName}', style: AppText.meta),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (a.documentPath != null)
                  OutlinedButton.icon(onPressed: () => _open(t), icon: const Icon(Icons.description_outlined), label: Text(t.openDocument)),
                if (needs)
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _ack(t),
                    icon: const Icon(Icons.check),
                    label: Text(a.isPolicy ? t.signPolicy : t.iHaveRead),
                  ),
                if (a.requiresAck && a.ackedAt != null && !widget.preview)
                  StatusTag(
                    [t.acknowledgedOn(t.shortDate(atVenue(a.ackedAt!, zone))), if (a.typedName.isNotEmpty) t.signedAs(a.typedName)].join(' · '),
                    Tone.good,
                    icon: Icons.verified_outlined,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<String?> _askName(BuildContext context, T t, String title) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.signNote, style: AppText.body),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(labelText: t.typeFullName),
                onChanged: (_) => setState(() {}),
                onSubmitted: (v) {
                  if (v.trim().length >= 2) Navigator.pop(context, v.trim());
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(t.cancel)),
          FilledButton(
            onPressed: controller.text.trim().length < 2 ? null : () => Navigator.pop(context, controller.text.trim()),
            child: Text(t.sign),
          ),
        ],
      ),
    ),
  );
}

// ---- Notifications ----

IconData _kindIcon(String kind) => switch (kind) {
      'call_time' => Icons.schedule,
      'missed_clock_in' => Icons.alarm,
      'cert_expiring' => Icons.badge_outlined,
      'shift_offered' || 'request_decided' || 'schedule_changed' => Icons.swap_horiz,
      'onboarding_reminder' => Icons.task_alt,
      _ => Icons.notifications_none,
    };

class _NotificationsTab extends ConsumerWidget {
  const _NotificationsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final async = ref.watch(myNotificationsProvider);
    final all = async.value;
    if (all == null) {
      return async.hasError
          ? ErrorNote(async.error!, onRetry: () => ref.invalidate(myNotificationsProvider))
          : const Center(child: CircularProgressIndicator());
    }
    final list = [for (final n in all) if (!n.isMessage && !n.isAnnouncement) n];
    final unread = list.where((n) => !n.isRead).toList();
    final now = _local(ref, (ref.watch(clockProvider).value ?? DateTime.now().toUtc()));
    final session = ref.watch(sessionProvider)!;

    Future<void> markAll() async {
      try {
        await ref.read(commsRepoProvider).markNotificationsRead(session, ids: [for (final n in unread) n.id]);
        ref.invalidate(myNotificationsProvider);
      } on AppFailure catch (e) {
        if (context.mounted) showMessage(context, e.message);
      }
    }

    Future<void> open(AppNotification n) async {
      if (!n.isRead) {
        try {
          await ref.read(commsRepoProvider).markNotificationsRead(session, ids: [n.id]);
          ref.invalidate(myNotificationsProvider);
        } on AppFailure catch (_) {
          // Opening still works offline.
        }
      }
      if (context.mounted && n.link.startsWith('/') && n.link != '/inbox') context.go(n.link);
    }

    return RefreshIndicator(
      onRefresh: () => ref.refresh(myNotificationsProvider.future),
      child: ListView(
        padding: const EdgeInsets.only(top: AppSpace.s, bottom: AppSpace.xl),
        children: [
          if (unread.isNotEmpty)
            _centered(Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.m),
                child: TextButton.icon(onPressed: markAll, icon: const Icon(Icons.done_all), label: Text(t.markAllRead)),
              ),
            )),
          if (list.isEmpty) EmptyNote(t.noNotifications),
          for (final n in list)
            _centered(ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
              leading: CircleAvatar(
                backgroundColor: n.isRead ? AppColors.idleSoft : toneSoft(n.kind == 'missed_clock_in' ? Tone.bad : Tone.info, context),
                foregroundColor: n.isRead ? AppColors.idle : toneColor(n.kind == 'missed_clock_in' ? Tone.bad : Tone.info, context),
                child: Icon(_kindIcon(n.kind)),
              ),
              title: Text(n.title, style: TextStyle(fontWeight: n.isRead ? FontWeight.w500 : FontWeight.w700)),
              subtitle: Text([if (n.body.isNotEmpty) n.body, t.ago(_local(ref, n.createdAt), now)].join('\n'), maxLines: 4, overflow: TextOverflow.ellipsis),
              isThreeLine: n.body.isNotEmpty,
              trailing: n.isRead
                  ? (n.link.startsWith('/') && n.link != '/inbox' ? const Icon(Icons.chevron_right) : null)
                  : Semantics(label: t.newLabel, child: const Icon(Icons.circle, size: 10, color: AppColors.accent)),
              onTap: () => open(n),
            )),
        ],
      ),
    );
  }
}

// ---- Settings ----

/// Push and email settings, and quiet hours.
Future<void> showNotificationSettings(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _SettingsSheet(),
    );

class _SettingsSheet extends ConsumerStatefulWidget {
  const _SettingsSheet();

  @override
  ConsumerState<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends ConsumerState<_SettingsSheet> {
  NotificationPrefs? _prefs;
  final _email = TextEditingController();
  bool _busy = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await ref.read(commsRepoProvider).notificationPrefs(ref.read(sessionProvider)!);
      if (!mounted) return;
      setState(() {
        _prefs = p;
        _email.text = p.emailAddress;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<String?> _pickTime(String? current) async {
    final parts = (current ?? '22:00').split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
    );
    if (picked == null) return null;
    return '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
  }

  String _label(String hm) {
    final parts = hm.split(':');
    final h = int.parse(parts[0]);
    return '${h % 12 == 0 ? 12 : h % 12}:${parts[1]} ${h < 12 ? 'AM' : 'PM'}';
  }

  Future<void> _save(T t) async {
    final p = _prefs!;
    setState(() => _busy = true);
    try {
      final saved = await ref
          .read(commsRepoProvider)
          .saveNotificationPrefs(ref.read(sessionProvider)!, p.hasStaffRecord ? p : p.copyWith(emailAddress: _email.text.trim()));
      if (!mounted) return;
      setState(() => _prefs = saved);
      showMessage(context, t.saved);
      Navigator.of(context).pop();
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final p = _prefs;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppSpace.screen, 0, AppSpace.screen, AppSpace.xl),
        child: p == null
            ? (_error != null ? ErrorNote(_error!) : const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(t.notificationSettings, style: AppText.sectionHeading),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t.pushOnPhone),
                    subtitle: Text(t.pushHelp),
                    value: p.push,
                    onChanged: (v) => setState(() => _prefs = p.copyWith(push: v)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t.emailCopies),
                    subtitle: Text([t.emailHelp, if (p.hasStaffRecord) p.emailAddress.isEmpty ? t.noEmailOnFile : p.emailAddress].join('\n')),
                    value: p.email,
                    onChanged: (v) => setState(() => _prefs = p.copyWith(email: v)),
                  ),
                  if (!p.hasStaffRecord)
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(labelText: t.emailAddress),
                    ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t.quietHours),
                    subtitle: Text(t.quietHelp),
                    value: p.hasQuietHours,
                    onChanged: (v) => setState(() => _prefs = v ? p.withQuietHours('22:00', '07:00') : p.withQuietHours(null, null)),
                  ),
                  if (p.hasQuietHours)
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              final v = await _pickTime(p.quietStart);
                              if (v != null) setState(() => _prefs = _prefs!.withQuietHours(v, _prefs!.quietEnd));
                            },
                            child: Text('${t.quietFrom} ${_label(p.quietStart!)}'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () async {
                              final v = await _pickTime(p.quietEnd);
                              if (v != null) setState(() => _prefs = _prefs!.withQuietHours(_prefs!.quietStart, v));
                            },
                            child: Text('${t.quietTo} ${_label(p.quietEnd!)}'),
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _busy ? null : () => _save(t), child: Text(t.save)),
                ],
              ),
      ),
    );
  }
}
