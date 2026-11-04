import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/comms_repository.dart';
import '../../data/models.dart';
import 'comms_providers.dart';

/// Quick messages for a busy concourse: (chip label, message text).
const messageTemplates = [
  ('Needs a runner', 'needs a runner.'),
  ('Needs a cashier', 'needs a cashier.'),
  ('Break coverage', 'needs break coverage.'),
  ('Restock help', 'needs help restocking.'),
  ('Close early', 'close early: finish the line you have, then close up.'),
];

String templateText(String text, {String? storefrontName}) {
  if (storefrontName != null) return '$storefrontName: $text';
  return text[0].toUpperCase() + text.substring(1);
}

bool _runsEvents(RoleGrant g) => g.permissions.contains(Perm.viewLive) || g.permissions.contains(Perm.manageSchedule);

/// Venue-wide managers can message everyone; others only their area.
bool isVenueWideSender(AppSession s) => s.canVenueWide(Perm.viewLive) || s.canVenueWide(Perm.manageSchedule);

/// Storefronts the person can message (their view_live / manage_schedule scope).
List<Storefront> storefrontsToMessage(AppSession s, VenueContext venue) {
  final out = <Storefront>[];
  for (final f in venue.storefronts) {
    if (s.grants.any((g) =>
        _runsEvents(g) &&
        (g.scopeType == 'venue' ||
            (g.scopeType == 'storefront' && g.scopeId == f.id) ||
            (g.scopeType == 'level' && g.scopeId == f.levelId)))) {
      out.add(f);
    }
  }
  return out..sort((a, b) => a.code.compareTo(b.code));
}

List<VenueLevel> levelsToMessage(AppSession s, VenueContext venue) => [
      for (final l in venue.levels)
        if (s.grants.any((g) => _runsEvents(g) && (g.scopeType == 'venue' || (g.scopeType == 'level' && g.scopeId == l.id)))) l,
    ];

String audienceName(MessageAudience a) => switch (a) {
      MessageAudience.everyone => 'Everyone',
      MessageAudience.managers => 'Managers and leads',
      MessageAudience.level => 'A level',
      MessageAudience.storefront => 'A storefront',
      MessageAudience.worker => 'One person',
    };

/// Write and send a message: audience, quick templates, urgent, text.
class ComposeForm extends ConsumerStatefulWidget {
  const ComposeForm({super.key, this.initialAudience, this.initialTargetId, this.eventId, this.onSent});

  final MessageAudience? initialAudience;
  final String? initialTargetId;

  /// For storefront and level messages: the event whose crew gets it. Defaults to the
  /// current event.
  final String? eventId;
  final ValueChanged<CommsMessage>? onSent;

  @override
  ConsumerState<ComposeForm> createState() => _ComposeFormState();
}

class _ComposeFormState extends ConsumerState<ComposeForm> {
  late MessageAudience _audience;
  String? _targetId;
  bool _urgent = false;
  bool _busy = false;
  final _body = TextEditingController();

  @override
  void initState() {
    super.initState();
    final session = ref.read(sessionProvider)!;
    _audience = widget.initialAudience ?? (isVenueWideSender(session) ? MessageAudience.everyone : MessageAudience.managers);
    _targetId = widget.initialTargetId;
  }

  @override
  void dispose() {
    _body.dispose();
    super.dispose();
  }

  Future<void> _send(AppSession session, Event? event) async {
    final text = _body.text.trim();
    if (text.isEmpty) return showMessage(context, 'Write a message first.');
    final needsTarget = _audience == MessageAudience.level || _audience == MessageAudience.storefront || _audience == MessageAudience.worker;
    if (needsTarget && _targetId == null) return showMessage(context, 'Choose who gets it.');
    setState(() => _busy = true);
    try {
      final sent = await ref.read(commsRepoProvider).sendMessage(
            session,
            MessageDraft(
              audience: _audience,
              audienceId: needsTarget ? _targetId : null,
              eventId: _audience == MessageAudience.level || _audience == MessageAudience.storefront ? event?.id : null,
              body: text,
              urgent: _urgent,
            ),
          );
      if (!mounted) return;
      showMessage(context, sent.recipientCount == 1 ? 'Sent to 1 person.' : 'Sent to ${sent.recipientCount} people.');
      _body.clear();
      setState(() => _urgent = false);
      ref.invalidate(sentMessagesProvider);
      widget.onSent?.call(sent);
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider)!;
    final venue = ref.watch(venueProvider).value;
    final events = ref.watch(eventsProvider).value ?? const <Event>[];
    final current = ref.watch(currentEventProvider);
    final event = widget.eventId == null ? current : events.where((e) => e.id == widget.eventId).firstOrNull ?? current;
    if (venue == null) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));

    final venueWide = isVenueWideSender(session);
    final levels = levelsToMessage(session, venue);
    final storefronts = storefrontsToMessage(session, venue);
    final audiences = [
      if (venueWide) MessageAudience.everyone,
      MessageAudience.managers,
      if (levels.isNotEmpty) MessageAudience.level,
      if (storefronts.isNotEmpty) MessageAudience.storefront,
      MessageAudience.worker,
    ];
    if (!audiences.contains(_audience)) _audience = audiences.first;
    final sfName = _audience == MessageAudience.storefront ? venue.storefront(_targetId ?? '')?.name : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('To', style: AppText.meta.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final a in audiences)
              ChoiceChip(
                label: Text(audienceName(a)),
                selected: _audience == a,
                onSelected: (_) => setState(() {
                  if (_audience != a) _targetId = null;
                  _audience = a;
                }),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_audience == MessageAudience.level)
          DropdownButtonFormField<String>(
            key: const ValueKey('level'),
            initialValue: levels.any((l) => l.id == _targetId) ? _targetId : null,
            decoration: const InputDecoration(labelText: 'Level'),
            items: [for (final l in levels) DropdownMenuItem(value: l.id, child: Text(l.name))],
            onChanged: (v) => setState(() => _targetId = v),
          ),
        if (_audience == MessageAudience.storefront)
          DropdownButtonFormField<String>(
            key: const ValueKey('storefront'),
            isExpanded: true,
            initialValue: storefronts.any((s) => s.id == _targetId) ? _targetId : null,
            decoration: const InputDecoration(labelText: 'Storefront'),
            items: [for (final s in storefronts) DropdownMenuItem(value: s.id, child: Text('${s.code} · ${s.name}', overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() => _targetId = v),
          ),
        if (_audience == MessageAudience.worker) _PersonPicker(selectedId: _targetId, eventId: event?.id, onChanged: (id) => setState(() => _targetId = id)),
        if (_audience == MessageAudience.level || _audience == MessageAudience.storefront) ...[
          const SizedBox(height: 6),
          Text(
            event == null
                ? 'No event right now: it goes to the leads and managers for it.'
                : 'Goes to the people working ${event.name} there, plus its leads and managers.',
            style: AppText.meta,
          ),
        ],
        if (_audience == MessageAudience.managers) Text('Goes to every manager and lead.', style: AppText.meta),
        if (_audience == MessageAudience.everyone) Text('Goes to everyone at ${session.venue.name}.', style: AppText.meta),
        const SizedBox(height: 14),
        Text('Quick messages', style: AppText.meta.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (label, text) in messageTemplates)
              ActionChip(
                label: Text(label),
                onPressed: () => setState(() => _body.text = templateText(text, storefrontName: sfName)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _body,
          minLines: 3,
          maxLines: 6,
          maxLength: 1000,
          decoration: const InputDecoration(hintText: 'Message', alignLabelWithHint: true),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _urgent,
          onChanged: (v) => setState(() => _urgent = v),
          title: const Text('Urgent'),
          subtitle: const Text('Highlighted in red, and emailed to people who turned on email.'),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy ? null : () => _send(session, event),
          style: _urgent ? FilledButton.styleFrom(backgroundColor: AppColors.bad) : null,
          icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send),
          label: Text(_urgent ? 'Send urgent message' : 'Send'),
        ),
      ],
    );
  }
}

/// Pick one person: the staff list for venue managers, otherwise the people working the
/// person's storefronts at the event.
class _PersonPicker extends ConsumerWidget {
  const _PersonPicker({required this.selectedId, required this.eventId, required this.onChanged});

  final String? selectedId;
  final String? eventId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider)!;
    List<Worker> people;
    if (session.canVenueWide(Perm.viewWorkers)) {
      people = ref.watch(workersProvider).value ?? const [];
    } else if (eventId != null) {
      final board = ref.watch(boardProvider(eventId!)).value;
      people = [for (final w in (board?.workers.values ?? const <BoardWorker>[])) w.worker];
    } else {
      people = const [];
    }
    people = [for (final w in people) if (w.status == 'active') w]..sort((a, b) => a.displayName.compareTo(b.displayName));
    if (people.isEmpty) return Text('No one to choose from right now.', style: AppText.meta);
    final selected = people.where((w) => w.id == selectedId).firstOrNull;
    return Autocomplete<Worker>(
      key: ValueKey('person-${people.length}'),
      initialValue: TextEditingValue(text: selected?.displayName ?? ''),
      displayStringForOption: (w) => w.displayName,
      optionsBuilder: (v) {
        final q = v.text.trim().toLowerCase();
        if (q.isEmpty) return people.take(20);
        return people.where((w) => w.displayName.toLowerCase().contains(q) || w.employeeNumber.toLowerCase().contains(q)).take(20);
      },
      onSelected: (w) => onChanged(w.id),
      fieldViewBuilder: (context, controller, focus, submit) => TextField(
        controller: controller,
        focusNode: focus,
        decoration: InputDecoration(labelText: 'Person', hintText: 'Type a name', suffixIcon: selected == null ? null : const Icon(Icons.check, color: AppColors.good)),
        onChanged: (_) {
          if (selectedId != null) onChanged(null);
        },
      ),
    );
  }
}

/// A message sheet, for example from a storefront on the live map.
Future<void> showComposeSheet(BuildContext context, {MessageAudience? audience, String? targetId, String? eventId, String title = 'New message'}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppSpace.screen, 0, AppSpace.screen, AppSpace.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: AppText.sectionHeading),
            const SizedBox(height: 12),
            ComposeForm(
              initialAudience: audience,
              initialTargetId: targetId,
              eventId: eventId,
              onSent: (_) => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    ),
  );
}

/// A lead's one-tap alert to the managers: "Stand 104 needs a runner."
Future<void> showHelpRequest(BuildContext context, WidgetRef ref, Storefront storefront) async {
  final note = TextEditingController();
  var choice = 0;
  final send = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('Request help at ${storefront.name}'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Sends an urgent alert to the managers and leads.', style: AppText.meta),
                const SizedBox(height: 8),
                RadioGroup<int>(
                  groupValue: choice,
                  onChanged: (v) => setState(() => choice = v ?? 0),
                  child: Column(
                    children: [
                      for (var i = 0; i < 4; i++)
                        RadioListTile<int>(contentPadding: EdgeInsets.zero, value: i, title: Text(messageTemplates[i].$1)),
                    ],
                  ),
                ),
                TextField(controller: note, decoration: const InputDecoration(hintText: 'Add a note (optional)'), maxLength: 300),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.bad),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Send alert'),
          ),
        ],
      ),
    ),
  );
  final extra = note.text.trim();
  note.dispose();
  if (send != true || !context.mounted) return;
  final session = ref.read(sessionProvider)!;
  try {
    final body = [templateText(messageTemplates[choice].$2, storefrontName: storefront.name), if (extra.isNotEmpty) extra].join(' ');
    final sent = await ref
        .read(commsRepoProvider)
        .sendMessage(session, MessageDraft(audience: MessageAudience.managers, body: body, urgent: true));
    if (context.mounted) showMessage(context, 'Alert sent to ${sent.recipientCount} managers and leads.');
  } on AppFailure catch (e) {
    if (context.mounted) showMessage(context, e.message);
  }
}
