import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/performance_repository.dart';
import 'performance_providers.dart';

Tone scoreTone(int? score) => score == null
    ? Tone.idle
    : score >= 90
        ? Tone.good
        : score >= 75
            ? Tone.info
            : score >= 50
                ? Tone.warn
                : Tone.bad;

/// "Reliability 85" (or "New") as a tag.
Widget reliabilityTag(ReliabilityScore s, {bool short = false}) {
  if (s.score == null) return const StatusTag('No history', Tone.idle);
  final label = short ? '${s.score}' : 'Reliability ${s.score}';
  return StatusTag(s.isNew ? '$label · new' : label, s.isNew ? Tone.idle : scoreTone(s.score), icon: Icons.verified_outlined);
}

const doNotRehireTag = StatusTag('Do not rehire', Tone.bad, icon: Icons.block);

/// Tags for the assign sheet: the candidate's reliability score and the flag.
List<Widget> candidateTags(Map<String, CandidateInsight>? insights, String workerId) {
  final i = insights?[workerId];
  if (i == null) return const [];
  return [if (i.score.score != null) reliabilityTag(i.score, short: false), if (i.flagged) doNotRehireTag];
}

bool candidateFlagged(Map<String, CandidateInsight>? insights, String workerId) => insights?[workerId]?.flagged ?? false;

String outcomeLabel(ShiftOutcome o) => switch (o.outcome) {
      AttendanceOutcome.onTime => 'On time',
      AttendanceOutcome.late => 'Late ${o.minutesLate} min',
      AttendanceOutcome.noShow => 'No-show',
      AttendanceOutcome.callOff => 'Call-off',
      AttendanceOutcome.released => 'Sent home',
      AttendanceOutcome.pending => 'Not yet',
    };

Tone outcomeTone(AttendanceOutcome o) => switch (o) {
      AttendanceOutcome.onTime => Tone.good,
      AttendanceOutcome.late => Tone.warn,
      AttendanceOutcome.noShow || AttendanceOutcome.callOff => Tone.bad,
      _ => Tone.idle,
    };

String _stars(int n) => '★' * n + '☆' * (5 - n);

/// A person's reliability, ratings, notes and do-not-rehire flag. Shown to people with
/// view_workers; changes need manage_workers.
class PerformanceSection extends ConsumerWidget {
  const PerformanceSection({super.key, required this.worker});

  final Worker worker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider)!;
    if (!session.canVenueWide(Perm.viewWorkers)) return const SizedBox.shrink();
    final canManage = session.canVenueWide(Perm.manageWorkers);
    final data = ref.watch(performanceDataProvider);
    final detail = ref.watch(workerPerformanceProvider(worker.id));
    final zone = session.venue.timeZone;
    final date = DateFormat('MMM d, y');

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // ---- Do not rehire ----
      detail.when(
        loading: () => const SizedBox.shrink(),
        error: (e, _) => ErrorNote(e),
        data: (d) => d.flag == null
            ? const SizedBox.shrink()
            : Card(
                color: AppColors.badSoft,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.m),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Row(children: [
                      Icon(Icons.block, color: AppColors.bad, size: 20),
                      SizedBox(width: 6),
                      Text('Do not rehire', style: TextStyle(fontWeight: FontWeight.w800, color: AppColors.bad)),
                    ]),
                    const SizedBox(height: 4),
                    Text(d.flag!.reason, style: AppText.body),
                    Text(
                      'Flagged ${date.format(atVenue(d.flag!.flaggedAt, zone))}${d.flag!.flaggedByName.isEmpty ? '' : ' by ${d.flag!.flaggedByName}'}. '
                      'They cannot be put in a position.',
                      style: AppText.meta,
                    ),
                    if (canManage)
                      Wrap(spacing: 8, children: [
                        TextButton(onPressed: () => _flag(context, ref, d.flag!), child: const Text('Edit reason')),
                        TextButton(onPressed: () => _clearFlag(context, ref), child: const Text('Clear flag')),
                      ]),
                  ]),
                ),
              ),
      ),

      // ---- Reliability ----
      const SizedBox(height: 8),
      Text('Reliability', style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
      data.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(performanceDataProvider)),
        data: (p) {
          final s = p.scoreOf(worker.id);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SizedBox(height: 4),
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(s.score == null ? '—' : '${s.score}', style: AppText.numeral.copyWith(color: toneColor(scoreTone(s.score), context))),
              if (s.score != null) StatusTag(s.isNew ? 'New: ${s.events} of ${p.rules.minEvents} events' : reliabilityBand(s.score!), s.isNew ? Tone.idle : scoreTone(s.score)),
              if (s.events > 0)
                Text('${s.onTime} on time · ${s.lates} late · ${s.noShows} no-show · ${s.callOffs} call-off', style: AppText.meta),
            ]),
            const SizedBox(height: 4),
            Text(s.breakdown, style: AppText.body),
            Text(p.rules.explain, style: AppText.meta),
            if (s.counted.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final o in s.counted)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    SizedBox(width: 92, child: Text(DateFormat('MMM d').format(atVenue(o.callTime, zone)), style: AppText.meta)),
                    Expanded(child: Text(p.events[o.eventId]?.name ?? 'Event', style: AppText.body, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 8),
                    StatusTag(outcomeLabel(o), outcomeTone(o.outcome)),
                  ]),
                ),
            ],
          ]);
        },
      ),

      // ---- Ratings and notes ----
      detail.when(
        loading: () => const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
        error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(workerPerformanceProvider(worker.id))),
        data: (d) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: Text(
                d.ratings.isEmpty ? 'Ratings' : 'Ratings · ${d.averageStars!.toStringAsFixed(1)} ★ from ${d.ratings.length}',
                style: AppText.body.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            if (canManage) TextButton.icon(onPressed: () => _rate(context, ref), icon: const Icon(Icons.star_outline), label: const Text('Rate')),
          ]),
          if (d.ratings.isEmpty) const Text('No ratings yet.', style: AppText.meta),
          for (final r in d.ratings)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_stars(r.stars), style: const TextStyle(color: AppColors.warn, fontSize: 16, letterSpacing: 1)),
                if (r.note.isNotEmpty) Text(r.note, style: AppText.body),
                Text(
                  [
                    date.format(atVenue(r.ratedAt, zone)),
                    if (r.eventId != null && data.value?.events[r.eventId] != null) data.value!.events[r.eventId]!.name,
                    if (r.ratedByName.isNotEmpty) r.ratedByName,
                  ].join(' · '),
                  style: AppText.meta,
                ),
              ]),
            ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Text('Notes', style: AppText.body.copyWith(fontWeight: FontWeight.w700))),
            if (canManage) TextButton.icon(onPressed: () => _note(context, ref), icon: const Icon(Icons.note_add_outlined), label: const Text('Add note')),
          ]),
          if (d.notes.isEmpty) const Text('No notes yet.', style: AppText.meta),
          for (final n in d.notes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(n.body, style: AppText.body),
                Text(
                  [date.format(atVenue(n.writtenAt, zone)), if (n.writtenByName.isNotEmpty) n.writtenByName].join(' · '),
                  style: AppText.meta,
                ),
              ]),
            ),
          if (canManage && d.flag == null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.bad),
                onPressed: () => _flag(context, ref, null),
                icon: const Icon(Icons.block),
                label: const Text('Flag do not rehire'),
              ),
            ),
          ],
        ]),
      ),
    ]);
  }

  Future<void> _run(BuildContext context, WidgetRef ref, String done, Future<void> Function(PerformanceRepository repo, AppSession s) action) async {
    try {
      await action(ref.performance, ref.read(sessionProvider)!);
      refreshPerformance(ref, worker.id);
      if (context.mounted) showMessage(context, done);
    } on AppFailure catch (e) {
      if (context.mounted) showMessage(context, e.message);
    }
  }

  Future<void> _rate(BuildContext context, WidgetRef ref) async {
    final data = ref.read(performanceDataProvider).value;
    final zone = ref.read(sessionProvider)!.venue.timeZone;
    // Events the person worked recently, newest first, to tie the rating to.
    final events = <Event>[
      for (final o in data?.outcomes ?? const <ShiftOutcome>[])
        if (o.workerId == worker.id && (o.outcome == AttendanceOutcome.onTime || o.outcome == AttendanceOutcome.late)) ?data!.events[o.eventId],
    ]..sort((a, b) => b.startTime.compareTo(a.startTime));
    final result = await showDialog<(int, String, String?)>(
      context: context,
      builder: (_) => _RateDialog(name: worker.displayName, events: events.take(10).toList(), zone: zone),
    );
    if (result == null || !context.mounted) return;
    await _run(context, ref, 'Rating saved', (repo, s) => repo.addRating(s, worker.id, stars: result.$1, note: result.$2, eventId: result.$3));
  }

  Future<void> _note(BuildContext context, WidgetRef ref) async {
    final text = await _askText(context, title: 'Note about ${worker.displayName}', hint: 'What should other managers know?', action: 'Add note', maxLength: 1000);
    if (text == null || !context.mounted) return;
    await _run(context, ref, 'Note added', (repo, s) => repo.addNote(s, worker.id, text));
  }

  Future<void> _flag(BuildContext context, WidgetRef ref, RehireFlag? existing) async {
    final text = await _askText(
      context,
      title: existing == null ? 'Flag ${worker.displayName} do not rehire?' : 'Edit the reason',
      message: existing == null ? 'They will not be able to be put in any position until the flag is cleared. They are not told.' : null,
      hint: 'Reason (managers only)',
      action: existing == null ? 'Flag' : 'Save',
      initial: existing?.reason ?? '',
      maxLength: 500,
    );
    if (text == null || !context.mounted) return;
    await _run(context, ref, existing == null ? 'Flagged do not rehire' : 'Reason updated', (repo, s) => repo.setDoNotRehire(s, worker.id, text));
  }

  Future<void> _clearFlag(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Clear the flag on ${worker.displayName}?'),
        content: const Text('They can be scheduled again. The flag stays in the audit log.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear flag')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await _run(context, ref, 'Flag cleared', (repo, s) => repo.clearDoNotRehire(s, worker.id));
  }
}

Future<String?> _askText(BuildContext context,
    {required String title, required String hint, required String action, String? message, String initial = '', int maxLength = 500}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (message != null) ...[Text(message, style: AppText.body), const SizedBox(height: 12)],
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              maxLength: maxLength,
              decoration: InputDecoration(hintText: hint),
              onChanged: (_) => setState(() {}),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: controller.text.trim().isEmpty ? null : () => Navigator.pop(context, controller.text.trim()),
            child: Text(action),
          ),
        ],
      ),
    ),
  );
}

class _RateDialog extends StatefulWidget {
  const _RateDialog({required this.name, required this.events, required this.zone});

  final String name;
  final List<Event> events;
  final String zone;

  @override
  State<_RateDialog> createState() => _RateDialogState();
}

class _RateDialogState extends State<_RateDialog> {
  int _stars = 0;
  String? _event;
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _event = widget.events.firstOrNull?.id;
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Rate ${widget.name}'),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 1; i <= 5; i++)
                IconButton(
                  tooltip: '$i star${i == 1 ? '' : 's'}',
                  onPressed: () => setState(() => _stars = i),
                  icon: Icon(i <= _stars ? Icons.star : Icons.star_border, color: AppColors.warn, size: 32),
                ),
            ]),
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              initialValue: _event,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Event (optional)'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Not about one event')),
                for (final e in widget.events)
                  DropdownMenuItem<String?>(
                    value: e.id,
                    child: Text('${DateFormat('MMM d').format(atVenue(e.startTime, widget.zone))} · ${e.name}', overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => _event = v),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _note,
              minLines: 2,
              maxLines: 4,
              maxLength: 500,
              decoration: const InputDecoration(hintText: 'Note (optional)'),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: _stars == 0 ? null : () => Navigator.pop(context, (_stars, _note.text.trim(), _event)),
            child: const Text('Save rating'),
          ),
        ],
      );
}
