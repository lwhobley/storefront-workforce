import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/operations_repository.dart';
import 'operations_logic.dart';
import 'operations_providers.dart';
import 'ops_queue.dart';
import 'ops_widgets.dart';

/// The event's checklists with this device's waiting changes shown on top.
EventChecklists? checklistsView(WidgetRef ref, String eventId) {
  final data = ref.watch(eventChecklistsProvider(eventId)).value;
  final venue = ref.watch(venueProvider).value;
  ref.watch(opsQueueProvider);
  if (data == null || venue == null) return null;
  return withPendingChanges(
    data,
    ref.read(opsQueueProvider.notifier).pendingChecklistChanges(),
    kinds: {for (final s in venue.storefronts) s.id: s.kind},
    byName: ref.read(sessionProvider)?.displayName ?? '',
  );
}

Tone checklistTone(ChecklistStatus s) => switch (s) {
      ChecklistStatus.signedOff => Tone.good,
      ChecklistStatus.complete => Tone.info,
      ChecklistStatus.inProgress => Tone.warn,
      ChecklistStatus.notStarted => Tone.idle,
    };

/// "Opening 5/7" tags for one storefront, for the live view. Tap one to open it.
class ChecklistChips extends ConsumerWidget {
  const ChecklistChips({super.key, required this.eventId, required this.storefrontId});

  final String eventId;
  final String storefrontId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final venue = ref.watch(venueProvider).value;
    if (session == null || !session.isManagerView || venue == null) return const SizedBox.shrink();
    final data = checklistsView(ref, eventId);
    final sf = venue.storefront(storefrontId);
    if (data == null || sf == null || !data.storefrontIds.contains(storefrontId)) return const SizedBox.shrink();
    final runs = data.runsAt(storefrontId, sf.kind);
    if (runs.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final r in runs)
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => showChecklistRunSheet(context, eventId: eventId, storefrontId: storefrontId, templateId: r.templateId),
            child: StatusTag(
              r.status == ChecklistStatus.notStarted ? '${r.templateName} not started' : r.chipLabel,
              checklistTone(r.status),
              icon: r.signedOff ? Icons.verified_outlined : Icons.checklist,
            ),
          ),
      ],
    );
  }
}

Future<void> showChecklistRunSheet(BuildContext context, {required String eventId, required String storefrontId, required String templateId}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 760),
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.92,
      child: ChecklistRunPanel(eventId: eventId, storefrontId: storefrontId, templateId: templateId),
    ),
  );
}

/// One checklist: tick items, add photos and notes, sign off or reopen.
class ChecklistRunPanel extends ConsumerStatefulWidget {
  const ChecklistRunPanel({super.key, required this.eventId, required this.storefrontId, required this.templateId});

  final String eventId;
  final String storefrontId;
  final String templateId;

  @override
  ConsumerState<ChecklistRunPanel> createState() => _ChecklistRunPanelState();
}

class _ChecklistRunPanelState extends ConsumerState<ChecklistRunPanel> {
  bool _busy = false;

  ChecklistRun? _run(EventChecklists data, VenueContext venue) {
    final sf = venue.storefront(widget.storefrontId);
    if (sf == null) return null;
    for (final r in data.runsAt(widget.storefrontId, sf.kind)) {
      if (r.templateId == widget.templateId) return r;
    }
    return null;
  }

  Future<void> _change(ChecklistRunItem item, {required bool done, String? note, List<Uint8List> photos = const []}) async {
    final change = ChecklistItemChange(
      id: const Uuid().v4(),
      eventId: widget.eventId,
      storefrontId: widget.storefrontId,
      templateId: widget.templateId,
      templateItemId: item.templateItemId,
      done: done,
      occurredAt: DateTime.now().toUtc(),
      note: note,
    );
    setState(() => _busy = true);
    await runQueued(context, () => ref.read(opsQueueProvider.notifier).recordChecklistItem(change, photos: photos),
        sent: done ? 'Done: ${item.label}' : 'Saved.');
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _toggle(ChecklistRunItem item, bool done) async {
    if (done && item.photoRequired && item.photoCount == 0) {
      final photo = await takeOpsPhoto();
      if (photo == null) {
        if (mounted) showMessage(context, 'This item needs a photo. Take one to tick it.');
        return;
      }
      return _change(item, done: true, photos: [photo]);
    }
    return _change(item, done: done);
  }

  Future<void> _addPhoto(ChecklistRunItem item) async {
    final photo = await takeOpsPhoto();
    if (photo == null) return;
    await _change(item, done: item.done, photos: [photo]);
  }

  Future<void> _editNote(ChecklistRunItem item) async {
    final controller = TextEditingController(text: item.note);
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.label),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 500,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Note (for example who was missing)'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save note')),
        ],
      ),
    );
    if (note == null || note == item.note) return;
    await _change(item, done: item.done, note: note);
  }

  Future<void> _signOff(ChecklistRun run) async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Sign off ${run.templateName.toLowerCase()}?'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Every item is done. Signing off locks the checklist; you can reopen it with a reason.'),
              const SizedBox(height: 12),
              TextField(controller: controller, maxLength: 500, decoration: const InputDecoration(hintText: 'Note (optional)')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sign off')),
        ],
      ),
    );
    if (ok != true) return;
    await _online(() => ref.ops.signOffChecklist(run.id, note: controller.text.trim()), 'Signed off.');
  }

  Future<void> _reopen(ChecklistRun run) async {
    final reason = await askReason(
      context,
      title: 'Reopen ${run.templateName.toLowerCase()}?',
      message: 'The lead can change items again. The reason is kept.',
      action: 'Reopen',
      suggestions: const ['Item was missed', 'Staff changed', 'Photo unclear'],
    );
    if (reason == null) return;
    await _online(() => ref.ops.reopenChecklist(run.id, reason), 'Reopened.');
  }

  /// Sign-off and reopen need the server: a manager's decision should not wait offline.
  Future<void> _online(Future<Object?> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      await ref.read(eventChecklistsProvider(widget.eventId).notifier).refresh();
      if (mounted) showMessage(context, done);
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.offline ? 'No signal. Try again when you are connected.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(venueProvider).value;
    final data = checklistsView(ref, widget.eventId);
    final event = ref.watch(eventsProvider).value?.where((e) => e.id == widget.eventId).firstOrNull;
    if (venue == null || data == null) return const Center(child: CircularProgressIndicator());
    final run = _run(data, venue);
    final sf = venue.storefront(widget.storefrontId);
    if (run == null || sf == null) return const EmptyNote('This checklist is not available.');
    final zone = venue.venue.timeZone;
    final time = DateFormat('h:mm a');
    final canEdit = data.canEdit(widget.storefrontId) && !run.signedOff;
    final canSignOff = data.canSignOff(widget.storefrontId);

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.s, AppSpace.screen, AppSpace.s),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text([sf.name, ?event?.name].join(' · ').toUpperCase(), style: AppText.kicker),
                    const SizedBox(height: 2),
                    Text('${run.templateName} checklist', style: AppText.screenTitle.copyWith(fontSize: 26)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      StatusTag(run.status.label, checklistTone(run.status)),
                      StatusTag('${run.doneCount} of ${run.total} done', run.allDone ? Tone.good : Tone.idle),
                      if (run.hasPending) const StatusTag('Waiting to send', Tone.warn, icon: Icons.cloud_upload_outlined),
                    ]),
                    if (run.total > 0) ...[
                      const SizedBox(height: 10),
                      LinearProgressIndicator(value: run.doneCount / run.total, minHeight: 6, borderRadius: BorderRadius.circular(3)),
                    ],
                  ],
                ),
              ),
              for (final item in run.items)
                _ItemTile(
                  item: item,
                  enabled: canEdit && !_busy,
                  zone: zone,
                  time: time,
                  onToggle: (v) => _toggle(item, v),
                  onPhoto: () => _addPhoto(item),
                  onNote: () => _editNote(item),
                ),
              if (run.items.isEmpty) const EmptyNote('No items on this checklist for this storefront.'),
            ],
          ),
        ),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, AppSpace.m),
            child: _SignOffBar(run: run, canSignOff: canSignOff, canEdit: data.canEdit(widget.storefrontId), busy: _busy, zone: zone,
                onSignOff: () => _signOff(run), onReopen: () => _reopen(run)),
          ),
        ),
      ],
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item, required this.enabled, required this.zone, required this.time, required this.onToggle, required this.onPhoto, required this.onNote});

  final ChecklistRunItem item;
  final bool enabled;
  final String zone;
  final DateFormat time;
  final ValueChanged<bool> onToggle;
  final VoidCallback onPhoto;
  final VoidCallback onNote;

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      if (item.help.isNotEmpty) item.help,
      if (item.done && item.doneAt != null) 'Done ${time.format(atVenue(item.doneAt!, zone))}${item.doneByName.isEmpty ? '' : ' · ${item.doneByName}'}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen - 8, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: Checkbox(value: item.done, onChanged: enabled ? (v) => onToggle(v ?? false) : null, semanticLabel: item.label),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(item.label, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                      if (item.photoRequired)
                        StatusTag(item.photoCount > 0 ? 'Photo added' : 'Photo needed', item.photoCount > 0 ? Tone.good : Tone.warn, icon: Icons.photo_camera_outlined),
                      if (item.pending) const StatusTag('Waiting to send', Tone.warn),
                    ],
                  ),
                  for (final d in details) Text(d, style: AppText.meta),
                  if (item.note.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('Note: ${item.note}', style: AppText.body.copyWith(fontSize: 14)),
                  ],
                  if (item.photoCount > 0) ...[
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      for (final p in item.photoPaths) OpsPhotoThumb(kind: 'checklist', path: p, size: 56),
                      WaitingPhotos(item.pendingPhotos),
                    ]),
                  ],
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),
          if (enabled) ...[
            IconButton(tooltip: 'Add photo', icon: const Icon(Icons.add_a_photo_outlined), onPressed: onPhoto),
            IconButton(tooltip: 'Note', icon: const Icon(Icons.edit_note), onPressed: onNote),
          ],
        ],
      ),
    );
  }
}

class _SignOffBar extends StatelessWidget {
  const _SignOffBar({required this.run, required this.canSignOff, required this.canEdit, required this.busy, required this.zone, required this.onSignOff, required this.onReopen});

  final ChecklistRun run;
  final bool canSignOff;
  final bool canEdit;
  final bool busy;
  final String zone;
  final VoidCallback onSignOff;
  final VoidCallback onReopen;

  @override
  Widget build(BuildContext context) {
    final when = DateFormat('MMM d, h:mm a');
    final lines = <String>[
      if (run.signedOff)
        'Signed off by ${run.signedOffByName.isEmpty ? 'a manager' : run.signedOffByName}'
            '${run.signedOffAt == null ? '' : ', ${when.format(atVenue(run.signedOffAt!, zone))}'}'
            '${run.signOffNote.isEmpty ? '' : '. ${run.signOffNote}'}',
      if (!run.signedOff && run.reopenedAt != null) 'Reopened by ${run.reopenedByName}: ${run.reopenReason}',
      if (!run.signedOff && !canSignOff) run.allDone ? 'Done. A manager signs off.' : 'A manager signs off when every item is done.',
      if (!run.signedOff && canSignOff && !run.allDone) 'Finish every item (and its photos) to sign off.',
      if (!run.signedOff && canSignOff && run.allDone && run.hasPending) 'Waiting for changes to send before sign-off.',
      if (!canEdit && !canSignOff) 'View only.',
    ];
    final action = !canSignOff
        ? null
        : run.signedOff
            ? OutlinedButton.icon(onPressed: busy ? null : onReopen, icon: const Icon(Icons.lock_open), label: const Text('Reopen'))
            : FilledButton.icon(
                onPressed: busy || !run.allDone || run.hasPending || run.id.isEmpty ? null : onSignOff,
                icon: const Icon(Icons.verified_outlined),
                label: const Text('Sign off'),
              );
    return Row(
      children: [
        Expanded(child: Text(lines.join('\n'), style: AppText.meta)),
        if (action != null) ...[const SizedBox(width: 12), action],
      ],
    );
  }
}

/// Venue time label for an event: "Sat, Nov 7 · 7:00 PM".
String eventWhen(Event e, String zone) => DateFormat('EEE, MMM d · h:mm a').format(atVenue(e.startTime, zone));
