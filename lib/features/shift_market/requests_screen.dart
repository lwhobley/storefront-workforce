import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/shift_market_repository.dart';
import '../schedule/assignment_checks.dart';
import 'market_providers.dart';
import 'market_widgets.dart';
import 'request_checks.dart';

/// Pickups, drops, and swaps waiting for a manager, limited to the storefronts the
/// signed-in person schedules. Each shows the rules-engine result for the person who
/// would work the shift. Manager screen: English.
class RequestsScreen extends ConsumerStatefulWidget {
  const RequestsScreen({super.key});

  @override
  ConsumerState<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends ConsumerState<RequestsScreen> {
  bool _history = false;
  ShiftRequestKind? _kind;

  Future<void> _decide(ShiftRequest r, AssignmentCheck check, {required bool approve}) async {
    var note = '';
    if (!approve) {
      final reason = await askReason(
        context,
        title: 'Deny this ${_kindName(r.kind).toLowerCase()}?',
        message: 'The employee sees your note.',
        hint: 'Note to the employee',
        action: 'Deny',
        suggestions: const ['We are short that night', 'Already covered', 'Try a swap instead', 'Talk to me first'],
      );
      if (reason == null) return;
      note = reason;
    } else if (check.warnings.isNotEmpty) {
      final reason = await askReason(
        context,
        title: 'Approve despite warnings?',
        message: check.warnings.map((w) => '• ${w.message}').join('\n'),
        hint: 'Why is this OK? (saved with the change)',
        action: 'Approve',
        suggestions: const ['Manager approved', 'Will release before limit', 'Renewal in progress'],
      );
      if (reason == null) return;
      note = reason;
    }
    if (!mounted) return;
    try {
      await (ref.read(repositoryProvider) as ShiftMarketRepository)
          .decideShiftRequest(r.id, approve: approve, note: note, warnings: approve ? check.warningCodes : const []);
      if (mounted) showMessage(context, '${_kindName(r.kind)} ${approve ? 'approved' : 'denied'}. ${_who(r)} will be notified.');
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      ref.invalidate(reviewRequestsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final venueAsync = ref.watch(venueProvider);
    final async = ref.watch(reviewRequestsProvider(_history));
    final openCount = ref.watch(reviewRequestsProvider(false)).value?.where((r) => r.status == ShiftRequestStatus.pending).length;

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(reviewRequestsProvider);
            await ref.read(reviewRequestsProvider(_history).future).catchError((_) => const <ShiftRequest>[]);
          },
          child: Builder(builder: (context) {
            final venue = venueAsync.value;
            final header = [
              ScreenHeader(
                title: 'Requests',
                subtitle: openCount == null
                    ? 'Pickups, drops, and swaps from your staff'
                    : openCount == 0
                        ? 'Nothing waiting for you'
                        : '$openCount waiting for a decision',
                actions: [IconButton(tooltip: 'Reload', icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(reviewRequestsProvider))],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SegmentedButton<bool>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: false, label: Text('Open'), icon: Icon(Icons.inbox_outlined)),
                        ButtonSegment(value: true, label: Text('History'), icon: Icon(Icons.history)),
                      ],
                      selected: {_history},
                      onSelectionChanged: (v) => setState(() => _history = v.first),
                    ),
                    for (final k in [null, ...ShiftRequestKind.values])
                      ChoiceChip(
                        label: Text(k == null ? 'All' : '${_kindName(k)}s'),
                        selected: _kind == k,
                        onSelected: (_) => setState(() => _kind = k),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpace.s),
            ];
            if (venue == null || !async.hasValue) {
              final error = venueAsync.error ?? async.error;
              return ListView(children: [
                ...header,
                if (error != null)
                  ErrorNote(error, onRetry: () => ref.invalidate(reviewRequestsProvider))
                else
                  const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
              ]);
            }
            final rows = [for (final r in async.value!) if (_kind == null || r.kind == _kind) r];
            return MarketList(children: [
              ...header,
              if (rows.isEmpty) EmptyNote(_history ? 'No decided requests yet.' : 'No requests waiting.'),
              for (final r in rows)
                _RequestCard(
                  request: r,
                  venue: venue,
                  history: _history,
                  onDecide: (check, approve) => _decide(r, check, approve: approve),
                ),
            ]);
          }),
        ),
      ),
    );
  }
}

String _kindName(ShiftRequestKind k) => switch (k) {
      ShiftRequestKind.pickup => 'Pickup',
      ShiftRequestKind.drop => 'Drop',
      ShiftRequestKind.swap => 'Swap',
    };

String _who(ShiftRequest r) => r.kind == ShiftRequestKind.swap ? '${r.requesterName} and ${r.targetName}' : r.requesterName;

String _statusName(ShiftRequestStatus s) => switch (s) {
      ShiftRequestStatus.pending => 'Waiting for you',
      ShiftRequestStatus.offered => 'Waiting for coworker',
      ShiftRequestStatus.approved => 'Approved',
      ShiftRequestStatus.denied => 'Denied',
      ShiftRequestStatus.cancelled => 'Withdrawn',
      ShiftRequestStatus.expired => 'Expired',
    };

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.request, required this.venue, required this.history, required this.onDecide});

  final ShiftRequest request;
  final VenueContext venue;
  final bool history;
  final void Function(AssignmentCheck check, bool approve) onDecide;

  @override
  Widget build(BuildContext context) {
    final r = request;
    final zone = venue.venue.timeZone;
    final check = requestCheck(r, venue);
    final local = atVenue(r.shift.callTime, zone);
    final when = '${DateFormat('EEE, MMM d').format(local)} · call ${DateFormat('h:mm a').format(local)}';
    final age = r.incoming?.ageOnEvent;
    final minor = r.incoming?.isMinor(venue.rules.minors.adultAge) ?? false;
    final (kindTone, kindIcon) = switch (r.kind) {
      ShiftRequestKind.pickup => (Tone.info, Icons.add_task),
      ShiftRequestKind.drop => (Tone.warn, Icons.event_busy),
      ShiftRequestKind.swap => (Tone.info, Icons.swap_horiz),
    };
    final statusTone = switch (r.status) {
      ShiftRequestStatus.pending => Tone.warn,
      ShiftRequestStatus.offered => Tone.idle,
      ShiftRequestStatus.approved => Tone.good,
      ShiftRequestStatus.denied => Tone.bad,
      _ => Tone.idle,
    };
    final headline = switch (r.kind) {
      ShiftRequestKind.swap => '${r.requesterName} → ${r.targetName}',
      _ when history => r.requesterName,
      ShiftRequestKind.pickup => '${r.requesterName} wants this shift',
      ShiftRequestKind.drop => '${r.requesterName} wants to drop',
    };
    final pending = r.status == ShiftRequestStatus.pending;

    return Card(
      margin: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.s, AppSpace.screen, 0),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(spacing: 6, runSpacing: 4, children: [
              StatusTag(_kindName(r.kind), kindTone, icon: kindIcon),
              StatusTag(_statusName(r.status), statusTone),
              if (minor) StatusTag('Minor $age', Tone.warn),
            ]),
            const SizedBox(height: AppSpace.s),
            Text(headline, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, height: 1.25)),
            const SizedBox(height: 2),
            Text('${r.storefrontName} · ${r.roleName}', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
            Text('${r.event.name} · $when', style: AppText.meta),
            if (r.kind == ShiftRequestKind.pickup && r.shift.isOpen) Text('Position is open', style: AppText.meta),
            if (r.note.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('“${r.note}”', style: AppText.body.copyWith(fontStyle: FontStyle.italic)),
            ],
            if (!history) ...[
              const SizedBox(height: AppSpace.s),
              for (final b in check.blocks) StatusLine(icon: Icons.block, tone: Tone.bad, text: b.message),
              for (final w in check.warnings) StatusLine(icon: Icons.warning_amber, tone: Tone.warn, text: w.message),
              if (r.kind == ShiftRequestKind.drop && check.blocks.isEmpty)
                const StatusLine(icon: Icons.info_outline, tone: Tone.info, text: 'Approving opens the position again. Fill it from the schedule.'),
              if (r.status == ShiftRequestStatus.offered)
                StatusLine(icon: Icons.hourglass_top, tone: Tone.idle, text: '${r.targetName} has not accepted yet.'),
              if (check.ok && r.kind != ShiftRequestKind.drop && pending)
                const StatusLine(icon: Icons.check_circle_outline, tone: Tone.good, text: 'No rule issues.'),
              if (pending) ...[
                const SizedBox(height: AppSpace.m),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                      onPressed: () => onDecide(check, false),
                      icon: const Icon(Icons.close),
                      label: const Text('Deny'),
                    ),
                  ),
                  const SizedBox(width: AppSpace.s),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                      onPressed: check.blocks.isEmpty ? () => onDecide(check, true) : null,
                      icon: const Icon(Icons.check),
                      label: Text(check.warnings.isEmpty ? 'Approve' : 'Approve…'),
                    ),
                  ),
                ]),
              ],
            ] else ...[
              const SizedBox(height: AppSpace.s),
              Text(
                [
                  if (r.decidedAt != null) DateFormat('MMM d, h:mm a').format(atVenue(r.decidedAt!, zone)),
                  if (r.decidedByName.isNotEmpty) 'by ${r.decidedByName}',
                ].join(' '),
                style: AppText.meta,
              ),
              if (r.decisionNote.isNotEmpty) Text('“${r.decisionNote}”', style: AppText.body),
              if (r.warnings.isNotEmpty) Text('Accepted warnings: ${r.warnings.map((w) => w.replaceAll('_', ' ')).join(', ')}', style: AppText.meta),
            ],
          ],
        ),
      ),
    );
  }
}
