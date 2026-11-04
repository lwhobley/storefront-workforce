import 'package:workforce_core/workforce_core.dart';

import '../../data/models.dart';
import '../../data/people_repository.dart';

// ---------------------------------------------------------------------------
// An employee's own hours (no money)
// ---------------------------------------------------------------------------

/// One event (or one day of work with no event) for one person, from their punches.
class EventHours {
  const EventHours({
    required this.key,
    required this.date,
    required this.workedMinutes,
    required this.breakMinutes,
    required this.paidMinutes,
    this.event,
    this.storefrontName = '',
    this.jobRoleCode,
    this.firstIn,
    this.lastOut,
    this.breakCount = 0,
    this.open = false,
  });

  /// Event id, or 'day:yyyy-mm-dd' for punches with no event.
  final String key;
  final Event? event;

  /// Venue-local date the work belongs to.
  final DateTime date;
  final String storefrontName;
  final String? jobRoleCode;
  final DateTime? firstIn;
  final DateTime? lastOut;

  /// On the clock, breaks excluded.
  final int workedMinutes;
  final int breakMinutes;
  final int breakCount;

  /// What counts as time worked for pay: worked minutes plus short paid breaks.
  final int paidMinutes;

  /// Still clocked in.
  final bool open;
}

class PeriodHours {
  const PeriodHours({required this.period, required this.items});

  final PayPeriod period;
  final List<EventHours> items;

  int get paidMinutes => items.fold(0, (s, e) => s + e.paidMinutes);
  int get workedMinutes => items.fold(0, (s, e) => s + e.workedMinutes);
  int get breakMinutes => items.fold(0, (s, e) => s + e.breakMinutes);
}

/// Groups one person's punches by event and runs each group through [WorkTimeline],
/// the same engine the clock screen and payroll use.
List<EventHours> hoursByEvent(
  MyHoursData data, {
  required String timeZone,
  required BreakRules breakRules,
  List<Storefront> storefronts = const [],
  DateTime? now,
}) {
  final groups = <String, List<Punch>>{};
  for (final p in data.punches) {
    if (p.status == PunchStatus.voided) continue;
    final key = p.eventId ?? 'day:${dateOnly(localDateOf(p.occurredAt, timeZone))}';
    groups.putIfAbsent(key, () => []).add(p);
  }
  final out = <EventHours>[];
  for (final MapEntry(:key, value: punches) in groups.entries) {
    final event = data.events[key];
    final timeline = WorkTimeline.fromPunches(punches, now: now);
    final paid = timeline.paidIntervals(breakRules).fold(0, (s, i) => s + i.minutes);
    final shifts = [
      for (final s in data.shifts)
        if (s.eventId == key) s,
    ]..sort((a, b) => (a.status == ShiftStatus.cancelled ? 1 : 0).compareTo(b.status == ShiftStatus.cancelled ? 1 : 0));
    final shift = shifts.firstOrNull;
    final first = punches.map((p) => p.occurredAt).reduce((a, b) => a.isBefore(b) ? a : b);
    out.add(EventHours(
      key: key,
      event: event,
      date: localDateOf(event?.startTime ?? first, timeZone),
      storefrontName: storefronts.where((f) => f.id == shift?.storefrontId).firstOrNull?.name ?? '',
      jobRoleCode: shift?.jobRoleCode,
      firstIn: timeline.firstClockIn,
      lastOut: timeline.lastClockOut,
      workedMinutes: timeline.workedMinutes,
      breakMinutes: timeline.breakMinutes,
      breakCount: timeline.breakSegments.length,
      paidMinutes: paid,
      open: timeline.isOpen,
    ));
  }
  out.sort((a, b) => b.date.compareTo(a.date));
  return out;
}

/// The venue's pay periods from [from] to [to] (local dates), newest first, each with
/// the work dated inside it.
List<PeriodHours> hoursByPayPeriod(
  List<EventHours> items, {
  required Map<String, dynamic> venueSettings,
  required DateTime from,
  required DateTime to,
}) {
  final periods = generatePayPeriodsFor(
    venueRules: VenueRules.fromJson(venueSettings),
    payRules: PayRules.fromVenueSettings(venueSettings),
    from: from,
    to: to,
  );
  return [
    for (final p in periods.reversed) PeriodHours(period: p, items: [for (final e in items) if (p.contains(e.date)) e]),
  ];
}

/// Hours and minutes, for people: 5 h 30 m.
String hoursMinutes(int minutes) {
  final h = minutes ~/ 60, m = minutes % 60;
  if (h == 0) return '$m m';
  return m == 0 ? '$h h' : '$h h $m m';
}

/// Decimal hours, for statements: 5.50.
String decimalHours(int minutes) => formatHundredths(minutesToHundredths(minutes));

// ---------------------------------------------------------------------------
// Partners
// ---------------------------------------------------------------------------

class PartnerEventHours {
  const PartnerEventHours({required this.event, required this.minutesByWorker, required this.scheduled});

  final Event event;

  /// Paid minutes per member who clocked in.
  final Map<String, int> minutesByWorker;

  /// Members with a position at the event.
  final Set<String> scheduled;

  int get totalMinutes => minutesByWorker.values.fold(0, (s, m) => s + m);
  int get worked => minutesByWorker.length;
}

/// Hours per event for a partner's people, from their punches, for events starting
/// between [from] and [to] (local dates). Same paid-time rule as payroll.
List<PartnerEventHours> partnerHoursByEvent(PartnerActivity a, {required String timeZone, required BreakRules breakRules, required DateTime from, required DateTime to}) {
  final out = <PartnerEventHours>[];
  for (final e in a.events.values) {
    final day = localDateOf(e.startTime, timeZone);
    if (day.isBefore(from) || day.isAfter(to)) continue;
    final byWorker = <String, List<Punch>>{};
    for (final p in a.punches) {
      if (p.eventId == e.id) byWorker.putIfAbsent(p.workerId, () => []).add(p);
    }
    final minutes = <String, int>{
      for (final MapEntry(:key, :value) in byWorker.entries)
        key: WorkTimeline.fromPunches(value).paidIntervals(breakRules).fold(0, (s, i) => s + i.minutes),
    };
    final scheduled = {for (final s in a.shifts) if (s.eventId == e.id) ?s.workerId};
    if (minutes.isEmpty && scheduled.isEmpty) continue;
    out.add(PartnerEventHours(event: e, minutesByWorker: minutes, scheduled: scheduled));
  }
  out.sort((x, y) => y.event.startTime.compareTo(x.event.startTime));
  return out;
}

/// Shifts from now on, soonest first.
List<Shift> upcomingShifts(PartnerActivity a, DateTime now) {
  bool live(Event? e) => e != null && (e.status == EventStatus.scheduled || e.status == EventStatus.live) &&
      (e.endTime ?? e.startTime.add(const Duration(hours: 3))).isAfter(now);
  return [
    for (final s in a.shifts)
      if (s.status == ShiftStatus.assigned && live(a.events[s.eventId])) s,
  ]..sort((x, y) => x.callTime.compareTo(y.callTime));
}

class AgencyPeriodBilling {
  const AgencyPeriodBilling({required this.period, required this.lines, required this.problems});

  final PayPeriod period;
  final List<AgencyInvoiceLine> lines;
  final List<PayProblem> problems;

  int get totalCents => lines.fold(0, (s, l) => s + l.amountCents);
  int get minutes => lines.fold(0, (s, l) => s + l.minutes);
}

/// Billable lines per pay period, from the agency's own bill rates, with the same
/// billing engine the venue's invoices use.
List<AgencyPeriodBilling> agencyBillingByPeriod(
  AgencyPortalData d, {
  required String venueId,
  required String timeZone,
  required Map<String, dynamic> venueSettings,
  required DateTime from,
  required DateTime to,
}) {
  final rules = VenueRules.fromJson(venueSettings);
  final temps = [
    for (final m in d.members)
      WorkerPayInput(
        worker: m.toWorker(venueId, WorkerType.temp, agencyId: d.agencyId),
        punches: [for (final p in d.activity.punches) if (p.workerId == m.id) p],
        shifts: [for (final s in d.activity.shifts) if (s.workerId == m.id) s],
      ),
  ];
  final periods = generatePayPeriodsFor(venueRules: rules, payRules: PayRules.fromVenueSettings(venueSettings), from: from, to: to);
  final out = <AgencyPeriodBilling>[];
  for (final p in periods.reversed) {
    final start = p.startsOn.isBefore(from) ? from : p.startsOn;
    final end = p.endsOn.isAfter(to) ? to : p.endsOn;
    final result = calculateAgencyBilling(
      timeZone: timeZone,
      overtimeRules: rules.overtime,
      from: start,
      to: end,
      temps: temps,
      events: d.activity.events,
      billRates: d.billRates,
      breakRules: rules.breaks,
    );
    final lines = result.invoice(d.agencyId)?.lines ?? const <AgencyInvoiceLine>[];
    if (lines.isEmpty) continue;
    out.add(AgencyPeriodBilling(period: p, lines: lines, problems: result.problems));
  }
  return out;
}

String _csvCell(Object? v) {
  final s = '${v ?? ''}';
  return RegExp(r'[",\n\r]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
}

String toCsv(List<List<Object?>> rows) => '${rows.map((r) => r.map(_csvCell).join(',')).join('\r\n')}\r\n';

/// The NPO group's statement: one row per event payout.
String npoStatementCsv(NpoPortalData d, String timeZone) => toCsv([
      ['Group', 'Event', 'Date', 'Scheduled', 'Worked', 'No-shows', 'Hours', 'Rate', 'Gross', 'Deductions', 'Adjustment', 'Adjustment reason', 'Total', 'Status', 'Paid on', 'Payment reference'],
      for (final p in d.payouts)
        [
          d.groupName,
          d.eventNames[p.eventId] ?? d.activity.events[p.eventId]?.name ?? '',
          if (d.activity.events[p.eventId] case final e?) dateOnly(localDateOf(e.startTime, timeZone)) else '',
          p.membersScheduled,
          p.membersWorked,
          p.noShows,
          formatHundredths(p.hoursHundredths),
          formatCents(p.hourlyRateCents),
          formatCents(p.grossCents),
          formatCents(p.deductionsCents),
          formatCents(p.adjustmentCents),
          p.adjustmentReason,
          formatCents(p.totalCents),
          p.status,
          p.paidAt == null ? '' : dateOnly(localDateOf(p.paidAt!, timeZone)),
          p.paymentReference,
        ],
    ]);

/// The agency's billable lines.
String agencyBillingCsv(AgencyPortalData d, List<AgencyPeriodBilling> periods, {required String Function(String) roleName}) {
  final members = {for (final m in d.members) m.id: m};
  return toCsv([
    ['Agency', 'Pay period', 'Date', 'Event', 'Employee number', 'Name', 'Role', 'Regular hours', 'Overtime hours', 'Bill rate', 'Overtime bill rate', 'Amount'],
    for (final p in periods)
      for (final l in p.lines)
        [
          d.agencyName,
          '${dateOnly(p.period.startsOn)} to ${dateOnly(p.period.endsOn)}',
          dateOnly(l.firstWorkDate),
          d.activity.events[l.eventId]?.name ?? '',
          members[l.workerId]?.employeeNumber ?? '',
          members[l.workerId]?.displayName ?? '',
          l.jobRoleCode == null ? '' : roleName(l.jobRoleCode!),
          formatHundredths(l.regularHoursHundredths),
          formatHundredths(l.overtimeHoursHundredths),
          l.billRateCents == null ? '' : formatCents(l.billRateCents!),
          l.overtimeBillRateCents == null ? '' : formatCents(l.overtimeBillRateCents!),
          formatCents(l.amountCents),
        ],
  ]);
}

// ---------------------------------------------------------------------------
// Adding people and the roster import
// ---------------------------------------------------------------------------

/// Next free employee number for the type: E1001.., T2001.., N3001..
String suggestEmployeeNumber(WorkerType type, Iterable<String> existing) {
  final (prefix, start) = switch (type) {
    WorkerType.regular => ('E', 1001),
    WorkerType.temp => ('T', 2001),
    WorkerType.npo => ('N', 3001),
  };
  var max = start - 1;
  final pattern = RegExp('^$prefix(\\d+)\$');
  for (final n in existing) {
    final m = pattern.firstMatch(n);
    if (m != null) {
      final v = int.parse(m.group(1)!);
      if (v > max) max = v;
    }
  }
  return '$prefix${max + 1}';
}

/// Reads yyyy-mm-dd or m/d/yyyy. Null when it is not a real date.
DateTime? parseDate(String s) {
  final t = s.trim();
  int? y, m, d;
  final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(t);
  final us = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(t);
  if (iso != null) {
    (y, m, d) = (int.parse(iso.group(1)!), int.parse(iso.group(2)!), int.parse(iso.group(3)!));
  } else if (us != null) {
    (y, m, d) = (int.parse(us.group(3)!), int.parse(us.group(1)!), int.parse(us.group(2)!));
  } else {
    return null;
  }
  final date = DateTime.utc(y, m, d);
  return date.year == y && date.month == m && date.day == d ? date : null;
}

/// Splits CSV text into rows of cells (quotes, doubled quotes, CRLF).
List<List<String>> parseCsv(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      row.add(cell.toString());
      cell.clear();
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(cell.toString());
      cell.clear();
      if (row.any((x) => x.trim().isNotEmpty)) rows.add(row);
      row = <String>[];
    } else {
      cell.write(c);
    }
  }
  row.add(cell.toString());
  if (row.any((x) => x.trim().isNotEmpty)) rows.add(row);
  return rows;
}

const rosterColumns = [
  'employee_number', 'first_name', 'last_name', 'type', 'phone', 'email', 'date_of_birth', 'roles', 'paycom_code', 'agency', 'npo_group', 'hire_date',
];

class RosterRow {
  const RosterRow({required this.line, required this.cells, this.person, this.errors = const [], this.isUpdate = false});

  /// Line number in the file (the header is line 1).
  final int line;
  final Map<String, String> cells;
  final NewPerson? person;
  final List<String> errors;

  /// The employee number is already on file: importing updates that person.
  final bool isUpdate;

  bool get valid => errors.isEmpty && person != null;
  String get name => '${cells['first_name'] ?? ''} ${cells['last_name'] ?? ''}'.trim();
}

class RosterPreview {
  const RosterPreview({required this.rows, this.problems = const []});

  final List<RosterRow> rows;

  /// Problems with the file itself (missing columns).
  final List<String> problems;

  List<RosterRow> get valid => [for (final r in rows) if (r.valid) r];
  List<RosterRow> get invalid => [for (final r in rows) if (!r.valid) r];
  int get newCount => valid.where((r) => !r.isUpdate).length;
  int get updateCount => valid.where((r) => r.isUpdate).length;
}

/// Checks a roster CSV against the venue: names, type, dates, roles, agency or NPO
/// group, and employee numbers (repeated in the file, or already on file = update).
RosterPreview parseRoster(
  String text, {
  required VenueContext venue,
  required Iterable<String> existingNumbers,
  required DateTime today,
  int minimumAge = 14,
}) {
  final table = parseCsv(text);
  if (table.isEmpty) return const RosterPreview(rows: [], problems: ['The file is empty.']);
  final header = [for (final h in table.first) h.trim().toLowerCase().replaceAll(RegExp(r'[\s-]+'), '_')];
  final missing = [for (final c in const ['employee_number', 'first_name', 'last_name', 'type']) if (!header.contains(c)) c];
  if (missing.isNotEmpty) return RosterPreview(rows: const [], problems: ['Missing columns: ${missing.join(', ')}.']);
  final unknown = [for (final h in header) if (h.isNotEmpty && !rosterColumns.contains(h)) h];

  final onFile = {for (final n in existingNumbers) n.toUpperCase()};
  final seen = <String, int>{};
  final rows = <RosterRow>[];
  String? lookup<T>(String raw, List<T> items, String Function(T) id, List<String> Function(T) names) {
    final key = raw.trim().toLowerCase();
    for (final i in items) {
      if (id(i).toLowerCase() == key || names(i).any((n) => n.toLowerCase() == key)) return id(i);
    }
    return null;
  }

  for (var i = 1; i < table.length; i++) {
    final cells = <String, String>{
      for (var c = 0; c < header.length; c++) header[c]: c < table[i].length ? table[i][c].trim() : '',
    };
    String v(String k) => cells[k] ?? '';
    final errors = <String>[];

    final number = v('employee_number').toUpperCase();
    if (number.isEmpty) {
      errors.add('Employee number is missing');
    } else if (!RegExp(r'^[A-Z0-9-]{2,20}$').hasMatch(number)) {
      errors.add('Employee number "$number" must be 2 to 20 letters, digits or dashes');
    } else if (seen.containsKey(number)) {
      errors.add('Employee number $number is repeated (line ${seen[number]})');
    }
    if (number.isNotEmpty) seen.putIfAbsent(number, () => i + 1);
    if (v('first_name').isEmpty) errors.add('First name is missing');
    if (v('last_name').isEmpty) errors.add('Last name is missing');
    if (v('first_name').length > 80 || v('last_name').length > 80) errors.add('Names are limited to 80 characters');

    final typeText = v('type').toLowerCase();
    final type = switch (typeText) {
      'regular' || 'staff' || 'employee' => WorkerType.regular,
      'temp' || 'agency' => WorkerType.temp,
      'npo' || 'volunteer' => WorkerType.npo,
      _ => null,
    };
    if (type == null) errors.add('Type "${v('type')}" must be regular, temp or npo');

    DateTime? date(String k, String label) {
      if (v(k).isEmpty) return null;
      final d = parseDate(v(k));
      if (d == null) errors.add('$label "${v(k)}" is not a date (use yyyy-mm-dd)');
      return d;
    }

    final dob = date('date_of_birth', 'Birth date');
    if (dob != null) {
      if (dob.isAfter(today)) {
        errors.add('Birth date is in the future');
      } else {
        final age = today.year - dob.year - ((today.month < dob.month || (today.month == dob.month && today.day < dob.day)) ? 1 : 0);
        if (age < minimumAge) errors.add('Under $minimumAge: too young to work');
      }
    }
    final hire = date('hire_date', 'Hire date');

    final roles = <String>[];
    for (final r in v('roles').split(RegExp(r'[;|]')).map((r) => r.trim()).where((r) => r.isNotEmpty)) {
      final code = lookup(r, venue.jobRoles, (j) => j.code, (j) => [j.name]);
      if (code == null) {
        errors.add('Unknown role "$r"');
      } else if (!roles.contains(code)) {
        roles.add(code);
      }
    }

    String? agencyId;
    String? npoId;
    if (type == WorkerType.temp) {
      if (v('agency').isEmpty) {
        errors.add('Temps need an agency');
      } else {
        agencyId = lookup(v('agency'), venue.agencies, (a) => a.id, (a) => [a.name]);
        if (agencyId == null) errors.add('Unknown agency "${v('agency')}"');
      }
    } else if (v('agency').isNotEmpty) {
      errors.add('Only temps have an agency');
    }
    if (type == WorkerType.npo) {
      if (v('npo_group').isEmpty) {
        errors.add('NPO volunteers need a group');
      } else {
        npoId = lookup(v('npo_group'), venue.npoGroups, (g) => g.id, (g) => [g.displayName, g.legalName]);
        if (npoId == null) errors.add('Unknown NPO group "${v('npo_group')}"');
      }
    } else if (v('npo_group').isNotEmpty) {
      errors.add('Only NPO volunteers have a group');
    }
    if (v('email').isNotEmpty && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v('email'))) errors.add('Email "${v('email')}" does not look right');

    rows.add(RosterRow(
      line: i + 1,
      cells: cells,
      errors: errors,
      isUpdate: onFile.contains(number),
      person: errors.isNotEmpty || type == null
          ? null
          : NewPerson(
              type: type,
              employeeNumber: number,
              firstName: v('first_name'),
              lastName: v('last_name'),
              dateOfBirth: dob,
              phone: v('phone'),
              email: v('email'),
              jobRoles: roles,
              agencyId: agencyId,
              npoGroupId: npoId,
              paycomEmployeeCode: type == WorkerType.regular ? v('paycom_code') : '',
              hireDate: hire,
            ),
    ));
  }
  return RosterPreview(rows: rows, problems: [if (unknown.isNotEmpty) 'Ignored columns: ${unknown.join(', ')}.']);
}

/// A sample file with every column.
const rosterTemplate = 'employee_number,first_name,last_name,type,phone,email,date_of_birth,roles,paycom_code,agency,npo_group,hire_date\r\n'
    'E1500,Maria,Lopez,regular,(512) 555-0142,maria@example.com,1998-04-12,cashier;runner,MLOP01,,,2026-11-01\r\n';
