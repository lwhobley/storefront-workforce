import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/performance_repository.dart';
import '../schedule/schedule_actions.dart' show workerTypeLabel;
import 'performance_providers.dart';
import 'performance_section.dart';

/// Staff ranked by reliability, rating or events worked, with filters, for deciding
/// who to schedule and rehire. Flagged people are marked.
class RankingsScreen extends ConsumerStatefulWidget {
  const RankingsScreen({super.key});

  @override
  ConsumerState<RankingsScreen> createState() => _RankingsScreenState();
}

class _RankingsScreenState extends ConsumerState<RankingsScreen> {
  RankingSort _sort = RankingSort.reliability;
  WorkerType? _type;
  String? _role;
  String? _storefront;
  String? _group;
  bool _hideFlagged = false;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider)!;
    final venue = ref.watch(venueProvider).value;
    final workersAsync = ref.watch(workersProvider);
    final dataAsync = ref.watch(performanceDataProvider);

    final header = ScreenHeader(
      kicker: 'Staff',
      title: 'Rankings',
      subtitle: dataAsync.value?.rules.explain,
      actions: [
        OutlinedButton.icon(
          onPressed: () => context.canPop() ? context.pop() : context.go('/staff'),
          icon: const Icon(Icons.arrow_back),
          label: const Text('Staff list'),
        ),
      ],
    );

    if (!session.canVenueWide(Perm.viewWorkers)) {
      return const Scaffold(body: SafeArea(child: EmptyNote('Rankings are for managers.')));
    }
    final workers = workersAsync.value;
    final data = dataAsync.value;
    if (workers == null || data == null || venue == null) {
      final error = workersAsync.error ?? dataAsync.error;
      return Scaffold(
        body: SafeArea(
          child: ListView(children: [
            header,
            if (error != null)
              ErrorNote(error, onRetry: () {
                ref.invalidate(workersProvider);
                ref.invalidate(performanceDataProvider);
              })
            else
              const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          ]),
        ),
      );
    }

    final workedAt = <String, Set<String>>{};
    for (final o in data.outcomes) {
      if (o.outcome == AttendanceOutcome.onTime || o.outcome == AttendanceOutcome.late) {
        workedAt.putIfAbsent(o.workerId, () => {}).add(o.storefrontId);
      }
    }
    final active = [for (final w in workers) if (w.status == 'active') w];
    final shownWorkers = [
      for (final w in active)
        if ((_type == null || w.type == _type) &&
            (_role == null || w.jobRoles.contains(_role)) &&
            (_storefront == null || (workedAt[w.id]?.contains(_storefront) ?? false)) &&
            (_group == null || w.npoGroupId == _group) &&
            (!_hideFlagged || !data.flags.containsKey(w.id)) &&
            (_query.isEmpty || w.displayName.toLowerCase().contains(_query) || w.employeeNumber.toLowerCase().contains(_query)))
          w,
    ];
    final entries = sortRankings(
      buildRankings(
        workers: shownWorkers,
        outcomes: data.outcomes,
        ratings: [for (final r in data.ratings) (r.workerId, r.stars)],
        flagged: data.flags.keys.toSet(),
        rules: data.rules,
        now: data.now,
      ),
      _sort,
    );
    final byId = {for (final w in workers) w.id: w};
    final wide = MediaQuery.sizeOf(context).width >= 900;

    // Two dropdowns side by side on a phone.
    final dropWidth = wide ? 220.0 : ((MediaQuery.sizeOf(context).width - 2 * AppSpace.screen - 12) / 2).clamp(140.0, 220.0);
    Widget dropdown<T>(String label, T? value, List<(T, String)> options, ValueChanged<T?> onChanged) => SizedBox(
          width: dropWidth,
          child: DropdownButtonFormField<T?>(
            initialValue: value,
            isExpanded: true,
            isDense: true,
            decoration: InputDecoration(labelText: label),
            items: [
              DropdownMenuItem<T?>(value: null, child: const Text('Any')),
              for (final (v, name) in options) DropdownMenuItem<T?>(value: v, child: Text(name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: onChanged,
          ),
        );

    final filters = Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name or employee number'),
          onChanged: (v) => setState(() => _query = v.toLowerCase()),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final t in [null, ...WorkerType.values])
            ChoiceChip(
              label: Text(t == null ? 'All' : workerTypeLabel(t)),
              selected: _type == t,
              onSelected: (_) => setState(() {
                _type = t;
                if (t != WorkerType.npo) _group = null;
              }),
            ),
          FilterChip(label: const Text('Hide flagged'), selected: _hideFlagged, onSelected: (v) => setState(() => _hideFlagged = v)),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 12, runSpacing: 10, children: [
          dropdown<String>('Role', _role, [for (final r in venue.jobRoles) (r.code, r.name)], (v) => setState(() => _role = v)),
          dropdown<String>(
            'Worked at',
            _storefront,
            [for (final s in venue.storefronts.where((s) => s.active)) (s.id, s.name)],
            (v) => setState(() => _storefront = v),
          ),
          if (_type == WorkerType.npo)
            dropdown<String>('NPO group', _group, [for (final g in venue.npoGroups) (g.id, g.displayName)], (v) => setState(() => _group = v)),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Text('Sort by', style: AppText.meta),
          for (final s in RankingSort.values)
            ChoiceChip(label: Text(s.label), selected: _sort == s, onSelected: (_) => setState(() => _sort = s)),
        ]),
      ]),
    );

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(performanceDataProvider);
            await ref.read(performanceDataProvider.future);
          },
          child: ListView.builder(
            itemCount: entries.length + 2,
            itemBuilder: (context, i) {
              if (i == 0) {
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  header,
                  filters,
                  if (_group != null) _GroupCard(groupId: _group!, name: venue.npoName(_group), data: data, workers: workers),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(AppSpace.screen, 12, AppSpace.screen, 4),
                    child: Text('${entries.length} people', style: AppText.meta),
                  ),
                  if (wide) const _HeaderRow(),
                  const Divider(height: 1),
                ]);
              }
              if (i == entries.length + 1) {
                return entries.isEmpty ? const EmptyNote('No one matches these filters.') : const SizedBox(height: 48);
              }
              final e = entries[i - 1];
              final w = byId[e.workerId]!;
              return _RankRow(rank: i, entry: e, worker: w, wide: wide, data: data, onTap: () => _open(w));
            },
          ),
        ),
      ),
    );
  }

  void _open(Worker w) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        constraints: const BoxConstraints(maxWidth: 720),
        builder: (context) => FractionallySizedBox(
          heightFactor: 0.9,
          child: ListView(padding: const EdgeInsets.fromLTRB(AppSpace.screen, 0, AppSpace.screen, 40), children: [
            Text(w.displayName, style: AppText.screenTitle.copyWith(fontSize: 26)),
            const SizedBox(height: 4),
            Text('${w.employeeNumber} · ${workerTypeLabel(w.type)}', style: AppText.meta),
            const SizedBox(height: 8),
            PerformanceSection(worker: w),
          ]),
        ),
      );
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: AppSpace.screen, vertical: 6),
        child: Row(children: [
          SizedBox(width: 40, child: Text('#', style: AppText.kicker)),
          Expanded(flex: 4, child: Text('NAME', style: AppText.kicker)),
          SizedBox(width: 110, child: Text('RELIABILITY', style: AppText.kicker)),
          SizedBox(width: 110, child: Text('RATING', style: AppText.kicker)),
          SizedBox(width: 80, child: Text('EVENTS', style: AppText.kicker)),
          Expanded(flex: 3, child: Text('RECENT ISSUES', style: AppText.kicker)),
        ]),
      );
}

class _RankRow extends StatelessWidget {
  const _RankRow({required this.rank, required this.entry, required this.worker, required this.wide, required this.data, required this.onTap});

  final int rank;
  final RankingEntry entry;
  final Worker worker;
  final bool wide;
  final PerformanceData data;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = entry.reliability;
    final rating = entry.averageStars == null ? '—' : '${entry.averageStars!.toStringAsFixed(1)} ★ (${entry.ratingCount})';
    final missed = [
      if (s.noShows > 0) '${s.noShows} no-show${s.noShows == 1 ? '' : 's'}',
      if (s.callOffs > 0) '${s.callOffs} call-off${s.callOffs == 1 ? '' : 's'}',
      if (s.lates > 0) '${s.lates} late',
    ].join(' · ');
    final name = Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Text(worker.displayName, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
      if (worker.type != WorkerType.regular) StatusTag(workerTypeLabel(worker.type), Tone.info),
      if (entry.flagged) doNotRehireTag,
    ]);
    final score = Text(
      s.score == null ? '—' : '${s.score}${s.isNew ? ' new' : ''}',
      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: toneColor(s.isNew ? Tone.idle : scoreTone(s.score), context)),
    );

    if (wide) {
      return InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen, vertical: 10),
          child: Row(children: [
            SizedBox(width: 40, child: Text('$rank', style: AppText.meta)),
            Expanded(flex: 4, child: name),
            SizedBox(width: 110, child: score),
            SizedBox(width: 110, child: Text(rating, style: AppText.body)),
            SizedBox(width: 80, child: Text('${entry.eventsWorked}', style: AppText.body)),
            Expanded(flex: 3, child: Text(missed.isEmpty ? '—' : missed, style: AppText.meta)),
          ]),
        ),
      );
    }
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
      leading: SizedBox(width: 28, child: Text('$rank', style: AppText.meta)),
      minLeadingWidth: 28,
      title: name,
      subtitle: Text([
        'Rating $rating · ${entry.eventsWorked} events',
        if (missed.isNotEmpty) missed,
      ].join('\n')),
      trailing: score,
    );
  }
}

/// An NPO group's attendance over the window: members, hours, shifts, no-shows, call-offs.
class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.groupId, required this.name, required this.data, required this.workers});

  final String groupId;
  final String name;
  final PerformanceData data;
  final List<Worker> workers;

  @override
  Widget build(BuildContext context) {
    final groups = groupReliability(
      groupOf: {for (final w in workers) if (w.npoGroupId != null && w.status == 'active') w.id: w.npoGroupId!},
      outcomes: data.outcomes,
      workedMinutes: data.workedMinutes,
      scores: data.scores(),
    );
    final g = groups[groupId] ?? GroupReliability(groupId);
    final rate = g.attendanceRate;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.screen, 12, AppSpace.screen, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.l),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: AppText.sectionHeading),
            Text('Past ${data.rules.windowDays == 365 ? 'year' : '${data.rules.windowDays} days'}', style: AppText.meta),
            const SizedBox(height: 8),
            Wrap(spacing: AppSpace.xl, runSpacing: 8, children: [
              _fact('Members', '${g.members}'),
              _fact('Hours', (g.workedMinutes / 60).toStringAsFixed(1)),
              _fact('Shifts worked', '${g.shiftsWorked}'),
              _fact('No-shows', '${g.noShows}'),
              _fact('Call-offs', '${g.callOffs}'),
              _fact('Late', '${g.late}'),
              _fact('Showed up', rate == null ? '—' : '${(rate * 100).round()}%'),
              _fact('Avg. score', g.averageScore == null ? '—' : '${g.averageScore}'),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _fact(String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label.toUpperCase(), style: AppText.kicker),
        Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      ]);
}
