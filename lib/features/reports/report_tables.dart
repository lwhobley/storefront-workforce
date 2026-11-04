import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import 'reports_providers.dart';

// ---- Formatting ----

String pct(double? v) => v == null ? '—' : '${(v * 100).toStringAsFixed(1)}%';

/// Percentage points between two rates, signed ("+1.2 pts").
String pts(double? now, double? before) {
  if (now == null || before == null) return '';
  final d = (now - before) * 100;
  return '${d >= 0 ? '+' : ''}${d.toStringAsFixed(1)} pts';
}

final _num = NumberFormat.decimalPattern('en_US');
final _currency = NumberFormat.currency(locale: 'en_US', symbol: r'$');
final _currency0 = NumberFormat.currency(locale: 'en_US', symbol: r'$', decimalDigits: 0);

String hrs(int minutes) => _num.format((minutes / 60 * 10).round() / 10);
String count(int n) => _num.format(n);
String usd(int cents) => _currency.format(cents / 100);
String usd0(int cents) => _currency0.format(cents / 100);
/// "$101.7k" for tight spaces.
String usdK(int cents) => cents.abs() >= 100000 ? '\$${(cents / 100000).toStringAsFixed(1)}k' : usd0(cents);
String usdOrDash(int? cents) => cents == null ? '—' : usd(cents);

String eventDate(Event e, String tz) => DateFormat('EEE, MMM d, y').format(atVenue(e.startTime, tz));
String shortEventDate(Event e, String tz) => DateFormat('MMM d').format(atVenue(e.startTime, tz));

Tone? ragTone(Rag r) => switch (r) {
      Rag.green => Tone.good,
      Rag.yellow => Tone.warn,
      Rag.red => Tone.bad,
      Rag.none => null,
    };

String ragLabel(Rag r) => switch (r) {
      Rag.green => 'On target',
      Rag.yellow => 'Close',
      Rag.red => 'Off target',
      Rag.none => '',
    };

/// Budget status of a slice ("Under budget", "4% over").
Rag budgetOf(KpiTotals t, ReportTargets targets) => t.budgets == 0 ? Rag.none : targets.budget(t.budgetedCostCents, t.budgetCents);

String budgetText(KpiTotals t) {
  if (t.budgets == 0) return 'No budget';
  final cost = t.budgetedCostCents, budget = t.budgetCents;
  if (cost <= budget) return 'Under budget';
  if (budget == 0) return 'Over budget';
  return '${((cost - budget) * 100 / budget).toStringAsFixed(1)}% over';
}

String workerTypeLabel(WorkerType t) => switch (t) {
      WorkerType.regular => 'Staff',
      WorkerType.temp => 'Temps',
      WorkerType.npo => 'NPO members',
    };

/// A table on screen: export text plus a color per cell and a tap per row.
class ViewTable {
  const ViewTable(this.table, {this.tones = const {}, this.onTap = const {}});

  final ReportTable table;

  /// (row, column) -> tone.
  final Map<(int, int), Tone> tones;
  final Map<int, void Function()> onTap;
}

class _Builder {
  _Builder(this.columns);

  final List<String> columns;
  final rows = <List<String>>[];
  final tones = <(int, int), Tone>{};
  final taps = <int, void Function()>{};

  void add(List<String> row, {Map<int, Tone?> tone = const {}, void Function()? onTap}) {
    final i = rows.length;
    rows.add(row);
    tone.forEach((c, t) {
      if (t != null) tones[(i, c)] = t;
    });
    if (onTap != null) taps[i] = onTap;
  }

  ViewTable build(String title, {String note = ''}) =>
      ViewTable(ReportTable(title: title, columns: columns, rows: rows, note: note), tones: tones, onTap: taps);
}

// ---- Tables ----

/// One row per event (held and upcoming).
ViewTable eventsTable(SeasonReport r, VenueContext venue, ReportTargets targets, {void Function(Event e)? onTap}) {
  final money = r.result.hasMoney;
  final tz = venue.venue.timeZone;
  final b = _Builder([
    'Date', 'Event', 'Type', 'Planned', 'Staffed', 'Fill rate', 'Open', 'On time', 'Late', 'No-shows', 'Call-offs', //
    'Hours', 'Overtime hours', 'Breaks OK',
    if (money) ...['Labor cost', 'Budget', 'Budget status', 'Cost per attendee'],
  ]);
  for (final e in r.result.events) {
    final t = e.total;
    final up = e.upcoming;
    b.add(
      [
        eventDate(e.event, tz), e.event.name, venue.eventTypes[e.event.eventTypeCode] ?? e.event.eventTypeCode, //
        count(t.planned), count(t.staffed), pct(t.fillRate), count(t.open),
        up ? 'Upcoming' : pct(t.onTimeRate), up ? '' : count(t.late), up ? '' : count(t.noShows), up ? '' : count(t.callOffs),
        up ? '' : hrs(t.workedMinutes), up ? '' : hrs(t.overtimeMinutes), up ? '' : pct(t.breakComplianceRate),
        if (money) ...[
          up ? '' : usd(t.laborCents),
          t.budgets == 0 && e.eventBudgetCents == null ? '' : usd(e.eventBudgetCents ?? t.budgetCents),
          up ? '' : budgetText(t),
          up ? '' : usdOrDash(t.costPerAttendeeCents),
        ],
      ],
      tone: {
        5: ragTone(targets.fill(t.fillRate)),
        7: up ? null : ragTone(targets.attendance(t.onTimeRate)),
        if (money) 16: up ? null : ragTone(budgetOf(t, targets)),
      },
      onTap: onTap == null ? null : () => onTap(e.event),
    );
  }
  return b.build('Events, ${r.season.label}', note: 'Upcoming events show staffing only.');
}

/// Season totals by storefront (events held so far).
ViewTable storefrontsTable(Map<String?, KpiTotals> byStorefront, VenueContext venue, ReportTargets targets, {required bool money, required String title}) {
  final b = _Builder([
    'Storefront', 'Planned', 'Staffed', 'Fill rate', 'On time', 'Late', 'No-shows', 'Call-offs', 'Hours', 'Overtime hours', 'Breaks OK', //
    if (money) ...['Labor cost', 'Budget', 'Budget status', 'Tips'],
  ]);
  final keys = byStorefront.keys.toList()
    ..sort((a, c) {
      if (a == null) return 1;
      if (c == null) return -1;
      return (venue.storefront(a)?.name ?? a).compareTo(venue.storefront(c)?.name ?? c);
    });
  for (final k in keys) {
    final t = byStorefront[k]!;
    if (!money && !t.hasActivity) continue;
    b.add(
      [
        k == null ? 'Not at a storefront' : (venue.storefront(k)?.name ?? 'Storefront'),
        count(t.planned), count(t.staffed), pct(t.fillRate), pct(t.onTimeRate), count(t.late), count(t.noShows), count(t.callOffs),
        hrs(t.workedMinutes), hrs(t.overtimeMinutes), pct(t.breakComplianceRate),
        if (money) ...[usd(t.laborCents), t.budgets == 0 ? '' : usd(t.budgetCents), budgetText(t), usd(t.tipsCents)],
      ],
      tone: {
        3: ragTone(targets.fill(t.fillRate)),
        4: ragTone(targets.attendance(t.onTimeRate)),
        if (money) 13: ragTone(budgetOf(t, targets)),
      },
    );
  }
  return b.build(title, note: money ? 'Storefront budgets come from each event\'s storefront budget.' : '');
}

ViewTable staffingMixTable(SeasonReport r) {
  final money = r.result.hasMoney;
  final all = r.result.byWorkerType;
  final totalMinutes = all.values.fold(0, (s, t) => s + t.workedMinutes);
  final totalCost = all.values.fold(0, (s, t) => s + t.laborCents);
  final b = _Builder(['Who', 'Hours', 'Share of hours', 'Overtime hours', 'On time', 'No-shows', 'Call-offs', if (money) ...['Cost', 'Share of cost']]);
  for (final type in WorkerType.values) {
    final t = all[type] ?? KpiTotals.zero;
    b.add([
      workerTypeLabel(type), hrs(t.workedMinutes), pct(totalMinutes == 0 ? null : t.workedMinutes / totalMinutes), hrs(t.overtimeMinutes), //
      pct(t.onTimeRate), count(t.noShows), count(t.callOffs),
      if (money) ...[usd(t.laborCents), pct(totalCost == 0 ? null : t.laborCents / totalCost)],
    ]);
  }
  return b.build('Staffing mix',
      note: money ? 'Staff cost is pay plus employer costs; temps at agency bill rates; NPO members at the group payout.' : '');
}

ViewTable npoTable(SeasonReport r, VenueContext venue, ReportTargets targets) {
  final money = r.result.hasMoney;
  final b = _Builder(['Group', 'Hours', 'On time', 'Showed up', 'Late', 'No-shows', 'Call-offs', if (money) ...['Payouts', 'Paid', 'Owed']]);
  for (final g in r.result.npoGroups) {
    final t = g.totals;
    b.add(
      [
        venue.npoName(g.groupId).isEmpty ? 'NPO group' : venue.npoName(g.groupId), hrs(t.workedMinutes), pct(t.onTimeRate), pct(t.attendanceRate), //
        count(t.late), count(t.noShows), count(t.callOffs),
        if (money) ...[usd(g.totalCents), usd(g.paidCents), usd(g.owedCents)],
      ],
      tone: {2: ragTone(targets.attendance(t.onTimeRate))},
    );
  }
  final est = r.result.npoPayoutsEstimated;
  return b.build('NPO groups',
      note: money && est > 0 ? 'Includes $est payout${est == 1 ? '' : 's'} not created yet, estimated from time records; owed until marked paid.' : '');
}

ViewTable tipsTable(SeasonReport r) {
  final b = _Builder(['Person', 'Tips', 'Hours in the pool', 'Per hour', 'Events']);
  for (final t in r.result.tips) {
    b.add([r.name(t.workerId), usd(t.cents), (t.hoursHundredths / 100).toStringAsFixed(2), usdOrDash(t.centsPerHour), count(t.events)]);
  }
  final est = r.result.tipPoolsEstimated;
  return b.build('Tips by person',
      note: est > 0 ? '$est tip pool${est == 1 ? ' was' : 's were'} not split yet; shown as the Pay screen would split them by hours.' : '');
}

ViewTable retentionTable(List<RetentionRow> rows, int startMonth) {
  final b = _Builder(['Season', 'Staff who worked', 'Came back from last season', 'New', 'Kept from last season', 'Turnover', 'Last season\'s new hires who came back']);
  for (final r in rows.reversed) {
    final s = Season(r.season, startMonth: startMonth);
    b.add([
      s.label, count(r.staff), r.priorStaff == 0 ? '—' : count(r.returning), r == rows.first ? '—' : count(r.newStaff), pct(r.retention), pct(r.turnover), //
      r.priorNew == 0 ? '—' : '${r.priorNewReturned} of ${r.priorNew} (${pct(r.newHireReturnRate)})',
    ]);
  }
  return b.build('Turnover and retention (staff)',
      note: 'Worked = clocked in at least once that season. Temps and NPO members are left out. The current season is so far.');
}

ViewTable certsTable(CertificationCompliance c, VenueContext venue, Map<String, Worker> workers) {
  final b = _Builder(['Person', 'Certification', 'Expires']);
  for (final (id, cert) in c.expiringSoon) {
    b.add([workers[id]?.displayName ?? '', venue.certName(cert.typeCode), cert.expiresOn == null ? '' : DateFormat('MMM d, y').format(cert.expiresOn!)],
        tone: {2: Tone.warn});
  }
  for (final id in c.expiredOrMissing) {
    b.add([workers[id]?.displayName ?? '', 'Expired or missing', ''], tone: {1: Tone.bad});
  }
  return b.build('Certifications to renew', note: 'Expiring within 30 days, then people missing one their trained roles need.');
}

/// Headline numbers as a two-column table (for export).
ViewTable summaryTable(String title, KpiTotals t, {required bool money, KpiTotals? upcoming}) {
  final b = _Builder(['Measure', 'Value']);
  b
    ..add(['Events', count(t.events)])
    ..add(['Positions planned', count(t.planned)])
    ..add(['Positions staffed', count(t.staffed)])
    ..add(['Fill rate', pct(t.fillRate)])
    ..add(['Average hours to fill an open position', t.averageHoursToFill == null ? '—' : t.averageHoursToFill!.toStringAsFixed(1)])
    ..add(['On time', pct(t.onTimeRate)])
    ..add(['Showed up', pct(t.attendanceRate)])
    ..add(['Late arrivals', count(t.late)])
    ..add(['Average minutes late', t.averageMinutesLate == null ? '—' : t.averageMinutesLate!.toStringAsFixed(0)])
    ..add(['No-shows', count(t.noShows)])
    ..add(['Call-offs', count(t.callOffs)])
    ..add(['Hours worked', hrs(t.workedMinutes)])
    ..add(['Overtime hours', hrs(t.overtimeMinutes)])
    ..add(['Breaks due', count(t.breaksDue)])
    ..add(['Breaks missed', count(t.breaksMissed)])
    ..add(['Breaks late', count(t.breaksLate)])
    ..add(['Breaks too short', count(t.breaksShort)])
    ..add(['Breaks OK', pct(t.breakComplianceRate)]);
  if (upcoming != null) b.add(['Open positions at upcoming events', count(upcoming.open)]);
  if (money) {
    b
      ..add(['Labor cost', usd(t.laborCents)])
      ..add(['Staff pay', usd(t.payrollCents)])
      ..add(['Employer costs on staff pay', usd(t.burdenCents)])
      ..add(['Temps (agency bills)', usd(t.tempCents)])
      ..add(['NPO payouts', usd(t.npoCents)])
      ..add(['Budget (events with one)', t.budgets == 0 ? '—' : usd(t.budgetCents)])
      ..add(['Cost of those events', t.budgets == 0 ? '—' : usd(t.budgetedCostCents)])
      ..add(['Budget status', budgetText(t)])
      ..add(['Cost per attendee', usdOrDash(t.costPerAttendeeCents)])
      ..add(['Tips (not labor cost)', usd(t.tipsCents)]);
  }
  return b.build(title);
}

/// Side-by-side comparison. With [perEvent], counts, hours and money are averages per
/// event (rates are pooled over all the events).
ViewTable compareTable(String title, List<(String, KpiTotals)> columns, {required bool money, bool perEvent = false, String note = ''}) {
  String avg(int v, KpiTotals t, String Function(int) f) {
    if (!perEvent) return f(v);
    if (t.events == 0) return '—';
    return f((v / t.events).round());
  }

  String avgD(int v, KpiTotals t) => !perEvent ? count(v) : (t.events == 0 ? '—' : (v / t.events).toStringAsFixed(1));
  final b = _Builder(['Measure', for (final c in columns) c.$1]);
  void row(String label, String Function(KpiTotals t) f) => b.add([label, for (final c in columns) c.$2.events == 0 && perEvent ? '—' : f(c.$2)]);
  row('Events', (t) => count(t.events));
  row('Fill rate', (t) => pct(t.fillRate));
  row('On time', (t) => pct(t.onTimeRate));
  row('Showed up', (t) => pct(t.attendanceRate));
  row(perEvent ? 'No-shows per event' : 'No-shows', (t) => avgD(t.noShows, t));
  row(perEvent ? 'Call-offs per event' : 'Call-offs', (t) => avgD(t.callOffs, t));
  row(perEvent ? 'Hours per event' : 'Hours', (t) => avg(t.workedMinutes, t, hrs));
  row(perEvent ? 'Overtime hours per event' : 'Overtime hours', (t) => avg(t.overtimeMinutes, t, hrs));
  row('Breaks OK', (t) => pct(t.breakComplianceRate));
  row('Hours to fill an open position', (t) => t.averageHoursToFill == null ? '—' : t.averageHoursToFill!.toStringAsFixed(1));
  if (money) {
    row(perEvent ? 'Labor cost per event' : 'Labor cost', (t) => avg(t.laborCents, t, usd0));
    row('Cost per attendee', (t) => usdOrDash(t.costPerAttendeeCents));
    row('Budget status', budgetText);
  }
  return b.build(title, note: note);
}
