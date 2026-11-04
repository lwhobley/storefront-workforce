import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import 'arena_map.dart';
import 'live_model.dart';
import 'storefront_sheet.dart';

/// The live event board: headcount, the arena map colored by storefront status, and the
/// people who need attention now (missing, breaks due, near overtime, minors).
class LiveView extends ConsumerStatefulWidget {
  const LiveView({super.key, required this.board});

  final EventBoard board;

  @override
  ConsumerState<LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends ConsumerState<LiveView> {
  String? _levelId;
  String? _selected;

  void _open(String storefrontId, bool wide) {
    if (wide) {
      setState(() => _selected = storefrontId);
    } else {
      showStorefrontSheet(context, widget.board.event.id, storefrontId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final venueAsync = ref.watch(venueProvider);
    final venue = venueAsync.value;
    final now = ref.watch(clockProvider).value ?? DateTime.now().toUtc();
    if (venue == null) {
      return venueAsync.hasError
          ? ErrorNote(venueAsync.error!, onRetry: () => ref.invalidate(venueProvider))
          : const Center(child: CircularProgressIndicator());
    }
    final board = widget.board;
    final rules = venue.rules;
    final cards = evaluateBoard(board, rules, now);
    final summaries = summarizeByStorefront(board, cards);
    final open = summaries.values.where((s) => s.isOpen);

    final needed = open.fold(0, (sum, s) => sum + s.needed);
    final assigned = open.fold(0, (sum, s) => sum + s.assigned);
    final onSite = open.fold(0, (sum, s) => sum + s.onSite);
    final missing = cards.where((c) => c.headline == LiveHeadline.notArrived || c.headline == LiveHeadline.noShow).toList();
    final late = cards.where((c) => c.attendance.status == AttendanceStatus.late).length;
    final openPositions = cards.where((c) => c.headline == LiveHeadline.openPosition).toList();
    final breaks = cards.where((c) => c.shift.workerId != null && c.needsBreakAttention && c.state != TimelineState.clockedOut && c.headline != LiveHeadline.released).toList();
    final overtime = cards.where((c) => (c.overtime.approaching || c.overtime.inOvertime) && c.headline != LiveHeadline.released).toList();
    final minors = cards.where((c) => c.isMinor && (c.state == TimelineState.working || c.state == TimelineState.onBreak)).toList();
    final released = [for (final s in board.shifts) if (s.releaseOrder != null) s]..sort((a, b) => a.releaseOrder!.compareTo(b.releaseOrder!));

    final levels = [for (final l in venue.levels) if (venue.storefronts.any((s) => s.levelId == l.id && board.storefrontIds.contains(s.id))) l];
    final levelId = levels.any((l) => l.id == _levelId) ? _levelId! : (levels.isEmpty ? null : levels.first.id);
    final levelStorefronts = [for (final s in venue.storefronts) if (s.levelId == levelId && board.storefrontIds.contains(s.id)) s];
    final fillRate = needed == 0 ? 100 : (assigned * 100 / needed).round();

    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 1100;
      final tiles = Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final t in [
            StatTile(label: 'Staffed', value: '$assigned/$needed', detail: '$fillRate% filled', tone: fillRate >= 98 ? Tone.good : fillRate >= 90 ? Tone.warn : Tone.bad),
            StatTile(label: 'On site', value: '$onSite', detail: 'clocked in now', tone: Tone.good),
            StatTile(label: 'Missing', value: '${missing.length}', detail: '${missing.where((c) => c.headline == LiveHeadline.noShow).length} no-shows', tone: missing.isEmpty ? Tone.good : Tone.bad),
            StatTile(label: 'Late', value: '$late', detail: 'arrived after grace', tone: late == 0 ? Tone.good : Tone.warn),
            StatTile(label: 'Open positions', value: '${openPositions.length}', tone: openPositions.isEmpty ? Tone.good : Tone.bad),
            StatTile(label: 'Breaks due', value: '${breaks.length}', tone: breaks.isEmpty ? Tone.good : Tone.warn),
            StatTile(label: 'Near overtime', value: '${overtime.length}', tone: overtime.isEmpty ? Tone.good : Tone.warn),
            StatTile(label: 'Sent home', value: '${released.length}'),
          ])
            SizedBox(width: wide ? 150 : (box.maxWidth - AppSpace.screen * 2 - 10) / 2, child: t),
        ],
      );

      final map = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (levels.length > 1)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<String>(
                segments: [for (final l in levels) ButtonSegment(value: l.id, label: Text(l.name))],
                selected: {?levelId},
                onSelectionChanged: (v) => setState(() => _levelId = v.first),
              ),
            ),
          const SizedBox(height: 12),
          ArenaMap(
            layout: venueMapLayouts[(venue.venue.settings['map'] as Map?)?['layout']],
            storefronts: levelStorefronts,
            summaries: summaries,
            selectedId: _selected,
            levelName: venue.levels.where((l) => l.id == levelId).firstOrNull?.name ?? '',
            onTap: (s) => _open(s.id, wide),
          ),
          const SizedBox(height: 8),
          const Wrap(spacing: 12, runSpacing: 4, children: [
            _Legend(Tone.good, 'Fully staffed'),
            _Legend(Tone.warn, 'Late or break due'),
            _Legend(Tone.bad, 'Missing or open'),
            _Legend(Tone.idle, 'Closed / not started'),
          ]),
        ],
      );

      final attention = _Attention(
        board: board,
        venue: venue,
        missing: missing,
        openPositions: openPositions,
        breaks: breaks,
        overtime: overtime,
        minors: minors,
        released: released,
        suggestions: releaseSuggestions(cards, board, rules).take(5).toList(),
        onStorefront: (id) => _open(id, wide),
      );

      if (wide) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, 48),
          children: [
            tiles,
            const SizedBox(height: AppSpace.l),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: Column(children: [map, attention])),
                const SizedBox(width: AppSpace.l),
                Expanded(
                  flex: 2,
                  child: Card(
                    child: SizedBox(
                      height: 760,
                      child: _selected == null
                          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Tap a storefront on the map to see who is there.', style: AppText.meta)))
                          : Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: StorefrontPanel(eventId: board.event.id, storefrontId: _selected!, embedded: true),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      }
      return ListView(
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, AppSpace.l), child: tiles),
          Padding(padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen), child: map),
          attention,
        ],
      );
    });
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.tone, this.label);

  final Tone tone;
  final String label;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: toneColor(tone, context), shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: AppText.meta),
      ]);
}

class _Attention extends ConsumerWidget {
  const _Attention({
    required this.board,
    required this.venue,
    required this.missing,
    required this.openPositions,
    required this.breaks,
    required this.overtime,
    required this.minors,
    required this.released,
    required this.suggestions,
    required this.onStorefront,
  });

  final EventBoard board;
  final VenueContext venue;
  final List<LiveShiftStatus> missing;
  final List<LiveShiftStatus> openPositions;
  final List<LiveShiftStatus> breaks;
  final List<LiveShiftStatus> overtime;
  final List<LiveShiftStatus> minors;
  final List<Shift> released;
  final List<LiveShiftStatus> suggestions;
  final ValueChanged<String> onStorefront;

  String _where(Shift s) {
    final sf = venue.storefront(s.storefrontId);
    return '${sf?.name ?? ''} · ${venue.roleName(s.jobRoleCode)}';
  }

  Widget _row(BuildContext context, LiveShiftStatus c, String detail) {
    final w = board.workers[c.shift.workerId]?.worker;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
      title: Text(w?.displayName ?? 'Open position'),
      subtitle: Text('${_where(c.shift)} · $detail'),
      trailing: StatusTag(headlineLabel(c.headline), headlineTone(c.headline)),
      onTap: () => onStorefront(c.shift.storefrontId),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final time = DateFormat('h:mm a');
    final zone = board.timeZone;
    final openByStorefront = <String, int>{};
    for (final c in openPositions) {
      openByStorefront.update(c.shift.storefrontId, (n) => n + 1, ifAbsent: () => 1);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (missing.isNotEmpty) ...[
          SectionHeading('Missing (${missing.length})'),
          for (final c in missing) _row(context, c, 'call ${time.format(atVenue(c.shift.callTime, zone))}, ${c.attendance.minutesPastCall} min ago'),
        ],
        if (openByStorefront.isNotEmpty) ...[
          SectionHeading('Open positions (${openPositions.length})'),
          for (final e in openByStorefront.entries)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
              title: Text(venue.storefront(e.key)?.name ?? ''),
              subtitle: Text([
                for (final c in openPositions.where((c) => c.shift.storefrontId == e.key)) venue.roleName(c.shift.jobRoleCode),
              ].join(', ')),
              trailing: StatusTag('${e.value} open', Tone.bad),
              onTap: () => onStorefront(e.key),
            ),
        ],
        if (breaks.isNotEmpty) ...[
          SectionHeading('Breaks due (${breaks.length})'),
          for (final c in breaks) _row(context, c, '${formatMinutesShort(c.workedMinutes)} worked'),
        ],
        if (overtime.isNotEmpty) ...[
          SectionHeading('Approaching overtime (${overtime.length})'),
          for (final c in overtime)
            _row(context, c, c.overtime.inOvertime ? 'in overtime' : '${formatMinutesShort(c.overtime.minutesUntilOvertime)} until overtime'),
        ],
        if (minors.isNotEmpty) ...[
          SectionHeading('Minors on the clock (${minors.length})'),
          for (final c in minors)
            _row(context, c, 'age ${c.age} · ${formatMinutesShort(c.workedMinutes)} worked'
                '${_minorLimit(c, zone) == null ? '' : ' · must leave by ${_minorLimit(c, zone)}'}'),
        ],
        SectionHeading('Sent home (${released.length})'),
        if (released.isEmpty) const EmptyNote('No one sent home yet.'),
        for (final s in released)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
            leading: CircleAvatar(radius: 14, child: Text('${s.releaseOrder}', style: const TextStyle(fontSize: 12))),
            title: Text(board.workers[s.workerId]?.worker.displayName ?? ''),
            subtitle: Text('${_where(s)} · ${s.releasedAt == null ? '' : time.format(atVenue(s.releasedAt!, zone))} · ${s.releaseReason}'),
          ),
        if (suggestions.isNotEmpty) ...[
          const SectionHeading('Next to send home, by venue rule'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpace.screen),
            child: Text('Temps, then NPO members, then staff with the newest hire date. Tap a storefront to act.', style: AppText.meta),
          ),
          for (final c in suggestions)
            _row(context, c, workerKindLabel(board.workers[c.shift.workerId]?.worker)),
        ],
        if (board.changes.isNotEmpty) ...[
          const SectionHeading('Recent moves and changes'),
          for (final ch in board.changes.take(12))
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
              title: Text('${board.workers[ch.workerId]?.worker.displayName ?? ''} ${ch.action}'
                  '${ch.action == 'moved' ? ' ${mapLabel(venue.storefront(ch.fromStorefrontId ?? '')?.name ?? '')} → ${mapLabel(venue.storefront(ch.toStorefrontId ?? '')?.name ?? '')}' : ''}'),
              subtitle: Text('${time.format(atVenue(ch.changedAt, zone))} · ${ch.changedByName} · ${ch.reason}'),
            ),
        ],
      ],
    );
  }

  /// The latest end time today for a minor, from the venue's minor rules.
  String? _minorLimit(LiveShiftStatus c, String zone) {
    final age = c.age;
    if (age == null) return null;
    final band = venue.rules.minors.bandFor(age);
    final local = atVenue(board.event.callTime, zone);
    final summer = isSummer(DateTime.utc(local.year, local.month, local.day));
    return summer ? (band?.summerLatestEnd ?? band?.latestEnd) : band?.latestEnd;
  }
}

String workerKindLabel(Worker? w) {
  if (w == null) return '';
  return switch (w.type) {
    WorkerType.temp => 'temp',
    WorkerType.npo => 'NPO member',
    WorkerType.regular => w.hireDate == null ? 'staff' : 'staff since ${w.hireDate!.year}',
  };
}
