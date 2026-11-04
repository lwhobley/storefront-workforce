import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/people_repository.dart';
import 'report_tables.dart';
import 'report_widgets.dart';
import 'reports_providers.dart';
import 'targets_dialog.dart';

/// KPIs for the workforce (no sales): staffing, attendance, hours, breaks, labor cost
/// against budget (pay viewers only), people, by season, event and storefront.
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

/// The season picked on the Reports screen, kept while moving to an event and back.
final reportsSeasonProvider = NotifierProvider<_SeasonChoice, int?>(_SeasonChoice.new);

class _SeasonChoice extends Notifier<int?> {
  @override
  int? build() => null;

  void set(int? startYear) => state = startYear;
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider)!;
    final current = ref.watch(currentSeasonProvider);
    final startYear = ref.watch(reportsSeasonProvider) ?? current.startYear;
    final season = Season(startYear, startMonth: current.startMonth);
    final venueAsync = ref.watch(venueProvider);
    final targets = ref.watch(reportTargetsProvider).value ?? ReportTargets.defaults;
    final reportAsync = ref.watch(seasonReportProvider(startYear));
    final previous = ref.watch(seasonReportProvider(startYear - 1)).value;
    final retention = ref.watch(retentionProvider).value;
    final onboarding = ref.watch(reportOnboardingProvider).value;
    final venue = venueAsync.value;
    final report = reportAsync.value;

    List<ViewTable> allTables() {
      if (report == null || venue == null) return const [];
      final money = report.result.hasMoney;
      return [
        summaryTable('Season ${season.label} at a glance', report.result.total, money: money, upcoming: report.result.upcoming),
        if (previous != null)
          compareTable('This season and last', [('${season.label} so far', report.result.total), (previous.season.label, previous.result.total)],
              money: money, perEvent: true),
        eventsTable(report, venue, targets),
        storefrontsTable(report.result.byStorefront, venue, targets, money: money, title: 'Storefronts, ${season.label}'),
        staffingMixTable(report),
        npoTable(report, venue, targets),
        if (money) tipsTable(report),
        if (retention != null) retentionTable(retention, season.startMonth),
        certsTable(_certs(report, venue), venue, report.workers),
      ];
    }

    final seasons = [for (var y = current.startYear; y > current.startYear - 4; y--) Season(y, startMonth: current.startMonth)];
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        body: SafeArea(
          child: NestedScrollView(
            headerSliverBuilder: (context, _) => [
              SliverToBoxAdapter(
                child: ScreenHeader(
                  kicker: session.venue.name,
                  title: 'Reports',
                  subtitle: 'Workforce only: staffing, attendance, hours${report?.result.hasMoney == true ? ', labor cost' : ''}.',
                  actions: [
                    DropdownButton<int>(
                      value: startYear,
                      underline: const SizedBox.shrink(),
                      items: [for (final s in seasons) DropdownMenuItem(value: s.startYear, child: Text('Season ${s.label}'))],
                      onChanged: (v) => ref.read(reportsSeasonProvider.notifier).set(v),
                    ),
                    if (session.canVenueWide(Perm.manageSettings))
                      TextButton.icon(
                        onPressed: () => showTargetsDialog(context, ref, targets),
                        icon: const Icon(Icons.flag_outlined, size: 18),
                        label: const Text('Targets'),
                      ),
                    ExportButtons(
                      onCsv: () => exportCsv(context, 'reports-${season.label.replaceAll('–', '-')}.csv', allTables()),
                      onPrint: () => printTables(context,
                          title: 'Reports, season ${season.label}',
                          subtitle: '${session.venue.name} · ${season.rangeLabel} · through ${_through(report)} · printed ${_today(session)}',
                          tables: allTables(),
                          fileName: 'reports-${season.label.replaceAll('–', '-')}.html'),
                    ),
                  ],
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpace.screen, 0, AppSpace.screen, AppSpace.s),
                  child: Text(
                    'Season ${season.label} runs ${season.rangeLabel}. A season starts each ${monthFullNames[season.startMonth - 1]} 1 '
                    '(a venue setting). Numbers cover events held so far; upcoming events count for staffing only.',
                    style: AppText.meta,
                  ),
                ),
              ),
              const SliverToBoxAdapter(
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  padding: EdgeInsets.symmetric(horizontal: AppSpace.m),
                  tabs: [Tab(text: 'Overview'), Tab(text: 'Events'), Tab(text: 'Storefronts'), Tab(text: 'People')],
                ),
              ),
            ],
            body: venue == null || report == null
                ? (reportAsync.hasError || venueAsync.hasError)
                    ? ErrorNote(reportAsync.error ?? venueAsync.error!, onRetry: () => ref.invalidate(seasonReportProvider(startYear)))
                    : const Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 12),
                          Text('Working out the numbers…', style: AppText.meta),
                        ]),
                      )
                : TabBarView(children: [
                    _Overview(report: report, previous: previous, venue: venue, targets: targets),
                    _Scroll([KpiTableView(eventsTable(report, venue, targets, onTap: (e) => context.go('/reports/event/${e.id}?season=$startYear')))]),
                    _Scroll([
                      KpiTableView(storefrontsTable(report.result.byStorefront, venue, targets,
                          money: report.result.hasMoney, title: 'Storefronts, events held so far')),
                    ]),
                    _People(report: report, venue: venue, targets: targets, retention: retention, onboarding: onboarding),
                  ]),
          ),
        ),
      ),
    );
  }

  String _through(SeasonReport? r) => r == null ? '' : '${monthNames[r.through.month - 1]} ${r.through.day}, ${r.through.year}';
  String _today(AppSession s) {
    final d = venueDate(DateTime.now().toUtc(), s.venue.timeZone);
    return '${monthNames[d.month - 1]} ${d.day}, ${d.year}';
  }
}

CertificationCompliance _certs(SeasonReport report, VenueContext venue) => certificationCompliance(
      workers: report.workers.values,
      jobRoles: venue.jobRoles,
      onDate: venueDate(DateTime.now().toUtc(), venue.venue.timeZone),
      rules: venue.rules.certifications,
    );

class _Scroll extends StatelessWidget {
  const _Scroll(this.children);

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.only(bottom: 48), children: children);
}

class _Overview extends StatelessWidget {
  const _Overview({required this.report, required this.previous, required this.venue, required this.targets});

  final SeasonReport report;
  final SeasonReport? previous;
  final VenueContext venue;
  final ReportTargets targets;

  @override
  Widget build(BuildContext context) {
    final r = report.result;
    final t = r.total;
    final p = previous?.result.total;
    final money = r.hasMoney;
    final grace = venue.rules.attendance.lateGraceMinutes;
    final recent = r.held.reversed.take(8).toList();
    return _Scroll([
      const SectionHeading('Against targets'),
      KpiGrid(tiles: [
        KpiTile(
          label: 'Fill rate',
          value: pct(t.fillRate),
          rag: targets.fill(t.fillRate),
          detail: p == null ? '${count(t.staffed)} of ${count(t.planned)}' : 'Last season ${pct(p.fillRate)}',
        ),
        KpiTile(
          label: 'On time',
          value: pct(t.onTimeRate),
          rag: targets.attendance(t.onTimeRate),
          detail: p == null ? '${count(t.late)} late' : 'Last season ${pct(p.onTimeRate)}',
        ),
        if (money)
          KpiTile(
            label: 'Labor cost',
            value: usd0(t.laborCents),
            rag: budgetOf(t, targets),
            detail: t.budgets == 0 ? 'No budgets set' : '${budgetText(t)} · ${usdK(t.budgetCents)}',
          ),
        KpiTile(label: 'No-shows', value: count(t.noShows), detail: '${count(t.callOffs)} call-offs · ${count(t.late)} late'),
        KpiTile(
          label: 'Open positions ahead',
          value: count(r.upcoming.open),
          detail: 'at ${r.upcomingEvents.length} upcoming events',
        ),
        KpiTile(
          label: 'Hours worked',
          value: hrs(t.workedMinutes),
          detail: '${hrs(t.overtimeMinutes)} overtime (${pct(t.overtimeShare)})',
        ),
        KpiTile(
          label: 'Breaks OK',
          value: pct(t.breakComplianceRate),
          detail: '${t.breaksMissed} missed · ${t.breaksShort} short · ${t.breaksLate} late',
        ),
        KpiTile(
          label: 'Time to fill',
          value: t.averageHoursToFill == null ? '—' : '${t.averageHoursToFill!.toStringAsFixed(1)} h',
          detail: 'open position to assigned',
        ),
        if (money)
          KpiTile(
            label: 'Cost per attendee',
            value: usdOrDash(t.costPerAttendeeCents),
            detail: p == null ? 'actual attendance, else expected' : 'last season ${usdOrDash(p.costPerAttendeeCents)}',
          ),
        if (money) KpiTile(label: 'Tips', value: usd0(t.tipsCents), detail: '${r.tips.length} people · not labor cost'),
      ]),
      Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, 0),
        child: Text(
          'Green meets the target, yellow is close, red is off. Fill: ${pct(targets.fillGreen)} green, ${pct(targets.fillYellow)} yellow. '
          'On time (clocked in within $grace minutes of call, out of everyone scheduled): ${pct(targets.attendanceGreen)} green, '
          '${pct(targets.attendanceYellow)} yellow.${money ? ' Budget: under is green, up to ${(targets.budgetYellowOver * 100).round()}% over is yellow.' : ''}'
          '${targets.isDefault ? ' These are the default targets.' : ''}',
          style: AppText.meta,
        ),
      ),
      const SectionHeading('Recent events'),
      if (recent.isEmpty) const EmptyNote('No events held yet this season.'),
      for (final e in recent) _EventRow(e: e, venue: venue, targets: targets, money: money, season: report.season.startYear),
      if (previous != null)
        KpiTableView(compareTable(
          'This season and last, per event',
          [('${report.season.label} so far', t), (previous!.season.label, previous!.result.total)],
          money: money,
          perEvent: true,
        )),
    ]);
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.e, required this.venue, required this.targets, required this.money, required this.season});

  final EventReport e;
  final VenueContext venue;
  final ReportTargets targets;
  final bool money;
  final int season;

  @override
  Widget build(BuildContext context) {
    final t = e.total;
    final cost = budgetOf(t, targets);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
      title: Text(e.event.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(shortEventDate(e.event, venue.venue.timeZone), style: AppText.meta),
          StatusTag('Fill ${pct(t.fillRate)}', ragTone(targets.fill(t.fillRate)) ?? Tone.idle),
          StatusTag('On time ${pct(t.onTimeRate)}', ragTone(targets.attendance(t.onTimeRate)) ?? Tone.idle),
          if (money && cost != Rag.none) StatusTag(budgetText(t), ragTone(cost)!),
        ]),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.go('/reports/event/${e.event.id}?season=$season'),
    );
  }
}

class _People extends StatelessWidget {
  const _People({required this.report, required this.venue, required this.targets, required this.retention, required this.onboarding});

  final SeasonReport report;
  final VenueContext venue;
  final ReportTargets targets;
  final List<RetentionRow>? retention;
  final OnboardingSummary? onboarding;

  @override
  Widget build(BuildContext context) {
    final certs = _certs(report, venue);
    final money = report.result.hasMoney;
    final ret = retention;
    final latest = ret == null || ret.isEmpty ? null : ret.last;
    final tips = report.result.tips;
    final tipCents = tips.fold(0, (s, t) => s + t.cents);
    final tipHours = tips.fold(0, (s, t) => s + t.hoursHundredths);
    return _Scroll([
      KpiTableView(staffingMixTable(report)),
      KpiTableView(npoTable(report, venue, targets)),
      const SectionHeading('Onboarding and certifications'),
      KpiGrid(tiles: [
        KpiTile(
          label: 'Onboarding done',
          value: onboarding == null ? '—' : pct(onboarding!.completionRate),
          detail: onboarding == null ? 'Needs staff access' : '${onboarding!.finished} of ${onboarding!.people} active people',
        ),
        KpiTile(
          label: 'Days to finish',
          value: onboarding?.averageDaysToComplete == null ? '—' : onboarding!.averageDaysToComplete!.toStringAsFixed(1),
          detail: 'average, for people who finished',
        ),
        KpiTile(
          label: 'Certified for their roles',
          value: pct(certs.rate),
          rag: certs.rate == null ? Rag.none : (certs.rate! >= 1 ? Rag.green : certs.rate! >= 0.95 ? Rag.yellow : Rag.red),
          detail: '${certs.compliant} of ${certs.people} who need one',
        ),
        KpiTile(label: 'Expiring in 30 days', value: count(certs.expiringSoon.length), detail: '${certs.expiredOrMissing.length} expired or missing'),
      ]),
      KpiTableView(certsTable(certs, venue, report.workers), maxRows: 15),
      const SectionHeading('Turnover and retention'),
      if (ret == null) const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())),
      if (latest != null)
        KpiGrid(tiles: [
          KpiTile(label: 'Kept from last season', value: pct(latest.retention), detail: '${latest.returning} of ${latest.priorStaff} staff'),
          KpiTile(label: 'New this season', value: count(latest.newStaff), detail: 'never worked here before'),
          KpiTile(
            label: 'New hires who came back',
            value: pct(latest.newHireReturnRate),
            detail: latest.priorNew == 0 ? 'no new hires last season' : '${latest.priorNewReturned} of ${latest.priorNew} from last season',
          ),
        ]),
      if (ret != null) KpiTableView(retentionTable(ret, report.season.startMonth), showTitle: false),
      if (money) ...[
        const SectionHeading('Tips'),
        KpiGrid(tiles: [
          KpiTile(label: 'Tips per person', value: tips.isEmpty ? '—' : usd(tipCents ~/ tips.length), detail: '${tips.length} people'),
          KpiTile(label: 'Tips per hour', value: tipHours == 0 ? '—' : usd(tipCents * 100 ~/ tipHours), detail: 'hours in the tip pools'),
        ]),
        KpiTableView(tipsTable(report), maxRows: 20, showTitle: false),
      ],
    ]);
  }
}
