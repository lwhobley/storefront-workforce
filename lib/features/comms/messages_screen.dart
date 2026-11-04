import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/comms_repository.dart';
import '../../data/models.dart';
import 'comms_providers.dart';
import 'compose.dart';
import 'documents.dart';
import 'inbox_screen.dart';

bool canManageAnnouncements(AppSession s) => s.canVenueWide(Perm.manageWorkers) || s.canVenueWide(Perm.manageSettings);

/// Managers and leads: send messages and alerts, see who read them, and (staff managers)
/// publish announcements and track acknowledgments.
class MessagesScreen extends ConsumerWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider)!;
    final announcements = canManageAnnouncements(session);
    final tabs = [const Tab(text: 'Send'), const Tab(text: 'Sent'), if (announcements) const Tab(text: 'Announcements')];
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              ScreenHeader(
                kicker: session.venue.name,
                title: 'Messages',
                subtitle: isVenueWideSender(session) ? null : 'Message your storefront, or alert the managers.',
              ),
              TabBar(tabs: tabs, isScrollable: MediaQuery.sizeOf(context).width < 420, tabAlignment: MediaQuery.sizeOf(context).width < 420 ? TabAlignment.start : null),
              Expanded(
                child: TabBarView(children: [
                  const _SendTab(),
                  const _SentTab(),
                  if (announcements) const _AnnouncementsAdminTab(),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _page(Widget child) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: SizedBox(width: double.infinity, child: child)),
    );

class _SendTab extends StatelessWidget {
  const _SendTab();

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.l, AppSpace.screen, AppSpace.xl),
        children: [_page(const ComposeForm())],
      );
}

// ---- Sent ----

class _SentTab extends ConsumerWidget {
  const _SentTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sentMessagesProvider);
    final list = async.value;
    if (list == null) {
      return async.hasError ? ErrorNote(async.error!, onRetry: () => ref.invalidate(sentMessagesProvider)) : const Center(child: CircularProgressIndicator());
    }
    final zone = ref.watch(sessionProvider)!.venue.timeZone;
    final time = DateFormat('MMM d, h:mm a');
    return RefreshIndicator(
      onRefresh: () => ref.refresh(sentMessagesProvider.future),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, AppSpace.xl),
        children: [
          if (list.isEmpty) const EmptyNote('Nothing sent yet.'),
          for (final m in list)
            _page(Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.s),
              child: Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                  side: BorderSide(color: m.urgent ? AppColors.bad : AppColors.divider),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.m),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        if (m.urgent) ...[const StatusTag('Urgent', Tone.bad, icon: Icons.priority_high), const SizedBox(width: 6)],
                        Expanded(child: Text('To ${m.audienceLabel}', style: AppText.body.copyWith(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
                      ]),
                      const SizedBox(height: 4),
                      Text([if (!m.mine) 'From ${m.senderName}', time.format(atVenue(m.createdAt, zone))].join(' · '), style: AppText.meta),
                      const SizedBox(height: 8),
                      Text(m.body, style: AppText.body),
                      const SizedBox(height: 10),
                      _ReadBar(read: m.readCount, total: m.recipientCount, verb: 'read'),
                    ],
                  ),
                ),
              ),
            )),
        ],
      ),
    );
  }
}

class _ReadBar extends StatelessWidget {
  const _ReadBar({required this.read, required this.total, required this.verb});

  final int read;
  final int total;
  final String verb;

  @override
  Widget build(BuildContext context) {
    final share = total == 0 ? 0.0 : read / total;
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: share,
              minHeight: 6,
              backgroundColor: AppColors.idleSoft,
              color: share >= 0.9 ? AppColors.good : AppColors.accent,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(total == 0 ? 'No recipients' : '$read of $total $verb', style: AppText.meta.copyWith(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

// ---- Announcements ----

String audienceSummary(AnnouncementAudience a, VenueContext? venue) {
  if (a.isEveryone) return 'Everyone';
  const types = {'regular': 'Regular staff', 'temp': 'Temp staff', 'npo': 'Nonprofit volunteers'};
  final parts = <String>[
    if (a.workerTypes.isNotEmpty) a.workerTypes.map((t) => types[t] ?? t).join(' or '),
    if (a.jobRoles.isNotEmpty) a.jobRoles.map((r) => venue?.roleName(r) ?? r).join(', '),
    if (a.roles.isNotEmpty) a.roles.join(', '),
  ];
  return parts.join(' · ');
}

class _AnnouncementsAdminTab extends ConsumerWidget {
  const _AnnouncementsAdminTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(announcementSummariesProvider);
    final venue = ref.watch(venueProvider).value;
    final list = async.value;
    final zone = ref.watch(sessionProvider)!.venue.timeZone;
    final date = DateFormat('MMM d');
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, AppSpace.xl),
      children: [
        _page(Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () => showModalBottomSheet<void>(context: context, isScrollControlled: true, builder: (_) => const _NewAnnouncementSheet()),
            icon: const Icon(Icons.add),
            label: const Text('New announcement'),
          ),
        )),
        const SizedBox(height: AppSpace.m),
        if (list == null)
          async.hasError ? ErrorNote(async.error!, onRetry: () => ref.invalidate(announcementSummariesProvider)) : const Center(child: CircularProgressIndicator())
        else if (list.isEmpty)
          const EmptyNote('No announcements yet.')
        else
          for (final a in list)
            _page(Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.s),
              child: Card(
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: _AckTracker(announcement: a)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.m),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                          if (a.isPolicy) const StatusTag('Policy', Tone.info, icon: Icons.gavel),
                          if (a.requiresAck && !a.isPolicy) const StatusTag('Acknowledgment', Tone.info),
                          if (a.documentPath != null) const StatusTag('Document', Tone.idle, icon: Icons.attach_file),
                          if (a.expiresAt != null && a.expiresAt!.isBefore((ref.watch(clockProvider).value ?? DateTime.now().toUtc()))) const StatusTag('Expired', Tone.idle),
                          Text(
                            [date.format(atVenue(a.publishedAt, zone)), if (a.createdByName.isNotEmpty) a.createdByName].join(' · '),
                            style: AppText.meta,
                          ),
                        ]),
                        const SizedBox(height: 6),
                        Text(a.title, style: AppText.sectionHeading),
                        const SizedBox(height: 2),
                        Text('For ${audienceSummary(a.audience, venue)} (${a.audienceCount} people)', style: AppText.meta),
                        if (a.requiresAck) ...[
                          const SizedBox(height: 10),
                          _ReadBar(read: a.ackCount, total: a.audienceCount, verb: 'acknowledged'),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            )),
      ],
    );
  }
}

/// Who has acknowledged an announcement and who has not, with a reminder button.
class _AckTracker extends ConsumerStatefulWidget {
  const _AckTracker({required this.announcement});

  final Announcement announcement;

  @override
  ConsumerState<_AckTracker> createState() => _AckTrackerState();
}

class _AckTrackerState extends ConsumerState<_AckTracker> {
  AckReport? _report;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ref.read(commsRepoProvider).ackReport(ref.read(sessionProvider)!, widget.announcement.id);
      if (mounted) setState(() => _report = r);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _remind() async {
    setState(() => _busy = true);
    try {
      final n = await ref.read(commsRepoProvider).remindUnacknowledged(ref.read(sessionProvider)!, widget.announcement.id);
      if (mounted) {
        showMessage(context, n == 0 ? 'Everyone left was already reminded in the last hour.' : 'Reminded $n ${n == 1 ? 'person' : 'people'}.');
      }
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.announcement;
    final r = _report;
    final zone = ref.watch(sessionProvider)!.venue.timeZone;
    final time = DateFormat('MMM d, h:mm a');
    final pending = r == null ? 0 : r.people.length - r.acked;
    return ListView(
      padding: const EdgeInsets.only(bottom: AppSpace.xl),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
          child: AnnouncementCard(announcement: a, preview: true),
        ),
        if (_error != null) ErrorNote(_error!, onRetry: _load),
        if (r == null && _error == null) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        if (r != null && !a.requiresAck) EmptyNote('This announcement does not ask for acknowledgment. It went to ${r.people.length} people.'),
        if (r != null && a.requiresAck) ...[
          SectionHeading(
            '${r.acked} of ${r.people.length} acknowledged',
            trailing: pending == 0
                ? null
                : FilledButton.tonalIcon(
                    onPressed: _busy ? null : _remind,
                    icon: const Icon(Icons.notifications_active_outlined),
                    label: Text('Remind $pending'),
                  ),
          ),
          for (final p in r.people)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
              leading: Icon(p.acked ? Icons.check_circle : Icons.radio_button_unchecked, color: p.acked ? AppColors.good : AppColors.idle),
              title: Text(p.name),
              subtitle: Text([
                if (p.employeeNumber.isNotEmpty) p.employeeNumber,
                if (p.workerType == 'temp') 'Temp',
                if (p.workerType == 'npo') 'Nonprofit',
                if (p.acked) 'Acknowledged ${time.format(atVenue(p.ackedAt!, zone))}' else 'Not yet',
                if (p.typedName.isNotEmpty) 'Signed "${p.typedName}"',
              ].join(' · ')),
            ),
        ],
      ],
    );
  }
}

/// Write and publish an announcement.
class _NewAnnouncementSheet extends ConsumerStatefulWidget {
  const _NewAnnouncementSheet();

  @override
  ConsumerState<_NewAnnouncementSheet> createState() => _NewAnnouncementSheetState();
}

class _NewAnnouncementSheetState extends ConsumerState<_NewAnnouncementSheet> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  final Set<String> _types = {};
  final Set<String> _jobs = {};
  bool _requiresAck = false;
  bool _policy = false;
  String? _docPath;
  String? _docName;
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _attach() async {
    final session = ref.read(sessionProvider)!;
    try {
      final picked = await pickDocument();
      if (picked == null) return;
      setState(() => _busy = true);
      final path = await ref.read(commsRepoProvider).uploadDocument(session, picked.name, picked.bytes, picked.mimeType);
      if (mounted) {
        setState(() {
          _docPath = path;
          _docName = picked.name;
        });
      }
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publish() async {
    if (_title.text.trim().isEmpty) return showMessage(context, 'Give it a title.');
    setState(() => _busy = true);
    try {
      final a = await ref.read(commsRepoProvider).publishAnnouncement(
            ref.read(sessionProvider)!,
            AnnouncementDraft(
              title: _title.text.trim(),
              body: _body.text.trim(),
              audience: AnnouncementAudience(workerTypes: _types.toList(), jobRoles: _jobs.toList()),
              requiresAck: _requiresAck || _policy,
              isPolicy: _policy,
              documentPath: _docPath,
            ),
          );
      if (!mounted) return;
      ref.invalidate(announcementSummariesProvider);
      Navigator.of(context).pop();
      showMessage(context, 'Published to ${a.audienceCount} people.');
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(venueProvider).value;
    final roles = venue?.jobRoles ?? const <JobRole>[];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppSpace.screen, 0, AppSpace.screen, AppSpace.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('New announcement', style: AppText.sectionHeading),
            const SizedBox(height: 12),
            TextField(controller: _title, maxLength: 200, decoration: const InputDecoration(labelText: 'Title')),
            TextField(controller: _body, minLines: 3, maxLines: 8, maxLength: 5000, decoration: const InputDecoration(labelText: 'Details', alignLabelWithHint: true)),
            const SizedBox(height: 4),
            Text('Who it is for (leave all off for everyone)', style: AppText.meta.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final (code, label) in const [('regular', 'Regular staff'), ('temp', 'Temp staff'), ('npo', 'Nonprofit volunteers')])
                FilterChip(
                  label: Text(label),
                  selected: _types.contains(code),
                  onSelected: (v) => setState(() => v ? _types.add(code) : _types.remove(code)),
                ),
            ]),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final r in roles)
                FilterChip(
                  label: Text(r.name),
                  selected: _jobs.contains(r.code),
                  onSelected: (v) => setState(() => v ? _jobs.add(r.code) : _jobs.remove(r.code)),
                ),
            ]),
            const SizedBox(height: 4),
            Text(
              _types.isEmpty && _jobs.isEmpty
                  ? 'Goes to everyone.'
                  : 'Goes to ${audienceSummary(AnnouncementAudience(workerTypes: _types.toList(), jobRoles: _jobs.toList()), venue)}.',
              style: AppText.meta,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Ask people to acknowledge'),
              subtitle: const Text('Each person taps "I have read this". You can see who has and remind the rest.'),
              value: _requiresAck || _policy,
              onChanged: _policy ? null : (v) => setState(() => _requiresAck = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('This is a policy'),
              subtitle: const Text('People sign by typing their full name. Also emailed to people who turned on email.'),
              value: _policy,
              onChanged: (v) => setState(() => _policy = v),
            ),
            const SizedBox(height: 4),
            Row(children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _attach,
                icon: const Icon(Icons.attach_file),
                label: Text(_docPath == null ? 'Attach a document' : 'Replace document'),
              ),
              const SizedBox(width: 10),
              if (_docName != null) Expanded(child: Text(_docName!, style: AppText.meta, overflow: TextOverflow.ellipsis)),
            ]),
            const SizedBox(height: 16),
            FilledButton.icon(onPressed: _busy ? null : _publish, icon: const Icon(Icons.campaign_outlined), label: const Text('Publish')),
          ],
        ),
      ),
    );
  }
}
