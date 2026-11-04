import 'package:flutter/material.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/download.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/performance_repository.dart';
import '../../data/reports_repository.dart';
import '../pay/pay_logic.dart' show money;
import '../schedule/schedule_actions.dart' show workerTypeLabel;

Tone ragTone(Rag rag) => switch (rag) {
      Rag.green => Tone.good,
      Rag.yellow => Tone.warn,
      Rag.red => Tone.bad,
      Rag.none => Tone.idle,
    };

String _percent(double? v) => v == null ? '—' : '${(v * 100).round()}%';
String _hours(int minutes) => '${(minutes / 60).round()}h';

/// A fraction as the percent people type, without trailing zeros: 0.98 -> "98".
String _typedPercent(double v) {
  final p = double.parse((v * 100).toStringAsFixed(2));
  return p == p.roundToDouble() ? '${p.round()}' : '$p';
}

String _budgetLabel(Rag rag) => switch (rag) {
      Rag.green => 'on track',
      Rag.yellow => 'near limit',
      Rag.red => 'over',
      Rag.none => 'no budget',
    };

final reportTargetsProvider = FutureProvider.autoDispose<ReportTargets>((ref) {
  final session = ref.watch(sessionProvider)!;
  return ref.read(repositoryProvider).loadReportTargets(session);
});

/// Which season the reports cover. 0 is the current season, 1 the one before.
final reportSeasonBackProvider = StateProvider<int>((ref) => 0);

Season _season(AppSession session, int back) {
  final startMonth = Season.startMonthFrom(session.venue.settings);
  final today = venueDate(DateTime.now().toUtc(), session.venue.timeZone);
  final current = Season.of(today, startMonth: startMonth);
  return Season(current.startYear - back, startMonth: startMonth);
}

class ReportsBundle {
  const ReportsBundle({required this.report, required this.season, required this.performance, required this.workerNames});

  final ReportResult report;
  final Season season;

  /// Outcomes, ratings and flags; null when the viewer cannot see staff.
  final PerformanceData? performance;
  final Map<String, String> workerNames;
}

final reportsProvider = FutureProvider.autoDispose<ReportsBundle>((ref) async {
  final session = ref.watch(sessionProvider)!;
  final repo = ref.read(repositoryProvider);
  final venue = await ref.watch(venueProvider.future);
  final season = _season(session, ref.watch(reportSeasonBackProvider));
  final data = await (repo as ReportsRepository).loadReportData(session, season.firstDay, season.lastDay);

  final report = buildReport(
    data: data,
    rules: venue.rules,
    timeZone: session.venue.timeZone,
    from: season.firstDay,
    to: season.lastDay,
    now: DateTime.now().toUtc(),
    jobRoles: venue.jobRoles,
  );

  final names = <String, String>{};
  PerformanceData? performance;
  if (session.canVenueWide(Perm.viewWorkers)) {
    for (final w in await repo.listWorkers(session)) {
      names[w.id] = w.displayName;
    }
    performance = await (repo as PerformanceRepository).loadPerformance(session);
  }
  return ReportsBundle(report: report, season: season, performance: performance, workerNames: names);
});

enum _View { overview, events, people }

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  _View _view = _View.overview;

  PerformanceRepository get _performance => ref.read(repositoryProvider) as PerformanceRepository;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider)!;
    final async = ref.watch(reportsProvider);
    final targets = ref.watch(reportTargetsProvider).value ?? ReportTargets.defaults;
    final back = ref.watch(reportSeasonBackProvider);
    final canPeople = session.canVenueWide(Perm.viewWorkers);

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(reportsProvider);
            ref.invalidate(reportTargetsProvider);
          },
          child: ListView(
            padding: const EdgeInsets.only(bottom: 48),
            children: [
              ScreenHeader(
                kicker: session.venue.name,
                title: 'Reports',
                subtitle: async.value?.season.rangeLabel,
                actions: [
                  if (session.canVenueWide('manage_settings'))
                    TextButton.icon(
                      onPressed: () => _editTargets(context, ref, targets),
                      icon: const Icon(Icons.tune),
                      label: const Text('Targets'),
                    ),
                  if (async.hasValue)
                    TextButton.icon(
                      onPressed: () => _export(async.value!, targets, csv: true),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('CSV'),
                    ),
                  if (async.hasValue)
                    TextButton.icon(
                      onPressed: () => _export(async.value!, targets, csv: false),
                      icon: const Icon(Icons.print_outlined),
                      label: const Text('Print / PDF'),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SegmentedButton<_View>(
                      segments: [
                        const ButtonSegment(value: _View.overview, label: Text('Overview')),
                        const ButtonSegment(value: _View.events, label: Text('Events')),
                        if (canPeople) const ButtonSegment(value: _View.people, label: Text('People')),
                      ],
                      selected: {_view},
                      onSelectionChanged: (v) => setState(() => _view = v.first),
                    ),
                    DropdownButton<int>(
                      value: back,
                      underline: const SizedBox.shrink(),
                      items: [
                        for (final b in const [0, 1, 2])
                          DropdownMenuItem(value: b, child: Text('Season ${_season(session, b).label}')),
                      ],
                      onChanged: (v) => ref.read(reportSeasonBackProvider.notifier).state = v ?? 0,
                    ),
                  ],
                ),
              ),
              ...async.when(
                loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
                error: (e, _) => [ErrorNote(e, onRetry: () => ref.invalidate(reportsProvider))],
                data: (b) => switch (_view) {
                  _View.overview => _overview(b, targets, session),
                  _View.events => _eventRows(b, targets, session),
                  _View.people => _peopleRows(b),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- Overview ----

  List<Widget> _overview(ReportsBundle b, ReportTargets targets, AppSession session) {
    final t = b.report.total;
    if (!t.hasActivity) return [const EmptyNote('No events held this season yet.')];
    final zone = session.venue.timeZone;
    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen, vertical: 8),
        child: Wrap(spacing: 10, runSpacing: 10, children: [
          StatTile(label: 'Events held', value: '${t.events}', detail: '${b.report.upcomingEvents.length} upcoming'),
          StatTile(
            label: 'Fill rate',
            value: _percent(t.fillRate),
            detail: '${t.staffed}/${t.planned} positions',
            tone: ragTone(targets.fill(t.fillRate)),
          ),
          StatTile(
            label: 'On time',
            value: _percent(t.onTimeRate),
            detail: '${t.late} late · ${t.noShows} no-shows · ${t.callOffs} call-offs',
            tone: ragTone(targets.attendance(t.onTimeRate)),
          ),
          StatTile(label: 'Hours worked', value: _hours(t.workedMinutes), detail: '${_percent(t.overtimeShare)} overtime'),
          StatTile(
            label: 'Break compliance',
            value: _percent(t.breakComplianceRate),
            detail: '${t.breakExceptions} of ${t.breaksDue} missed, late or short',
            tone: ragTone(rateRag(t.breakComplianceRate, green: 0.98, yellow: 0.9)),
          ),
          if (b.report.hasMoney) ...[
            StatTile(
              label: 'Labor cost',
              value: money(t.laborCents),
              detail: t.budgets == 0 ? 'no budget set' : '${money(t.budgetCents)} budget',
              tone: t.budgets == 0 ? Tone.idle : ragTone(targets.budget(t.budgetedCostCents, t.budgetCents)),
            ),
            if (t.costPerAttendeeCents != null)
              StatTile(label: 'Cost per attendee', value: money(t.costPerAttendeeCents!), detail: '${t.attendees} attended'),
            if (t.tipsCents > 0) StatTile(label: 'Tips', value: money(t.tipsCents), detail: 'not labor cost'),
          ],
        ]),
      ),
      const SectionHeading('Staffing mix'),
      for (final e in b.report.byWorkerType.entries)
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
          title: Text(workerTypeLabel(e.key)),
          subtitle: Text('${e.value.staffed} positions · ${_hours(e.value.workedMinutes)}'),
          trailing: b.report.hasMoney ? Text(money(e.value.laborCents), style: AppText.meta) : null,
        ),
      if (b.report.npoGroups.isNotEmpty) ...[
        const SectionHeading('Nonprofit groups'),
        for (final g in b.report.npoGroups)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
            title: Text(ref.read(venueProvider).value?.npoName(g.groupId) ?? 'Group'),
            subtitle: Text('${_hours(g.totals.workedMinutes)} · ${g.payouts} payouts${g.estimated > 0 ? ' · ${g.estimated} estimated' : ''}'),
            trailing: Text('${money(g.owedCents)} owed', style: AppText.meta),
          ),
      ],
      if (b.report.tips.isNotEmpty) ...[
        const SectionHeading('Tips, most first'),
        for (final w in b.report.tips.take(10))
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
            title: Text(b.workerNames[w.workerId] ?? 'Staff member'),
            subtitle: Text('${w.events} events · ${(w.hoursHundredths / 100).toStringAsFixed(1)}h'),
            trailing: Text('${money(w.cents)}${w.centsPerHour == null ? '' : ' · ${money(w.centsPerHour!)}/h'}', style: AppText.meta),
          ),
      ],
      Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.screen, 16, AppSpace.screen, 0),
        child: Text(
          'Season ${b.season.label} (${b.season.rangeLabel}), venue time ($zone). '
          '${b.report.hasMoney ? '' : 'Money is left out because you cannot see pay. '}'
          '${b.report.npoPayoutsEstimated > 0 ? '${b.report.npoPayoutsEstimated} payouts are estimated from time records. ' : ''}'
          '${b.report.tipPoolsEstimated > 0 ? '${b.report.tipPoolsEstimated} tip pools are estimated. ' : ''}',
          style: AppText.meta,
        ),
      ),
    ];
  }

  // ---- Events ----

  List<Widget> _eventRows(ReportsBundle b, ReportTargets targets, AppSession session) {
    if (b.report.events.isEmpty) return [const EmptyNote('No events this season.')];
    final zone = session.venue.timeZone;
    final day = DateFormat('EEE MMM d');
    final shown = [...b.report.events]..sort((x, y) => y.event.startTime.compareTo(x.event.startTime));
    return [
      for (final e in shown)
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen, vertical: 6),
          isThreeLine: true,
          title: Text(e.event.name),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${day.format(atVenue(e.event.startTime, zone))}${e.upcoming ? ' · upcoming' : ''}', style: AppText.meta),
              Text(
                'Staffed ${e.total.staffed}/${e.total.planned}'
                '${e.upcoming ? '' : ' · On time ${e.total.onTime} · Late ${e.total.late} · No-shows ${e.total.noShows}'}',
              ),
              if (!e.upcoming && b.report.hasMoney && e.total.laborCents > 0)
                Text(
                  'Labor ${money(e.total.laborCents)}'
                  '${e.eventBudgetCents == null ? '' : ' of ${money(e.eventBudgetCents!)}'}'
                  '${e.total.costPerAttendeeCents == null ? '' : ' · ${money(e.total.costPerAttendeeCents!)} per attendee'}',
                  style: AppText.meta,
                ),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                StatusTag('Fill ${_percent(e.total.fillRate)}', ragTone(targets.fill(e.total.fillRate))),
                if (!e.upcoming) StatusTag('On time ${_percent(e.total.onTimeRate)}', ragTone(targets.attendance(e.total.onTimeRate))),
                if (!e.upcoming && e.eventBudgetCents != null)
                  StatusTag(
                    'Budget ${_budgetLabel(targets.budget(e.total.laborCents, e.eventBudgetCents))}',
                    ragTone(targets.budget(e.total.laborCents, e.eventBudgetCents)),
                  ),
              ]),
            ],
          ),
        ),
    ];
  }

  // ---- People ----

  List<Widget> _peopleRows(ReportsBundle b) {
    final p = b.performance;
    if (p == null) return [const EmptyNote('You cannot see staff records.')];
    if (p.outcomes.isEmpty) return [const EmptyNote('No assigned shifts yet.')];
    final canManage = ref.read(sessionProvider)!.canVenueWide(Perm.manageWorkers);
    final stars = <String, (int sum, int count)>{};
    for (final r in p.ratings) {
      final s = stars[r.workerId] ?? (0, 0);
      stars[r.workerId] = (s.$1 + r.stars, s.$2 + 1);
    }
    double? avgStars(String id) {
      final s = stars[id];
      return s == null ? null : s.$1 / s.$2;
    }

    // Lowest scores first, then people with too few events to score.
    final people = [for (final id in {for (final o in p.outcomes) o.workerId}) reliabilityOf(id, p.outcomes, rules: p.rules, now: p.now)]
      ..sort((x, y) => (x.score ?? 101).compareTo(y.score ?? 101));
    return [
      for (final r in people)
        _ReliabilityTile(
          record: r,
          name: b.workerNames[r.workerId] ?? 'Staff member',
          stars: avgStars(r.workerId),
          rehireBlockReason: p.flags[r.workerId]?.reason,
          canManage: canManage,
          onRate: () => _rate(r.workerId),
          onFlag: () => _flag(r.workerId),
          onClear: () => _clearFlag(r.workerId),
        ),
    ];
  }

  // ---- Exports ----

  List<ReportTable> _tables(ReportsBundle b, ReportTargets targets) {
    final zone = ref.read(sessionProvider)!.venue.timeZone;
    final day = DateFormat('yyyy-MM-dd');
    final t = b.report.total;
    final hasMoney = b.report.hasMoney;

    return [
      ReportTable(
        title: 'Season ${b.season.label}',
        columns: const ['Measure', 'Value', 'Detail'],
        rows: [
          ['Events held', '${t.events}', '${b.report.upcomingEvents.length} upcoming'],
          ['Positions planned', '${t.planned}', '${t.staffed} staffed, ${t.open} open'],
          ['Fill rate', _percent(t.fillRate), '${t.open} positions never filled'],
          ['On-time rate', _percent(t.onTimeRate), '${t.late} late, ${t.noShows} no-shows, ${t.callOffs} call-offs'],
          ['Hours worked', _hours(t.workedMinutes), '${_percent(t.overtimeShare)} overtime'],
          ['Break compliance', _percent(t.breakComplianceRate), '${t.breakExceptions} of ${t.breaksDue}'],
          if (hasMoney) ['Labor cost', money(t.laborCents), t.budgets == 0 ? 'no budget' : '${money(t.budgetCents)} budget'],
          if (hasMoney && t.costPerAttendeeCents != null) ['Cost per attendee', money(t.costPerAttendeeCents!), '${t.attendees} attended'],
        ],
      ),
      ReportTable(
        title: 'Events',
        columns: [
          'Date', 'Event', 'Planned', 'Staffed', 'Fill %', 'On time', 'Late', 'No-shows', 'Hours',
          if (hasMoney) ...['Labor', 'Budget'],
        ],
        rows: [
          for (final e in b.report.events)
            [
              day.format(atVenue(e.event.startTime, zone)),
              e.event.name,
              '${e.total.planned}',
              '${e.total.staffed}',
              _percent(e.total.fillRate),
              '${e.total.onTime}',
              '${e.total.late}',
              '${e.total.noShows}',
              _hours(e.total.workedMinutes),
              if (hasMoney) ...[money(e.total.laborCents), e.eventBudgetCents == null ? '' : money(e.eventBudgetCents!)],
            ],
        ],
      ),
      if (b.performance != null)
        ReportTable(
          title: 'People',
          columns: const ['Name', 'Reliability', 'On time', 'Late', 'No-shows', 'Call-offs', 'Do not rehire'],
          rows: [
            for (final id in {for (final o in b.performance!.outcomes) o.workerId})
              () {
                final s = reliabilityOf(id, b.performance!.outcomes, rules: b.performance!.rules, now: b.performance!.now);
                final c = AttendanceSummary(s.counted);
                return [
                  b.workerNames[id] ?? 'Staff member',
                  s.score == null ? 'New' : '${s.score}',
                  '${c.onTime}',
                  '${c.late}',
                  '${c.noShows}',
                  '${c.callOffs}',
                  b.performance!.flags[id]?.reason ?? '',
                ];
              }(),
          ],
        ),
    ];
  }

  Future<void> _export(ReportsBundle b, ReportTargets targets, {required bool csv}) async {
    final venue = ref.read(sessionProvider)!.venue.name;
    final tables = _tables(b, targets);
    final name = 'reports-${b.season.label.replaceAll('–', '-')}';
    final ok = csv
        ? await saveTextFile('$name.csv', tablesToCsv(tables))
        : await saveTextFile(
            '$name.html',
            reportHtml(title: '$venue — season ${b.season.label}', subtitle: b.season.rangeLabel, tables: tables),
            mimeType: 'text/html',
          );
    if (!mounted || !ok) return;
    showMessage(context, csv ? 'Saved $name.csv' : 'Saved $name.html — open it and print to PDF');
  }

  // ---- Actions ----

  Future<void> _rate(String workerId) async {
    final session = ref.read(sessionProvider)!;
    final chosen = await showDialog<(int, String)>(context: context, builder: (_) => const _RateDialog());
    if (chosen == null) return;
    try {
      await _performance.addRating(session, workerId, stars: chosen.$1, note: chosen.$2);
      ref.invalidate(reportsProvider);
      if (mounted) showMessage(context, 'Rating saved');
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  Future<void> _flag(String workerId) async {
    final session = ref.read(sessionProvider)!;
    final reason = await askReason(
      context,
      title: 'Do not rehire',
      hint: 'Reason',
      action: 'Flag',
      suggestions: const ['No-call, no-show', 'Left without notice', 'Conduct', 'Safety'],
      message: 'This shows on the reports and blocks them from being scheduled.',
    );
    if (reason == null || reason.trim().isEmpty) return;
    try {
      await _performance.setDoNotRehire(session, workerId, reason);
      ref.invalidate(reportsProvider);
      if (mounted) showMessage(context, 'Flagged do not rehire');
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  Future<void> _clearFlag(String workerId) async {
    final session = ref.read(sessionProvider)!;
    try {
      await _performance.clearDoNotRehire(session, workerId);
      ref.invalidate(reportsProvider);
      if (mounted) showMessage(context, 'Flag cleared');
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }
}

Future<void> _editTargets(BuildContext context, WidgetRef ref, ReportTargets current) async {
  final session = ref.read(sessionProvider)!;
  final chosen = await showDialog<ReportTargets>(context: context, builder: (_) => _TargetsDialog(current: current));
  if (chosen == null) return;
  try {
    await ref.read(repositoryProvider).saveReportTargets(session, chosen);
    ref.invalidate(reportTargetsProvider);
    if (context.mounted) showMessage(context, 'Targets saved');
  } on AppFailure catch (e) {
    if (context.mounted) showMessage(context, e.message);
  }
}

class _TargetsDialog extends StatefulWidget {
  const _TargetsDialog({required this.current});

  final ReportTargets current;

  @override
  State<_TargetsDialog> createState() => _TargetsDialogState();
}

class _TargetsDialogState extends State<_TargetsDialog> {
  late final _fillGreen = TextEditingController(text: _typedPercent(widget.current.fillGreen));
  late final _fillYellow = TextEditingController(text: _typedPercent(widget.current.fillYellow));
  late final _attGreen = TextEditingController(text: _typedPercent(widget.current.attendanceGreen));
  late final _attYellow = TextEditingController(text: _typedPercent(widget.current.attendanceYellow));
  String? _error;

  @override
  void dispose() {
    for (final c in [_fillGreen, _fillYellow, _attGreen, _attYellow]) {
      c.dispose();
    }
    super.dispose();
  }

  double? _read(TextEditingController c) {
    final v = double.tryParse(c.text.trim());
    return v == null ? null : v / 100;
  }

  void _save() {
    final fg = _read(_fillGreen), fy = _read(_fillYellow), ag = _read(_attGreen), ay = _read(_attYellow);
    if (fg == null || fy == null || ag == null || ay == null) {
      setState(() => _error = 'Enter each target as a percentage.');
      return;
    }
    final t = widget.current.copyWith(fillGreen: fg, fillYellow: fy, attendanceGreen: ag, attendanceYellow: ay);
    final problem = t.validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(t);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Report targets'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Green at or above the first number, yellow at or above the second, red below.'),
          const SizedBox(height: 12),
          TextField(controller: _fillGreen, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Fill rate green %')),
          TextField(controller: _fillYellow, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Fill rate yellow %')),
          TextField(controller: _attGreen, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'On-time green %')),
          TextField(controller: _attYellow, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'On-time yellow %')),
          if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: AppText.meta)],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _RateDialog extends StatefulWidget {
  const _RateDialog();

  @override
  State<_RateDialog> createState() => _RateDialogState();
}

class _RateDialogState extends State<_RateDialog> {
  int _stars = 4;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rate'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButton<int>(
            value: _stars,
            items: [for (var s = 1; s <= 5; s++) DropdownMenuItem(value: s, child: Text('$s star${s == 1 ? '' : 's'}'))],
            onChanged: (v) => setState(() => _stars = v ?? _stars),
          ),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note (optional)'), maxLength: 500),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop((_stars, _note.text.trim())), child: const Text('Save')),
      ],
    );
  }
}

class _ReliabilityTile extends StatelessWidget {
  const _ReliabilityTile({
    required this.record,
    required this.name,
    required this.stars,
    required this.rehireBlockReason,
    required this.canManage,
    required this.onRate,
    required this.onFlag,
    required this.onClear,
  });

  final ReliabilityScore record;
  final String name;
  final double? stars;
  final String? rehireBlockReason;
  final bool canManage;
  final VoidCallback onRate;
  final VoidCallback onFlag;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final r = record;
    final flagged = rehireBlockReason != null;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen, vertical: 6),
      isThreeLine: flagged,
      title: Text(name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${r.breakdown}${stars == null ? '' : ' · ${stars!.toStringAsFixed(1)} stars'}'),
          if (flagged) Text('Do not rehire: ${rehireBlockReason!}', style: AppText.meta),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusTag(
            r.score == null ? 'New' : '${r.score}',
            r.score == null ? Tone.idle : ragTone(rateRag(r.score! / 100, green: 0.9, yellow: 0.8)),
          ),
          if (canManage)
            PopupMenuButton<String>(
              onSelected: (v) => switch (v) {
                'rate' => onRate(),
                'flag' => onFlag(),
                _ => onClear(),
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rate', child: Text('Rate…')),
                if (flagged)
                  const PopupMenuItem(value: 'clear', child: Text('Clear do not rehire'))
                else
                  const PopupMenuItem(value: 'flag', child: Text('Do not rehire…')),
              ],
            ),
        ],
      ),
    );
  }
}
