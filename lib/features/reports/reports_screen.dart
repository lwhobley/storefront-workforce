import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/download.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../pay/pay_logic.dart' show money;
import 'reports_labor.dart';

Tone kpiTone(KpiBand? band) => switch (band) {
      KpiBand.green => Tone.good,
      KpiBand.yellow => Tone.warn,
      KpiBand.red => Tone.bad,
      null => Tone.idle,
    };

/// Reliability bands: 90% on time is green, 80% yellow.
const reliabilityTarget = KpiTarget(green: 0.9, yellow: 0.8);

Tone _budgetTone(BudgetStatus s) => switch (s) {
      BudgetStatus.under => Tone.good,
      BudgetStatus.near => Tone.warn,
      BudgetStatus.over => Tone.bad,
    };

String _budgetLabel(BudgetStatus s) => switch (s) {
      BudgetStatus.under => 'on track',
      BudgetStatus.near => 'near limit',
      BudgetStatus.over => 'over',
    };

String _percent(double? v) => v == null ? '—' : '${(v * 100).round()}%';

/// A fraction as the percent people type, without trailing zeros: 0.98 -> "98", 0.985 -> "98.5".
String _typedPercent(double v) {
  final p = double.parse((v * 100).toStringAsFixed(2));
  return p == p.roundToDouble() ? '${p.round()}' : '$p';
}

final reportTargetsProvider = FutureProvider.autoDispose<ReportTargets>((ref) {
  final session = ref.watch(sessionProvider)!;
  return ref.read(repositoryProvider).loadReportTargets(session);
});

/// Everything the reports show, worked out from finished and live events.
class ReportsData {
  const ReportsData({
    required this.events,
    required this.localStarts,
    required this.outcomes,
    required this.workerNames,
    required this.averageStars,
    required this.rehireFlags,
  });

  /// One per finished or live event.
  final List<EventKpis> events;

  /// Local start date of each event, by event id.
  final Map<String, DateTime> localStarts;

  /// One entry per person and event they were scheduled for.
  final List<ShiftOutcome> outcomes;

  /// Names of the people in [outcomes]; empty when the viewer cannot see staff.
  final Map<String, String> workerNames;

  /// Average stars by person; people with no ratings are missing.
  final Map<String, double> averageStars;

  /// Reason by person for those flagged do-not-rehire.
  final Map<String, String> rehireFlags;
}

final reportsDataProvider = FutureProvider.autoDispose<ReportsData>((ref) async {
  final session = ref.watch(sessionProvider)!;
  final repo = ref.read(repositoryProvider);
  final venue = await ref.watch(venueProvider.future);
  final events = await ref.watch(eventsProvider.future);
  final zone = session.venue.timeZone;
  final done = [
    for (final e in events)
      if (e.status == EventStatus.completed || e.status == EventStatus.live) e,
  ];
  final boards = await Future.wait([for (final e in done) repo.loadBoard(e.id)]);
  // Labor cost needs the pay setup, so it is only worked out for people who can view pay.
  var labor = <String, LaborCostReport>{};
  if (session.canVenueWide('view_pay')) {
    await repo.ensurePayPeriods(session, DateTime.now().toUtc());
    final setup = await repo.loadPaySetup(session);
    labor = await laborCostByEvent(repo: repo, session: session, venue: venue, setup: setup, events: done);
  }

  final now = DateTime.now().toUtc();
  final kpis = <EventKpis>[];
  final outcomes = <ShiftOutcome>[];
  final localStarts = <String, DateTime>{};
  for (final b in boards) {
    final id = b.event.id;
    localStarts[id] = venueDate(b.event.startTime, zone);
    kpis.add(calculateEventKpis(
      eventId: id,
      shifts: b.shifts,
      needs: b.needs,
      punches: b.punches,
      attendance: session.rules.attendance,
      labor: labor[id],
    ));
    outcomes.addAll(attendanceOutcomes(
      shifts: b.shifts,
      punches: b.punches,
      changes: b.changes,
      rules: session.rules.attendance,
      now: now,
    ));
  }

  final names = <String, String>{};
  var averages = <String, double>{};
  var flags = <String, String>{};
  if (session.canVenueWide(Perm.viewWorkers)) {
    for (final w in await repo.listWorkers(session)) {
      names[w.id] = w.displayName;
    }
    averages = averageRatings(await repo.loadWorkerRatings(session));
    flags = await repo.loadRehireFlags(session);
  }
  return ReportsData(
    events: kpis,
    localStarts: localStarts,
    outcomes: outcomes,
    workerNames: names,
    averageStars: averages,
    rehireFlags: flags,
  );
});

enum _ReportView { events, seasons, people }

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  _ReportView _view = _ReportView.events;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider)!;
    final zone = session.venue.timeZone;
    final data = ref.watch(reportsDataProvider);
    final targets = ref.watch(reportTargetsProvider).value ?? ReportTargets.defaults;
    final events = {for (final e in ref.watch(eventsProvider).value ?? const <Event>[]) e.id: e};
    final day = DateFormat('EEE MMM d');
    final canPeople = session.canVenueWide(Perm.viewWorkers);

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(reportsDataProvider);
            ref.invalidate(reportTargetsProvider);
          },
          child: ListView(
            padding: const EdgeInsets.only(bottom: 48),
            children: [
              ScreenHeader(
                kicker: session.venue.name,
                title: 'Reports',
                actions: [
                  if (session.canVenueWide('manage_settings'))
                    TextButton.icon(
                      onPressed: () => _editTargets(context, ref, targets),
                      icon: const Icon(Icons.tune),
                      label: const Text('Targets'),
                    ),
                  if (data.hasValue && data.value!.events.isNotEmpty)
                    TextButton.icon(
                      onPressed: () async {
                        final ok = await saveTextFile('event-kpis.csv', eventKpisCsv(data.value!.events));
                        if (context.mounted && ok) showMessage(context, 'Saved event-kpis.csv');
                      },
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('Export CSV'),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                child: SegmentedButton<_ReportView>(
                  segments: [
                    const ButtonSegment(value: _ReportView.events, label: Text('Events')),
                    const ButtonSegment(value: _ReportView.seasons, label: Text('Seasons')),
                    if (canPeople) const ButtonSegment(value: _ReportView.people, label: Text('People')),
                  ],
                  selected: {_view},
                  onSelectionChanged: (v) => setState(() => _view = v.first),
                ),
              ),
              if (_view == _ReportView.events)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                  child: Text(
                    'Fill rate: green ${_typedPercent(targets.fillGreen)}%+, yellow ${_typedPercent(targets.fillYellow)}%+. '
                    'Attendance: green ${_typedPercent(targets.attendanceGreen)}%+, yellow ${_typedPercent(targets.attendanceYellow)}%+. '
                    'Finished and live events only.',
                    style: AppText.meta,
                  ),
                ),
              ...data.when(
                loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
                error: (e, _) => [ErrorNote(e, onRetry: () => ref.invalidate(reportsDataProvider))],
                data: (d) => switch (_view) {
                  _ReportView.events => _eventRows(d, events, targets, zone, day),
                  _ReportView.seasons => _seasonRows(d, targets),
                  _ReportView.people => _peopleRows(d),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _eventRows(ReportsData d, Map<String, Event> events, ReportTargets targets, String zone, DateFormat day) {
    if (d.events.isEmpty) return [const EmptyNote('No finished or live events yet.')];
    final sorted = [...d.events]..sort((a, b) {
        final ta = events[a.eventId]?.startTime ?? DateTime.utc(1900);
        final tb = events[b.eventId]?.startTime ?? DateTime.utc(1900);
        return tb.compareTo(ta);
      });
    return [
      for (final k in sorted) _EventKpiTile(kpis: k, event: events[k.eventId], targets: targets, zone: zone, day: day),
    ];
  }

  List<Widget> _seasonRows(ReportsData d, ReportTargets targets) {
    if (d.events.isEmpty) return [const EmptyNote('No finished or live events yet.')];
    final seasons = seasonSummaries([
      for (final k in d.events)
        if (d.localStarts[k.eventId] != null) (d.localStarts[k.eventId]!, k),
    ]);
    return [
      for (final s in seasons) _SeasonTile(summary: s, targets: targets),
    ];
  }

  List<Widget> _peopleRows(ReportsData d) {
    if (d.outcomes.isEmpty) return [const EmptyNote('No assigned shifts yet.')];
    final canManage = ref.read(sessionProvider)!.canVenueWide(Perm.manageWorkers);
    final people = reliabilityOf(d.outcomes)
        .where((r) => r.expected > 0)
        .toList()
      ..sort((a, b) => a.score!.compareTo(b.score!));
    return [
      for (final r in people)
        _ReliabilityTile(
          record: r,
          name: d.workerNames[r.workerId] ?? 'Staff member',
          stars: d.averageStars[r.workerId],
          rehireBlockReason: d.rehireFlags[r.workerId],
          canManage: canManage,
          onRate: () => _rate(r.workerId),
          onFlag: () => _flag(r.workerId),
          onClear: () => _clearFlag(r.workerId),
        ),
    ];
  }

  Future<void> _rate(String workerId) async {
    final session = ref.read(sessionProvider)!;
    final chosen = await showDialog<(int, String)>(context: context, builder: (_) => const _RateDialog());
    if (chosen == null) return;
    try {
      await ref.read(repositoryProvider).rateWorker(session, workerId: workerId, stars: chosen.$1, note: chosen.$2);
      ref.invalidate(reportsDataProvider);
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
      message: 'This shows on the reports and warns when they are scheduled.',
    );
    if (reason == null || reason.trim().isEmpty) return;
    try {
      await ref.read(repositoryProvider).flagDoNotRehire(session, workerId, reason);
      ref.invalidate(reportsDataProvider);
      if (mounted) showMessage(context, 'Flagged do not rehire');
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  Future<void> _clearFlag(String workerId) async {
    final session = ref.read(sessionProvider)!;
    try {
      await ref.read(repositoryProvider).clearDoNotRehire(session, workerId);
      ref.invalidate(reportsDataProvider);
      if (mounted) showMessage(context, 'Flag cleared');
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    }
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

Future<void> _editTargets(BuildContext context, WidgetRef ref, ReportTargets current) async {
  final session = ref.read(sessionProvider)!;
  final chosen = await showDialog<ReportTargets>(
    context: context,
    builder: (_) => _TargetsDialog(current: current),
  );
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
    final fg = _read(_fillGreen);
    final fy = _read(_fillYellow);
    final ag = _read(_attGreen);
    final ay = _read(_attYellow);
    final t = (fg == null || fy == null || ag == null || ay == null)
        ? null
        : ReportTargets.tryCreate(fillGreen: fg, fillYellow: fy, attendanceGreen: ag, attendanceYellow: ay);
    if (t == null) {
      setState(() => _error = 'Enter percentages. Yellow must be at or below green.');
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
          const Text('Green when at or above the first number, yellow at or above the second, red below.'),
          const SizedBox(height: 12),
          TextField(controller: _fillGreen, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Fill rate green %')),
          TextField(controller: _fillYellow, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Fill rate yellow %')),
          TextField(controller: _attGreen, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Attendance green %')),
          TextField(controller: _attYellow, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Attendance yellow %')),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: AppText.meta),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _EventKpiTile extends StatelessWidget {
  const _EventKpiTile({required this.kpis, required this.event, required this.targets, required this.zone, required this.day});

  final EventKpis kpis;
  final Event? event;
  final ReportTargets targets;
  final String zone;
  final DateFormat day;

  @override
  Widget build(BuildContext context) {
    final fillBand = targets.fill.band(kpis.fillRate);
    final attBand = targets.attendance.band(kpis.attendanceRate);
    final mix = kpis.staffingMix.entries.map((e) => '${e.value} ${e.key}').join(', ');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen, vertical: 6),
      isThreeLine: true,
      title: Text(event?.name ?? kpis.eventId),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (event != null) Text(day.format(atVenue(event!.startTime, zone)), style: AppText.meta),
          Text(
            'Staffed ${kpis.assigned}/${kpis.needed} · Attended ${kpis.attended}/${kpis.assigned} · '
            'Late ${kpis.late} · No-shows ${kpis.noShows}',
          ),
          Text(mix.isEmpty ? 'No one assigned' : mix, style: AppText.meta),
          if (kpis.laborCostCents != null)
            Text(
              'Labor ${money(kpis.laborCostCents!)}'
              '${kpis.budgetCents == null ? '' : ' of ${money(kpis.budgetCents!)} budget'}'
              '${kpis.costPerAttendeeCents == null ? '' : ' · ${money(kpis.costPerAttendeeCents!)} per attendee'}',
            ),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            StatusTag('Fill ${_percent(kpis.fillRate)}', kpiTone(fillBand)),
            StatusTag('Attendance ${_percent(kpis.attendanceRate)}', kpiTone(attBand)),
            if (kpis.budgetStatus != null) StatusTag('Budget ${_budgetLabel(kpis.budgetStatus!)}', _budgetTone(kpis.budgetStatus!)),
          ]),
        ],
      ),
    );
  }
}

class _SeasonTile extends StatelessWidget {
  const _SeasonTile({required this.summary, required this.targets});

  final SeasonSummary summary;
  final ReportTargets targets;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen, vertical: 6),
      isThreeLine: true,
      title: Text('Season ${s.label}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${s.events} events · Staffed ${s.assigned}/${s.needed} · Attended ${s.attended}/${s.assigned} · '
            'Late ${s.late} · No-shows ${s.noShows}',
          ),
          if (s.laborCostCents != null)
            Text(
              'Labor ${money(s.laborCostCents!)}${s.budgetCents == null ? '' : ' of ${money(s.budgetCents!)} budget'}',
              style: AppText.meta,
            ),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            StatusTag('Fill ${_percent(s.fillRate)}', kpiTone(targets.fill.band(s.fillRate))),
            StatusTag('Attendance ${_percent(s.attendanceRate)}', kpiTone(targets.attendance.band(s.attendanceRate))),
          ]),
        ],
      ),
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

  final Reliability record;
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
          Text(
            '${r.expected} shifts · On time ${r.onTime} · Late ${r.late} · No-shows ${r.noShows} · Call-offs ${r.callOffs}'
            '${stars == null ? '' : ' · ${stars!.toStringAsFixed(1)} stars'}',
          ),
          if (flagged) Text('Do not rehire: ${rehireBlockReason!}', style: AppText.meta),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusTag(_percent(r.score), kpiTone(reliabilityTarget.band(r.score))),
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
