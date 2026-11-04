import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import 'report_tables.dart';
import 'report_widgets.dart';
import 'reports_providers.dart';

/// One event's KPIs, by storefront, compared with recent events and with the same kind
/// of event last season.
class EventReportScreen extends ConsumerWidget {
  const EventReportScreen({super.key, required this.eventId, this.season});

  final String eventId;
  final int? season;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(currentSeasonProvider);
    final year = season ?? current.startYear;
    final reportAsync = ref.watch(seasonReportProvider(year));
    final previous = ref.watch(seasonReportProvider(year - 1)).value;
    final venue = ref.watch(venueProvider).value;
    final targets = ref.watch(reportTargetsProvider).value ?? ReportTargets.defaults;
    final session = ref.watch(sessionProvider)!;

    Widget body() {
      final report = reportAsync.value;
      if (report == null || venue == null) {
        return reportAsync.hasError
            ? ErrorNote(reportAsync.error!, onRetry: () => ref.invalidate(seasonReportProvider(year)))
            : const Center(child: CircularProgressIndicator());
      }
      final e = report.result.event(eventId);
      if (e == null) return const EmptyNote('This event is not in the report.');
      return _EventBody(e: e, report: report, previous: previous, venue: venue, targets: targets, session: session);
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.s, AppSpace.s, 0, 0),
              child: TextButton.icon(onPressed: () => context.go('/reports'), icon: const Icon(Icons.arrow_back), label: const Text('Reports')),
            ),
            Expanded(child: body()),
          ],
        ),
      ),
    );
  }
}

class _EventBody extends StatelessWidget {
  const _EventBody({required this.e, required this.report, required this.previous, required this.venue, required this.targets, required this.session});

  final EventReport e;
  final SeasonReport report;
  final SeasonReport? previous;
  final VenueContext venue;
  final ReportTargets targets;
  final AppSession session;

  List<ViewTable> _tables() {
    final money = report.result.hasMoney;
    final ev = e.event;
    final last5 = previousEvents(report.result, ev);
    final sameType = previous == null ? const <EventReport>[] : eventsOfType(previous!.result, ev.eventTypeCode);
    final typeName = venue.eventTypes[ev.eventTypeCode] ?? ev.eventTypeCode;
    return [
      summaryTable(ev.name, e.total, money: money),
      if (!e.upcoming)
        compareTable(
          'Compared with other events',
          [
            ('This event', e.total),
            (last5.isEmpty ? 'Earlier events (none)' : 'Last ${last5.length} events', KpiTotals.sum(last5.map((x) => x.total))),
            ('$typeName, last season', KpiTotals.sum(sameType.map((x) => x.total))),
          ],
          money: money,
          perEvent: true,
          note: 'Hours, money and counts are per event; rates are over all those events together.',
        ),
      storefrontsTable(e.byStorefront, venue, targets, money: money, title: 'By storefront'),
      if (money && e.cost != null) _costTable(),
    ];
  }

  ViewTable _costTable() {
    final c = e.cost!;
    final rows = <List<String>>[];
    final tones = <(int, int), Tone>{};
    for (final r in [...c.storefronts, c.total]) {
      final isTotal = identical(r, c.total);
      final status = budgetRag(r.totalCents, r.budgetCents, yellowOver: targets.budgetYellowOver);
      final tone = ragTone(status);
      if (tone != null) tones[(rows.length, 7)] = tone;
      rows.add([
        isTotal ? 'Event total' : (r.storefrontId == null ? 'Not at a storefront' : venue.storefront(r.storefrontId!)?.name ?? 'Storefront'),
        usd(r.payrollCents), usd(r.burdenCents), usd(r.tempCents), usd(r.npoCents), usd(r.totalCents), //
        r.budgetCents == null ? '' : usd(r.budgetCents!),
        r.budgetCents == null ? 'No budget' : (r.totalCents <= r.budgetCents! ? 'Under budget' : '${usd(r.totalCents - r.budgetCents!)} over'),
      ]);
    }
    return ViewTable(
      ReportTable(
        title: 'Labor cost against budget',
        columns: const ['Storefront', 'Staff pay', 'Employer costs', 'Temps', 'NPO', 'Total', 'Budget', 'Status'],
        rows: rows,
        note: 'Cost per attendee ${usdOrDash(c.costPerAttendeeCents)} (${count(c.attendance)} ${c.attendanceIsActual ? 'actual' : 'expected'}). '
            'Tips are not labor cost. NPO payouts not created yet are estimated from time records.',
      ),
      tones: tones,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = e.total;
    final ev = e.event;
    final money = report.result.hasMoney;
    final tz = venue.venue.timeZone;
    final tables = _tables();
    final subtitle = '${eventDate(ev, tz)} · ${venue.eventTypes[ev.eventTypeCode] ?? ev.eventTypeCode} · '
        '${count(ev.actualAttendance ?? ev.expectedAttendance)} ${ev.actualAttendance == null ? 'expected' : 'attended'}';
    return ListView(
      padding: const EdgeInsets.only(bottom: 48),
      children: [
        ScreenHeader(
          kicker: 'Event report',
          title: ev.name,
          subtitle: subtitle,
          actions: [
            ExportButtons(
              onCsv: () => exportCsv(context, 'event-${formatDate(venueDateOf(ev, tz))}.csv', tables),
              onPrint: () => printTables(context, title: ev.name, subtitle: '${session.venue.name} · $subtitle', tables: tables, fileName: 'event.html'),
            ),
          ],
        ),
        if (e.upcoming) const EmptyNote('This event has not started. Staffing so far:'),
        if (ev.status == EventStatus.live)
          const EmptyNote('In progress: hours and cost count only time already clocked out; attendance counts people past call time.'),
        KpiGrid(tiles: [
          KpiTile(label: 'Fill rate', value: pct(t.fillRate), rag: targets.fill(t.fillRate), detail: '${t.staffed} of ${t.planned} · ${t.open} open'),
          if (!e.upcoming) ...[
            KpiTile(label: 'On time', value: pct(t.onTimeRate), rag: targets.attendance(t.onTimeRate), detail: '${t.late} late · ${t.noShows} no-shows'),
            KpiTile(label: 'Call-offs', value: count(t.callOffs), detail: 'within 48 h of call'),
            KpiTile(label: 'Hours worked', value: hrs(t.workedMinutes), detail: '${hrs(t.overtimeMinutes)} overtime'),
            KpiTile(label: 'Breaks OK', value: pct(t.breakComplianceRate), detail: '${t.breakExceptions} of ${t.breaksDue} not OK'),
            if (money) ...[
              KpiTile(label: 'Labor cost', value: usd0(t.laborCents), rag: budgetOf(t, targets), detail: t.budgets == 0 ? 'No budget' : '${budgetText(t)} · ${usdK(t.budgetCents)}'),
              KpiTile(label: 'Cost per attendee', value: usdOrDash(t.costPerAttendeeCents), detail: ev.actualAttendance == null ? 'expected attendance' : 'actual attendance'),
              KpiTile(label: 'Tips', value: usd0(t.tipsCents), detail: 'not labor cost'),
            ],
          ],
        ]),
        for (final v in tables.skip(1)) KpiTableView(v),
      ],
    );
  }
}

DateTime venueDateOf(Event e, String tz) => localDateOf(e.startTime, tz);
