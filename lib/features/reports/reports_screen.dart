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
import '../../data/performance_repository.dart';
import '../pay/pay_logic.dart' show money;
import 'reports_labor.dart';

Tone ragTone(Rag rag) => switch (rag) {
      Rag.green => Tone.good,
      Rag.yellow => Tone.warn,
      Rag.red => Tone.bad,
      Rag.none => Tone.idle,
    };

/// Event numbers added up for one season.
class SeasonTotals {
  SeasonTotals(this.season);

  final Season season;
  int events = 0;
  int needed = 0;
  int assigned = 0;
  int attended = 0;
  int late = 0;
  int noShows = 0;
  int? laborCostCents;
  int? budgetCents;

  double? get fillRate => needed == 0 ? null : assigned / needed;
  double? get attendanceRate => assigned == 0 ? null : attended / assigned;
}

/// Event KPIs added up by season, newest first.
List<SeasonTotals> seasonTotals(Iterable<(DateTime localStart, EventKpis kpis)> rows, {int startMonth = Season.defaultStartMonth}) {
  final bySeason = <Season, SeasonTotals>{};
  for (final (start, k) in rows) {
    final s = bySeason.putIfAbsent(Season.of(start, startMonth: startMonth), () => SeasonTotals(Season.of(start, startMonth: startMonth)));
    s.events++;
    s.needed += k.needed;
    s.assigned += k.assigned;
    s.attended += k.attended;
    s.late += k.late;
    s.noShows += k.noShows;
    if (k.laborCostCents != null) s.laborCostCents = (s.laborCostCents ?? 0) + k.laborCostCents!;
    if (k.budgetCents != null) s.budgetCents = (s.budgetCents ?? 0) + k.budgetCents!;
  }
  return bySeason.values.toList()..sort((a, b) => b.season.compareTo(a.season));
}

String _budgetLabel(Rag rag) => switch (rag) {
      Rag.green => 'on track',
      Rag.yellow => 'near limit',
      Rag.red => 'over',
      Rag.none => 'no budget',
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
    required this.performance,
    required this.workerNames,
  });

  /// One per finished or live event.
  final List<EventKpis> events;

  /// Local start date of each event, by event id.
  final Map<String, DateTime> localStarts;

  /// Outcomes, ratings and do-not-rehire flags; null when the viewer cannot see staff.
  final PerformanceData? performance;

  /// Names of the people in [performance]; empty when the viewer cannot see staff.
  final Map<String, String> workerNames;
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

  final kpis = <EventKpis>[];
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
  }

  // Outcomes, ratings and flags come from the performance area, which keeps one
  // definition of what counts as on time, a no-show or a call-off.
  final names = <String, String>{};
  PerformanceData? performance;
  if (session.canVenueWide(Perm.viewWorkers)) {
    for (final w in await repo.listWorkers(session)) {
      names[w.id] = w.displayName;
    }
    performance = await (repo as PerformanceRepository).loadPerformance(session);
  }
  return ReportsData(events: kpis, localStarts: localStarts, performance: performance, workerNames: names);
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
    final seasons = seasonTotals(
      [
        for (final k in d.events)
          if (d.localStarts[k.eventId] != null) (d.localStarts[k.eventId]!, k),
      ],
      startMonth: Season.startMonthFrom(ref.read(sessionProvider)!.venue.settings),
    );
    return [
      for (final s in seasons) _SeasonTile(totals: s, targets: targets),
    ];
  }

  List<Widget> _peopleRows(ReportsData d) {
    final p = d.performance;
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
      ..sort((a, b) => (a.score ?? 101).compareTo(b.score ?? 101));
    return [
      for (final r in people)
        _ReliabilityTile(
          record: r,
          name: d.workerNames[r.workerId] ?? 'Staff member',
          stars: avgStars(r.workerId),
          rehireBlockReason: p.flags[r.workerId]?.reason,
          canManage: canManage,
          onRate: () => _rate(r.workerId),
          onFlag: () => _flag(r.workerId),
          onClear: () => _clearFlag(r.workerId),
        ),
    ];
  }

  PerformanceRepository get _performance => ref.read(repositoryProvider) as PerformanceRepository;

  Future<void> _rate(String workerId) async {
    final session = ref.read(sessionProvider)!;
    final chosen = await showDialog<(int, String)>(context: context, builder: (_) => const _RateDialog());
    if (chosen == null) return;
    try {
      await _performance.addRating(session, workerId, stars: chosen.$1, note: chosen.$2);
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
      await _performance.setDoNotRehire(session, workerId, reason);
      ref.invalidate(reportsDataProvider);
      if (mounted) showMessage(context, 'Flagged do not rehire');
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  Future<void> _clearFlag(String workerId) async {
    final session = ref.read(sessionProvider)!;
    try {
      await _performance.clearDoNotRehire(session, workerId);
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
    final fillRag = targets.fill(kpis.fillRate);
    final attRag = targets.attendance(kpis.attendanceRate);
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
            StatusTag('Fill ${_percent(kpis.fillRate)}', ragTone(fillRag)),
            StatusTag('Attendance ${_percent(kpis.attendanceRate)}', ragTone(attRag)),
            if (kpis.laborCostCents != null && kpis.budgetCents != null)
              StatusTag('Budget ${_budgetLabel(targets.budget(kpis.laborCostCents!, kpis.budgetCents))}',
                  ragTone(targets.budget(kpis.laborCostCents!, kpis.budgetCents))),
          ]),
        ],
      ),
    );
  }
}

class _SeasonTile extends StatelessWidget {
  const _SeasonTile({required this.totals, required this.targets});

  final SeasonTotals totals;
  final ReportTargets targets;

  @override
  Widget build(BuildContext context) {
    final s = totals;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen, vertical: 6),
      isThreeLine: true,
      title: Text('Season ${s.season.label}'),
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
            StatusTag('Fill ${_percent(s.fillRate)}', ragTone(targets.fill(s.fillRate))),
            StatusTag('Attendance ${_percent(s.attendanceRate)}', ragTone(targets.attendance(s.attendanceRate))),
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
