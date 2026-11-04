import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/operations_repository.dart';
import 'incident_form.dart' show InjuryReminder;
import 'incidents_screen.dart';
import 'operations_providers.dart';
import 'ops_queue.dart';
import 'ops_widgets.dart';

Future<void> showIncidentDetail(BuildContext context, String incidentId) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 760),
      builder: (_) => FractionallySizedBox(heightFactor: 0.92, child: IncidentDetail(incidentId: incidentId)),
    );

/// One incident: what happened, people, photos, the follow-up timeline, and for
/// managers the owner, status and closing note.
class IncidentDetail extends ConsumerStatefulWidget {
  const IncidentDetail({super.key, required this.incidentId});

  final String incidentId;

  @override
  ConsumerState<IncidentDetail> createState() => _IncidentDetailState();
}

class _IncidentDetailState extends ConsumerState<IncidentDetail> {
  final _note = TextEditingController();
  bool _busy = false;

  bool _canManage(AppSession s, Incident i) =>
      i.kind == IncidentKind.employee ? s.canVenueWide(Perm.manageWorkers) : s.canVenueWide(Perm.viewLive);

  Future<void> _addNote(Incident i) async {
    final body = _note.text.trim();
    if (body.isEmpty) return;
    final note = IncidentNoteDraft(id: const Uuid().v4(), incidentId: i.id, body: body, createdAt: DateTime.now().toUtc());
    if (await runQueued(context, () => ref.read(opsQueueProvider.notifier).addIncidentNote(note), sent: 'Note added.')) _note.clear();
  }

  Future<void> _addPhoto(Incident i) async {
    final p = await takeOpsPhoto();
    if (p == null || !mounted) return;
    await runQueued(context, () => ref.read(opsQueueProvider.notifier).addIncidentPhotos(const Uuid().v4(), i.id, [p]), sent: 'Photo added.');
  }

  /// Owner and status changes need the server (they notify people).
  Future<void> _update(Incident i, {IncidentStatus? status, String? assignedTo, bool unassign = false, String? closingNote, required String done}) async {
    setState(() => _busy = true);
    try {
      await ref.ops.updateIncident(i.id, status: status, assignedTo: assignedTo, unassign: unassign, closingNote: closingNote);
      await ref.read(incidentsProvider.notifier).refresh();
      if (mounted) showMessage(context, done);
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.offline ? 'No signal. Try again when you are connected.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close(Incident i) async {
    final note = await askReason(
      context,
      title: 'Close this incident?',
      message: i.kind == IncidentKind.injury ? 'Make sure HR has the injury report.' : null,
      hint: 'Closing note (what was done)',
      action: 'Close',
      suggestions: const ['Reported to HR', 'Fixed', 'Talked with the employee', 'No further action'],
    );
    if (note == null) return;
    await _update(i, status: IncidentStatus.closed, closingNote: note, done: 'Closed.');
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider)!;
    final venue = ref.watch(venueProvider).value;
    final incident = incidentsView(ref)?.where((i) => i.id == widget.incidentId).firstOrNull;
    if (venue == null) return const Center(child: CircularProgressIndicator());
    if (incident == null) return const EmptyNote('This incident is not available.');
    final i = incident;
    final zone = venue.venue.timeZone;
    final fmt = DateFormat('EEE, MMM d · h:mm a');
    final manage = _canManage(session, i) && !i.pending;
    final closed = i.status == IncidentStatus.closed;
    final where = venue.storefront(i.storefrontId ?? '')?.name ?? 'Not at a storefront';

    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.s, AppSpace.screen, 32),
      children: [
        Text('${i.kind.label} · $where'.toUpperCase(), style: AppText.kicker),
        const SizedBox(height: 2),
        Text(fmt.format(atVenue(i.occurredAt, zone)), style: AppText.screenTitle.copyWith(fontSize: 24)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          StatusTag('${i.severity.label} severity', severityTone(i.severity)),
          StatusTag(i.status.label, statusTone(i.status)),
          if (i.pending) const StatusTag('Waiting to send', Tone.warn, icon: Icons.cloud_upload_outlined),
          if (i.kind == IncidentKind.employee) const StatusTag('Staff managers only', Tone.info, icon: Icons.lock_outline),
        ]),
        const SizedBox(height: AppSpace.m),
        if (i.kind == IncidentKind.injury && !closed) ...[const InjuryReminder(), const SizedBox(height: AppSpace.m)],
        Text(i.description, style: AppText.body),
        const SizedBox(height: AppSpace.s),
        Text(
          [
            if (i.eventName.isNotEmpty) i.eventName,
            if (i.reportedByName.isNotEmpty) 'Reported by ${i.reportedByName}',
            if (i.assignedToName.isNotEmpty) 'Follow-up: ${i.assignedToName}',
          ].join(' · '),
          style: AppText.meta,
        ),
        if (i.people.isNotEmpty) ...[
          const SizedBox(height: AppSpace.m),
          const Text('PEOPLE INVOLVED', style: AppText.kicker),
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 8, children: [for (final p in i.people) Chip(label: Text(p.name))]),
        ],
        const SizedBox(height: AppSpace.m),
        Row(children: [
          const Expanded(child: Text('PHOTOS', style: AppText.kicker)),
          if (!closed && !i.pending)
            TextButton.icon(onPressed: () => _addPhoto(i), icon: const Icon(Icons.add_a_photo_outlined), label: const Text('Add photo')),
        ]),
        if (i.photoPaths.isEmpty && i.pendingPhotos == 0) const Text('No photos.', style: AppText.meta),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final p in i.photoPaths) OpsPhotoThumb(kind: 'incident', path: p, size: 88),
          WaitingPhotos(i.pendingPhotos),
        ]),
        if (closed) ...[
          const SizedBox(height: AppSpace.m),
          const Text('CLOSED', style: AppText.kicker),
          Text(i.closingNote, style: AppText.body),
          if (i.closedAt != null)
            Text('${i.closedByName.isEmpty ? '' : '${i.closedByName}, '}${fmt.format(atVenue(i.closedAt!, zone))}', style: AppText.meta),
        ],
        if (manage) ...[
          const SizedBox(height: AppSpace.l),
          _ManageBar(
            incident: i,
            busy: _busy,
            onAssign: (id) => _update(i, assignedTo: id, done: 'Follow-up owner set.'),
            onStatus: (s) => s == IncidentStatus.closed ? _close(i) : _update(i, status: s, done: s == IncidentStatus.open ? 'Reopened.' : 'Updated.'),
          ),
        ],
        const SizedBox(height: AppSpace.l),
        const Text('FOLLOW-UP', style: AppText.kicker),
        const SizedBox(height: 4),
        if (i.notes.isEmpty) const Text('No notes yet.', style: AppText.meta),
        for (final n in i.notes)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              switch (n.kind) { 'status' => Icons.flag_outlined, 'assigned' => Icons.person_outline, 'photos' => Icons.photo_outlined, _ => Icons.notes },
              color: AppColors.muted,
            ),
            title: Text(n.body, style: AppText.body.copyWith(fontSize: 14)),
            subtitle: Text([n.authorName, fmt.format(atVenue(n.createdAt, zone)), if (n.pending) 'waiting to send'].where((s) => s.isNotEmpty).join(' · ')),
          ),
        if (!closed && !i.pending) ...[
          const SizedBox(height: AppSpace.s),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: TextField(controller: _note, minLines: 1, maxLines: 4, maxLength: 2000, decoration: const InputDecoration(hintText: 'Add a follow-up note')),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 22),
              child: FilledButton(onPressed: () => _addNote(i), child: const Text('Add')),
            ),
          ]),
        ],
      ],
    );
  }
}

class _ManageBar extends ConsumerWidget {
  const _ManageBar({required this.incident, required this.busy, required this.onAssign, required this.onStatus});

  final Incident incident;
  final bool busy;
  final ValueChanged<String> onAssign;
  final ValueChanged<IncidentStatus> onStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i = incident;
    final assignees = ref.watch(incidentAssigneesProvider(i.kind)).value ?? const <IncidentAssignee>[];
    final closed = i.status == IncidentStatus.closed;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (!closed)
          PopupMenuButton<String>(
            enabled: !busy && assignees.isNotEmpty,
            tooltip: 'Follow-up owner',
            onSelected: onAssign,
            itemBuilder: (_) => [for (final a in assignees) PopupMenuItem(value: a.userId, child: Text(a.name))],
            child: Chip(
              avatar: const Icon(Icons.person_outline, size: 18),
              label: Text(i.assignedToName.isEmpty ? 'Set follow-up owner' : 'Owner: ${i.assignedToName}'),
            ),
          ),
        if (i.status == IncidentStatus.open)
          OutlinedButton(onPressed: busy ? null : () => onStatus(IncidentStatus.followingUp), child: const Text('Following up')),
        if (!closed) FilledButton.tonal(onPressed: busy ? null : () => onStatus(IncidentStatus.closed), child: const Text('Close')),
        if (closed) OutlinedButton(onPressed: busy ? null : () => onStatus(IncidentStatus.followingUp), child: const Text('Reopen')),
      ],
    );
  }
}
