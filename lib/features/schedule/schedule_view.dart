import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import 'schedule_actions.dart';

/// Builds the event's schedule: which storefronts open, how many people each needs by
/// role, and who fills each position.
class ScheduleView extends ConsumerStatefulWidget {
  const ScheduleView({super.key, required this.board});

  final EventBoard board;

  @override
  ConsumerState<ScheduleView> createState() => _ScheduleViewState();
}

class _ScheduleViewState extends ConsumerState<ScheduleView> {
  String? _level;
  bool _gapsOnly = false;

  Future<void> _openStorefronts(VenueContext venue) async {
    final board = widget.board;
    final selected = {...board.openStorefrontIds};
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('Open storefronts (${selected.length} of ${venue.storefronts.length})'),
          content: SizedBox(
            width: 480,
            height: 520,
            child: ListView(
              children: [
                Row(children: [
                  TextButton(onPressed: () => setState(() => selected.addAll(venue.storefronts.map((s) => s.id))), child: const Text('All')),
                  TextButton(onPressed: () => setState(selected.clear), child: const Text('None')),
                ]),
                for (final level in venue.levels) ...[
                  Padding(padding: const EdgeInsets.only(top: 12), child: Text(level.name, style: AppText.sectionHeading)),
                  for (final s in venue.storefronts.where((s) => s.levelId == level.id && s.active))
                    CheckboxListTile(
                      dense: true,
                      value: selected.contains(s.id),
                      title: Text('${s.code} · ${s.name}'),
                      onChanged: (v) => setState(() => v == true ? selected.add(s.id) : selected.remove(s.id)),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok == true && mounted) {
      await runBoardAction(context, ref, board.event.id, 'Storefronts updated', (repo) => repo.setOpenStorefronts(board.event.id, selected.toList()));
    }
  }

  Future<void> _generate() async {
    final board = widget.board;
    try {
      late int created;
      await ref.read(boardProvider(board.event.id).notifier).run((repo) async => created = await repo.generateOpenShifts(board.event.id));
      if (mounted) showMessage(context, created == 0 ? 'Every needed position already exists.' : '$created open positions created.');
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  Future<void> _editAttendance(Event event) async {
    final controller = TextEditingController(text: '${event.expectedAttendance}');
    final value = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Expected attendance'),
        content: TextField(controller: controller, keyboardType: TextInputType.number, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, int.tryParse(controller.text.trim())), child: const Text('Save')),
        ],
      ),
    );
    if (value == null || !mounted) return;
    try {
      await ref.read(repositoryProvider).updateEvent(event, expectedAttendance: value);
      ref.invalidate(eventsProvider);
      await ref.read(boardProvider(event.id).notifier).refresh();
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  Future<void> _editCallTime(Event event, String zone) async {
    final local = atVenue(event.callTime, zone);
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay(hour: local.hour, minute: local.minute), helpText: 'Default call time');
    if (picked == null || !mounted) return;
    try {
      final utc = venueWallTimeUtc(DateTime(local.year, local.month, local.day, picked.hour, picked.minute), zone);
      await ref.read(repositoryProvider).updateEvent(event, callTime: utc);
      ref.invalidate(eventsProvider);
      await ref.read(boardProvider(event.id).notifier).refresh();
      if (mounted) showMessage(context, 'Call time changed. Existing positions keep their own call times.');
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    } on ArgumentError catch (e) {
      if (mounted) showMessage(context, '${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final venueAsync = ref.watch(venueProvider);
    final venue = venueAsync.value;
    final session = ref.watch(sessionProvider)!;
    if (venue == null) {
      return venueAsync.hasError
          ? ErrorNote(venueAsync.error!, onRetry: () => ref.invalidate(venueProvider))
          : const Center(child: CircularProgressIndicator());
    }
    final board = widget.board;
    final event = board.event;
    final zone = board.timeZone;
    final time = DateFormat('h:mm a');
    final canEvents = session.canVenueWide(Perm.manageEvents);
    final canSchedule = session.can(Perm.manageSchedule);

    final storefronts = [
      for (final s in venue.storefronts)
        if (board.openStorefrontIds.contains(s.id) && (_level == null || s.levelId == _level)) s,
    ];
    final positions = [for (final s in board.shifts) if (s.status != ShiftStatus.cancelled) s];
    final filled = positions.where((s) => s.workerId != null).length;
    final needed = board.openStorefrontIds.fold(0, (sum, id) => sum + board.needAt(id));
    final missingPositions = needed - positions.length;
    final byType = <WorkerType, int>{};
    for (final s in positions.where((s) => s.workerId != null)) {
      final t = board.workers[s.workerId]?.worker.type ?? WorkerType.regular;
      byType[t] = (byType[t] ?? 0) + 1;
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 48),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, 0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.l),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: AppSpace.xl,
                    runSpacing: AppSpace.m,
                    children: [
                      _Fact('Call', time.format(atVenue(event.callTime, zone)), onEdit: canEvents ? () => _editCallTime(event, zone) : null),
                      _Fact('Doors', time.format(atVenue(event.doorsTime, zone))),
                      _Fact('Start', time.format(atVenue(event.startTime, zone))),
                      _Fact('Expected', NumberFormat.decimalPattern().format(event.expectedAttendance), onEdit: canEvents ? () => _editAttendance(event) : null),
                      _Fact('Positions filled', '$filled / ${positions.length}'),
                      _Fact('Mix', 'Staff ${byType[WorkerType.regular] ?? 0} · Temp ${byType[WorkerType.temp] ?? 0} · NPO ${byType[WorkerType.npo] ?? 0}'),
                    ],
                  ),
                  const SizedBox(height: AppSpace.l),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (canEvents)
                        OutlinedButton.icon(
                          onPressed: () => _openStorefronts(venue),
                          icon: const Icon(Icons.storefront),
                          label: Text('Open storefronts (${board.openStorefrontIds.length})'),
                        ),
                      if (canSchedule)
                        FilledButton.icon(
                          onPressed: _generate,
                          icon: const Icon(Icons.playlist_add),
                          label: Text(missingPositions > 0 ? 'Create $missingPositions open positions' : 'Create open positions'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.l, AppSpace.screen, 0),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ChoiceChip(label: const Text('All levels'), selected: _level == null, onSelected: (_) => setState(() => _level = null)),
              for (final l in venue.levels) ChoiceChip(label: Text(l.name), selected: _level == l.id, onSelected: (_) => setState(() => _level = l.id)),
              FilterChip(label: const Text('Only gaps'), selected: _gapsOnly, onSelected: (v) => setState(() => _gapsOnly = v)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (storefronts.isEmpty) const EmptyNote('No storefronts open for this event in your view.'),
        for (final sf in storefronts)
          _StorefrontTile(storefront: sf, board: board, venue: venue, gapsOnly: _gapsOnly, canSchedule: canSchedule),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, {this.onEdit});

  final String label;
  final String value;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onEdit,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label.toUpperCase(), style: AppText.kicker),
            if (onEdit != null) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.edit, size: 12, color: AppColors.muted)),
          ]),
          Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        ]),
      );
}

class _StorefrontTile extends ConsumerWidget {
  const _StorefrontTile({required this.storefront, required this.board, required this.venue, required this.gapsOnly, required this.canSchedule});

  final Storefront storefront;
  final EventBoard board;
  final VenueContext venue;
  final bool gapsOnly;
  final bool canSchedule;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shifts = board.shiftsAt(storefront.id).where((s) => s.status != ShiftStatus.cancelled).toList()
      ..sort((a, b) {
        final ra = venue.jobRole(a.jobRoleCode)?.sort ?? 99;
        final rb = venue.jobRole(b.jobRoleCode)?.sort ?? 99;
        return ra != rb ? ra.compareTo(rb) : (a.workerId == null ? 1 : 0).compareTo(b.workerId == null ? 1 : 0);
      });
    final needs = [for (final n in board.needs) if (n.storefrontId == storefront.id) n]
      ..sort((a, b) => (venue.jobRole(a.jobRoleCode)?.sort ?? 99).compareTo(venue.jobRole(b.jobRoleCode)?.sort ?? 99));
    final needed = needs.fold(0, (s, n) => s + n.count);
    final filled = shifts.where((s) => s.workerId != null).length;
    if (gapsOnly && filled >= needed && shifts.every((s) => s.workerId != null)) return const SizedBox.shrink();
    final tone = filled >= needed ? Tone.good : filled >= needed * 0.8 ? Tone.warn : Tone.bad;
    final rules = venue.rules;
    final time = DateFormat('h:mm a');

    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
      childrenPadding: const EdgeInsets.only(bottom: 12),
      title: Text(storefront.name),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: needed == 0 ? 1 : (filled / needed).clamp(0, 1),
                minHeight: 8,
                color: toneColor(tone, context),
                backgroundColor: AppColors.idleSoft,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text('$filled / $needed', style: AppText.meta.copyWith(fontWeight: FontWeight.w700)),
        ]),
      ),
      children: [
        if (canSchedule)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final n in needs)
                  _NeedStepper(
                    label: venue.roleName(n.jobRoleCode),
                    count: n.count,
                    onChanged: (v) => runBoardAction(context, ref, board.event.id, '${venue.roleName(n.jobRoleCode)} headcount: $v',
                        (repo) => repo.setStaffingNeed(board.event.id, storefront.id, n.jobRoleCode, v)),
                  ),
              ],
            ),
          ),
        for (final s in shifts)
          Builder(builder: (context) {
            final bw = board.workers[s.workerId];
            final w = bw?.worker;
            final minor = bw?.isMinor(rules.minors.adultAge) ?? false;
            return ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
              leading: Icon(w == null ? Icons.radio_button_unchecked : Icons.check_circle, color: w == null ? AppColors.bad : AppColors.good),
              title: Row(children: [
                Flexible(child: Text(w?.displayName ?? 'Open', overflow: TextOverflow.ellipsis)),
                if (w != null && w.type != WorkerType.regular) ...[const SizedBox(width: 6), StatusTag(workerTypeLabel(w.type), Tone.info)],
                if (minor) ...[const SizedBox(width: 4), StatusTag('Minor ${bw!.ageOnEvent}', Tone.warn)],
                if (s.status == ShiftStatus.released) ...[const SizedBox(width: 4), const StatusTag('Sent home', Tone.idle)],
              ]),
              subtitle: Text('${venue.roleName(s.jobRoleCode)} · call ${time.format(atVenue(s.callTime, board.timeZone))}'),
              trailing: !canSchedule
                  ? null
                  : w == null
                      ? FilledButton.tonal(onPressed: () => showAssignSheet(context, ref, board, s), child: const Text('Assign'))
                      : s.status == ShiftStatus.assigned
                          ? IconButton(tooltip: 'Remove', icon: const Icon(Icons.person_remove_outlined), onPressed: () => unassignWorker(context, ref, board, s))
                          : null,
            );
          }),
        if (shifts.length < needed)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen, vertical: 4),
            child: Text('${needed - shifts.length} more needed. Use "Create open positions" above.', style: AppText.meta.copyWith(color: AppColors.bad)),
          ),
      ],
    );
  }
}

class _NeedStepper extends StatelessWidget {
  const _NeedStepper({required this.label, required this.count, required this.onChanged});

  final String label;
  final int count;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(border: Border.all(color: AppColors.divider), borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.only(left: 10), child: Text(label, style: AppText.meta.copyWith(color: AppColors.text))),
          IconButton(tooltip: 'Fewer $label', icon: const Icon(Icons.remove, size: 18), onPressed: count > 0 ? () => onChanged(count - 1) : null),
          Text('$count', style: const TextStyle(fontWeight: FontWeight.w700)),
          IconButton(tooltip: 'More $label', icon: const Icon(Icons.add, size: 18), onPressed: () => onChanged(count + 1)),
        ]),
      );
}
