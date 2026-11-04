import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../schedule/schedule_actions.dart';
import 'live_model.dart';

/// Tapping a storefront on the map: who is assigned, who is here, who is missing, open
/// positions, and the actions a manager or lead can take.
Future<void> showStorefrontSheet(BuildContext context, String eventId, String storefrontId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: StorefrontPanel(eventId: eventId, storefrontId: storefrontId)),
  );
}

class StorefrontPanel extends ConsumerWidget {
  const StorefrontPanel({super.key, required this.eventId, required this.storefrontId, this.embedded = false});

  final String eventId;
  final String storefrontId;
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(boardProvider(eventId)).value;
    final venue = ref.watch(venueProvider).value;
    final session = ref.watch(sessionProvider)!;
    final now = ref.watch(clockProvider).value ?? DateTime.now().toUtc();
    if (board == null || venue == null) return const Center(child: CircularProgressIndicator());
    final sf = venue.storefront(storefrontId)!;
    final rules = venue.rules;
    final cards = evaluateBoard(
      EventBoard(
        event: board.event,
        timeZone: board.timeZone,
        weekStart: board.weekStart,
        storefrontIds: board.storefrontIds,
        openStorefrontIds: board.openStorefrontIds,
        needs: board.needs,
        shifts: board.shiftsAt(storefrontId),
        workers: board.workers,
        punches: board.punches,
        changes: board.changes,
        canManageAll: board.canManageAll,
      ),
      rules,
      now,
    );
    final summary = StorefrontSummary(storefrontId, board.openStorefrontIds.contains(storefrontId), cards, board.needAt(storefrontId));
    final canManage = session.grants.any((g) =>
        g.permissions.contains(Perm.manageSchedule) &&
        (g.scopeType == 'venue' || (g.scopeType == 'storefront' && g.scopeId == storefrontId) || (g.scopeType == 'level' && g.scopeId == sf.levelId)));
    final time = DateFormat('h:mm a');

    // Leads first, then by role, then problems first.
    cards.sort((a, b) {
      final ra = a.shift.jobRoleCode == 'lead' ? 0 : 1;
      final rb = b.shift.jobRoleCode == 'lead' ? 0 : 1;
      if (ra != rb) return ra.compareTo(rb);
      final r = a.shift.jobRoleCode.compareTo(b.shift.jobRoleCode);
      if (r != 0) return r;
      return a.headline.index.compareTo(b.headline.index);
    });

    final kindLabel = switch (sf.kind) {
      StorefrontKind.bar => 'Bar',
      StorefrontKind.portableCart => 'Portable cart',
      StorefrontKind.kiosk => 'Kiosk',
      StorefrontKind.permanentStand => 'Stand',
    };

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$kindLabel ${sf.code} · Section ${sf.section}'.toUpperCase(), style: AppText.kicker),
              Text(sf.name, style: AppText.screenTitle.copyWith(fontSize: 26)),
              const SizedBox(height: 12),
              if (!summary.isOpen)
                const StatusTag('Closed for this event', Tone.idle)
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    StatusTag('${summary.onSite} on site / ${summary.needed} needed', summary.onSite >= summary.needed ? Tone.good : Tone.warn),
                    if (summary.missing > 0) StatusTag('${summary.missing} missing', Tone.bad, icon: Icons.person_off),
                    if (summary.openPositions > 0) StatusTag('${summary.openPositions} open', Tone.bad, icon: Icons.person_add_alt),
                    if (summary.late > 0) StatusTag('${summary.late} late', Tone.warn),
                    if (summary.onBreak > 0) StatusTag('${summary.onBreak} on break', Tone.warn),
                    if (summary.breakAlerts > 0) StatusTag('${summary.breakAlerts} break due', Tone.warn, icon: Icons.free_breakfast_outlined),
                    if (summary.overtimeAlerts > 0) StatusTag('${summary.overtimeAlerts} near overtime', Tone.warn, icon: Icons.timer_outlined),
                    if (summary.released > 0) StatusTag('${summary.released} sent home', Tone.idle),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        for (final c in cards)
          _PositionTile(
            card: c,
            board: board,
            venue: venue,
            canManage: canManage,
            time: time,
          ),
        if (cards.isEmpty) const EmptyNote('No positions at this storefront for this event.'),
      ],
    );
  }
}

class _PositionTile extends ConsumerWidget {
  const _PositionTile({required this.card, required this.board, required this.venue, required this.canManage, required this.time});

  final LiveShiftStatus card;
  final EventBoard board;
  final VenueContext venue;
  final bool canManage;
  final DateFormat time;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shift = card.shift;
    final bw = board.workers[shift.workerId];
    final w = bw?.worker;
    final station = venue.station(shift.stationId)?.name;
    final zone = board.timeZone;
    final details = <String>[
      [venue.roleName(shift.jobRoleCode), ?station, 'Call ${time.format(atVenue(shift.callTime, zone))}'].join(' · '),
      if (card.attendance.clockedInAt != null)
        'In ${time.format(atVenue(card.attendance.clockedInAt!, zone))} · ${formatMinutesShort(card.workedMinutes)} worked'
            '${card.attendance.status == AttendanceStatus.late ? ' · ${card.attendance.minutesLate} min late' : ''}',
      if (card.needsBreakAttention && card.state != TimelineState.clockedOut) 'Break due now',
      if (card.overtime.inOvertime)
        'In overtime'
      else if (card.overtime.approaching)
        '${formatMinutesShort(card.overtime.minutesUntilOvertime)} to overtime',
      if (shift.status == ShiftStatus.released) 'Sent home #${shift.releaseOrder}: ${shift.releaseReason}',
    ];

    final actions = <PopupMenuEntry<String>>[
      if (shift.status == ShiftStatus.assigned) const PopupMenuItem(value: 'move', child: Text('Move to another storefront')),
      if (shift.status == ShiftStatus.assigned && card.attendance.clockedInAt != null)
        const PopupMenuItem(value: 'release', child: Text('Send home')),
      if (shift.status == ShiftStatus.assigned && card.attendance.clockedInAt == null)
        const PopupMenuItem(value: 'unassign', child: Text('Remove (called off)')),
      if (shift.status == ShiftStatus.released) const PopupMenuItem(value: 'unrelease', child: Text('Undo send-home')),
    ];

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
      leading: CircleAvatar(
        backgroundColor: toneSoft(headlineTone(card.headline), context),
        foregroundColor: toneColor(headlineTone(card.headline), context),
        child: w == null ? const Icon(Icons.person_add_alt) : Text(w.firstName.characters.first + w.lastName.characters.first),
      ),
      title: Row(
        children: [
          Flexible(child: Text(w?.displayName ?? 'Open position', overflow: TextOverflow.ellipsis)),
          if (w != null && w.type != WorkerType.regular) ...[const SizedBox(width: 6), StatusTag(workerTypeLabel(w.type), Tone.info)],
          if (card.isMinor) ...[const SizedBox(width: 4), StatusTag('Minor ${card.age}', Tone.warn)],
        ],
      ),
      subtitle: Text(details.join('\n')),
      isThreeLine: details.length > 1,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusTag(headlineLabel(card.headline), headlineTone(card.headline)),
          if (canManage && shift.isOpen)
            IconButton(tooltip: 'Fill this position', icon: const Icon(Icons.person_add_alt), onPressed: () => showAssignSheet(context, ref, board, shift)),
          if (canManage && actions.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: 'Actions',
              itemBuilder: (_) => actions,
              onSelected: (v) => switch (v) {
                'move' => showMoveDialog(context, ref, board, shift),
                'release' => releaseWorker(context, ref, board, shift),
                'unassign' => unassignWorker(context, ref, board, shift),
                'unrelease' => unreleaseWorker(context, ref, board, shift),
                _ => null,
              },
            ),
        ],
      ),
    );
  }
}
