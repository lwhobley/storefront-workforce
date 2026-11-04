import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/workforce_repository.dart';
import 'assignment_checks.dart';

String workerTypeLabel(WorkerType t) => switch (t) {
      WorkerType.regular => 'Staff',
      WorkerType.temp => 'Temp',
      WorkerType.npo => 'NPO',
    };

/// Runs a board action and shows the outcome. Server refusals (scope, certification,
/// double booking) come back as plain messages.
Future<bool> runBoardAction(BuildContext context, WidgetRef ref, String eventId, String success, Future<void> Function(WorkforceRepository repo) action) async {
  try {
    await ref.read(boardProvider(eventId).notifier).run((repo) => action(repo));
    if (context.mounted) showMessage(context, success);
    return true;
  } on AppFailure catch (e) {
    if (context.mounted) showMessage(context, e.message);
    return false;
  }
}

/// Picks a person for an open position. Shows each candidate's blocks and warnings from
/// the rules engine before anything is saved.
Future<void> showAssignSheet(BuildContext context, WidgetRef ref, EventBoard board, Shift shift) async {
  final venue = await ref.read(venueProvider.future);
  final role = venue.jobRole(shift.jobRoleCode);
  if (role == null || !context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.88,
      child: _AssignSheet(board: board, shift: shift, role: role, venue: venue),
    ),
  );
}

class _AssignSheet extends ConsumerStatefulWidget {
  const _AssignSheet({required this.board, required this.shift, required this.role, required this.venue});

  final EventBoard board;
  final Shift shift;
  final JobRole role;
  final VenueContext venue;

  @override
  ConsumerState<_AssignSheet> createState() => _AssignSheetState();
}

class _AssignSheetState extends ConsumerState<_AssignSheet> {
  late final Future<List<BoardWorker>> _candidates = ref.read(repositoryProvider).candidates(widget.board.event.id, widget.role.code);
  String _query = '';
  WorkerType? _type;
  bool _hideBlocked = true;

  Future<void> _pick(BoardWorker c, AssignmentCheck check) async {
    var reason = '';
    if (check.warnings.isNotEmpty) {
      final r = await askReason(
        context,
        title: 'Assign ${c.worker.displayName} anyway?',
        message: check.warnings.map((w) => '• ${w.message}').join('\n'),
        hint: 'Why is this OK? (saved with the change)',
        action: 'Assign',
        suggestions: const ['Manager approved', 'Will release before limit', 'Renewal in progress'],
      );
      if (r == null) return;
      reason = r;
    }
    if (!mounted) return;
    final ok = await runBoardAction(context, ref, widget.board.event.id, '${c.worker.displayName} assigned',
        (repo) => repo.assign(widget.shift.id, c.id, reason: reason, warnings: check.warningCodes));
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final sf = widget.venue.storefront(widget.shift.storefrontId);
    final rules = widget.venue.rules;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Fill ${widget.role.name} at ${sf?.name ?? ''}', style: AppText.sectionHeading),
              const SizedBox(height: 8),
              TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name or employee number'),
                onChanged: (v) => setState(() => _query = v.toLowerCase()),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  for (final t in [null, ...WorkerType.values])
                    ChoiceChip(
                      label: Text(t == null ? 'All' : workerTypeLabel(t)),
                      selected: _type == t,
                      onSelected: (_) => setState(() => _type = t),
                    ),
                  FilterChip(label: const Text('Hide blocked'), selected: _hideBlocked, onSelected: (v) => setState(() => _hideBlocked = v)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: FutureBuilder<List<BoardWorker>>(
            future: _candidates,
            builder: (context, snap) {
              if (snap.hasError) return ErrorNote(snap.error!);
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final rows = <(BoardWorker, AssignmentCheck)>[];
              for (final c in snap.data!) {
                if (_type != null && c.worker.type != _type) continue;
                if (_query.isNotEmpty &&
                    !c.worker.displayName.toLowerCase().contains(_query) &&
                    !c.worker.employeeNumber.toLowerCase().contains(_query)) {
                  continue;
                }
                final check = checkAssignment(
                  candidate: c,
                  role: widget.role,
                  event: widget.board.event,
                  shift: widget.shift,
                  rules: rules,
                  timeZone: widget.board.timeZone,
                  certName: widget.venue.certName,
                );
                if (_hideBlocked && check.blocks.isNotEmpty) continue;
                rows.add((c, check));
              }
              // Clean candidates first, then those with warnings.
              rows.sort((a, b) => (a.$2.blocks.length * 10 + a.$2.warnings.length).compareTo(b.$2.blocks.length * 10 + b.$2.warnings.length));
              if (rows.isEmpty) return const EmptyNote('No one available. Turn off "Hide blocked" to see why.');
              return ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, _) => const Divider(indent: AppSpace.screen),
                itemBuilder: (context, i) {
                  final (c, check) = rows[i];
                  final w = c.worker;
                  final org = w.type == WorkerType.temp
                      ? widget.venue.agencyName(w.agencyId)
                      : w.type == WorkerType.npo
                          ? widget.venue.npoName(w.npoGroupId)
                          : '';
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                    enabled: check.blocks.isEmpty,
                    title: Row(
                      children: [
                        Flexible(child: Text(w.displayName, overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 6),
                        StatusTag(workerTypeLabel(w.type), w.type == WorkerType.regular ? Tone.idle : Tone.info),
                        if (c.isMinor(rules.minors.adultAge)) ...[const SizedBox(width: 4), StatusTag('Minor ${c.ageOnEvent}', Tone.warn)],
                      ],
                    ),
                    subtitle: Text([
                      '${w.employeeNumber}${org.isEmpty ? '' : ' · $org'}',
                      for (final b in check.blocks) '⛔ ${b.message}',
                      for (final wn in check.warnings) '⚠ ${wn.message}',
                    ].join('\n')),
                    isThreeLine: check.blocks.length + check.warnings.length > 0,
                    trailing: check.blocks.isEmpty
                        ? FilledButton.tonal(onPressed: () => _pick(c, check), child: const Text('Assign'))
                        : null,
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Moves a person to another storefront mid-event. The reason is required and logged.
Future<void> showMoveDialog(BuildContext context, WidgetRef ref, EventBoard board, Shift shift) async {
  final venue = await ref.read(venueProvider.future);
  if (!context.mounted) return;
  final worker = board.workers[shift.workerId]?.worker;
  final targets = [
    for (final s in venue.storefronts)
      if (board.openStorefrontIds.contains(s.id) && s.id != shift.storefrontId && s.active) s,
  ]..sort((a, b) => a.name.compareTo(b.name));
  String? to;
  var role = shift.jobRoleCode;
  final reason = TextEditingController();
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        int openAt(String id) => board.shiftsAt(id).where((s) => s.isOpen && s.jobRoleCode == role).length;
        return AlertDialog(
          title: Text('Move ${worker?.displayName ?? ''}'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: to,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'To storefront'),
                  items: [
                    for (final s in targets)
                      DropdownMenuItem(
                        value: s.id,
                        child: Text('${s.name}${openAt(s.id) > 0 ? '  (${openAt(s.id)} open ${venue.roleName(role).toLowerCase()})' : ''}'),
                      ),
                  ],
                  onChanged: (v) => setState(() => to = v),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: role,
                  decoration: const InputDecoration(labelText: 'Role'),
                  items: [for (final r in venue.jobRoles) DropdownMenuItem(value: r.code, child: Text(r.name))],
                  onChanged: (v) => setState(() => role = v ?? role),
                ),
                const SizedBox(height: 12),
                TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason (logged)'), onChanged: (_) => setState(() {})),
                const SizedBox(height: 8),
                Wrap(spacing: 6, children: [
                  for (final s in const ['Long line', 'Cover a break', 'Slow stand', 'Short staffed'])
                    ActionChip(label: Text(s), onPressed: () => setState(() => reason.text = s)),
                ]),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              onPressed: to == null || reason.text.trim().isEmpty
                  ? null
                  : () async {
                      final ok = await runBoardAction(context, ref, board.event.id, 'Moved',
                          (repo) => repo.move(shift.id, to!, jobRole: role == shift.jobRoleCode ? null : role, reason: reason.text.trim()));
                      if (ok && context.mounted) Navigator.pop(context);
                    },
              child: const Text('Move'),
            ),
          ],
        );
      },
    ),
  );
}

/// Sends a person home early. The order of releases is kept per event.
Future<void> releaseWorker(BuildContext context, WidgetRef ref, EventBoard board, Shift shift) async {
  final worker = board.workers[shift.workerId]?.worker;
  final reason = await askReason(
    context,
    title: 'Send ${worker?.displayName ?? 'this person'} home?',
    message: 'This is release #${board.shifts.fold<int>(0, (m, s) => (s.releaseOrder ?? 0) > m ? s.releaseOrder! : m) + 1} for this event. '
        'They should clock out before leaving.',
    action: 'Send home',
    suggestions: const ['Slow stand', 'Low attendance', 'Volunteered to leave', 'Stand closing early'],
  );
  if (reason == null || !context.mounted) return;
  await runBoardAction(context, ref, board.event.id, 'Sent home', (repo) => repo.release(shift.id, reason));
}

Future<void> unassignWorker(BuildContext context, WidgetRef ref, EventBoard board, Shift shift) async {
  final reason = await askReason(context, title: 'Remove from this position?', action: 'Remove', suggestions: const ['Called off', 'Schedule change', 'Assigned by mistake']);
  if (reason == null || !context.mounted) return;
  await runBoardAction(context, ref, board.event.id, 'Position is open again', (repo) => repo.unassign(shift.id, reason: reason));
}

Future<void> unreleaseWorker(BuildContext context, WidgetRef ref, EventBoard board, Shift shift) async {
  final reason = await askReason(context, title: 'Undo send-home?', action: 'Undo', suggestions: const ['Sent home by mistake', 'Rush of customers']);
  if (reason == null || !context.mounted) return;
  await runBoardAction(context, ref, board.event.id, 'Back on the schedule', (repo) => repo.unrelease(shift.id, reason));
}
