import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import 'report_tables.dart';
import 'reports_providers.dart';

/// Live KPIs against the venue's targets, for the top of the live view: fill rate, on
/// time (the same outcomes as the reports), missing, and near overtime.
class LiveKpiStrip extends ConsumerWidget {
  const LiveKpiStrip({super.key, required this.board, required this.cards, required this.rules, required this.now, required this.needed, required this.assigned});

  final EventBoard board;
  final List<LiveShiftStatus> cards;
  final VenueRules rules;
  final DateTime now;
  final int needed;
  final int assigned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final targets = ref.watch(reportTargetsProvider).value ?? ReportTargets.defaults;
    final m = liveKpis(board: board, cards: cards, rules: rules, now: now, needed: needed, assigned: assigned);
    final runaway = LaborForecastAI.trackLiveLaborRunaway(
      event: board.event,
      shifts: board.shifts,
      punches: board.punches,
      now: now,
      rules: rules,
    );
    final chips = [
      _chip('Fill', pct(m.fillRate), ragTone(targets.fill(m.fillRate)), 'target ${pct(targets.fillGreen)}'),
      _chip('On time', pct(m.onTimeRate), ragTone(targets.attendance(m.onTimeRate)), 'target ${pct(targets.attendanceGreen)}'),
      _chip('Missing', '${m.missing}', m.missing == 0 ? Tone.good : Tone.bad, null),
      _chip('Near overtime', '${m.nearOvertime}', m.nearOvertime == 0 ? Tone.good : Tone.warn, null),
      if (runaway.budgetCents > 0)
        _chip(
          'AI Labor',
          runaway.isRunaway
              ? 'Runaway (+${runaway.variancePercentage.round()}%)'
              : runaway.isCaution
                  ? 'Caution (+${runaway.variancePercentage.round()}%)'
                  : 'On Track',
          runaway.isRunaway
              ? Tone.bad
              : runaway.isCaution
                  ? Tone.warn
                  : Tone.good,
          'Projected \$${(runaway.projectedFinalCents / 100).toStringAsFixed(0)} vs budget \$${(runaway.budgetCents / 100).toStringAsFixed(0)} (${runaway.recommendation})',
        ),
    ];
    return Semantics(
      container: true,
      label: 'Against targets',
      child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('AGAINST TARGETS', style: AppText.kicker.copyWith(fontSize: 11)),
        ...chips,
      ]),
    );
  }

  Widget _chip(String label, String value, Tone? tone, String? hint) {
    final t = tone ?? Tone.idle;
    return Builder(builder: (context) {
      final chip = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: toneSoft(t, context), borderRadius: BorderRadius.circular(16)),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: '$label ', style: AppText.meta.copyWith(color: AppColors.text)),
          TextSpan(text: value, style: TextStyle(fontWeight: FontWeight.w700, color: toneColor(t, context))),
        ])),
      );
      return hint == null ? chip : Tooltip(message: hint, child: chip);
    });
  }
}

/// The strip's numbers. On time uses [attendanceOutcomes]: people still within the
/// no-show window (pending) are not counted yet.
({double? fillRate, double? onTimeRate, int missing, int nearOvertime}) liveKpis({
  required EventBoard board,
  required List<LiveShiftStatus> cards,
  required VenueRules rules,
  required DateTime now,
  required int needed,
  required int assigned,
}) {
  final summary = AttendanceSummary(attendanceOutcomes(
    shifts: board.shifts,
    punches: [for (final p in board.punches) if (p.eventId == board.event.id) p],
    changes: board.changes,
    rules: rules.attendance,
    now: now,
  ));
  return (
    fillRate: needed == 0 ? null : (assigned > needed ? needed : assigned) / needed,
    onTimeRate: summary.onTimeRate,
    missing: cards.where((c) => c.headline == LiveHeadline.notArrived || c.headline == LiveHeadline.noShow).length,
    nearOvertime: cards.where((c) => (c.overtime.approaching || c.overtime.inOvertime) && c.headline != LiveHeadline.released).length,
  );
}
