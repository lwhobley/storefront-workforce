/// Payroll provider output: the manual-entry sheet and CSV files.
///
/// [PayrollExporter] is the provider-neutral interface; [PaycomExporter] is the
/// Paycom implementation. Both work from [PayLine]s (approved lines from the
/// database or freshly calculated ones), so hours are the 2-decimal line hours and
/// amounts the line amounts: the sheet always adds up to the approved lines.
///
/// Columns by pay code kind: every code of kind regular adds into "regular",
/// overtime into "overtime", bonus into "bonus", tips into "tips". Differential,
/// tip-credit make-up and other codes get their own column each (all differential
/// codes in the venue's list appear even when zero), ordered by pay_codes.sort.
/// Gross is the sum of all amounts, tips included.
library;

import '../model/entities.dart';
import '../rules/local_time.dart';
import 'money.dart';
import 'pay_models.dart';

enum EntrySheetSort { lastName, employeeCode }

enum EntrySheetMode {
  /// One row per worker for the period.
  periodTotals,

  /// One row per worker per work date.
  daily,
}

class EntrySheetOptions {
  const EntrySheetOptions({this.sort = EntrySheetSort.lastName, this.mode = EntrySheetMode.periodTotals});

  final EntrySheetSort sort;
  final EntrySheetMode mode;

  factory EntrySheetOptions.fromCodes({String sort = 'last_name', String mode = 'period_totals'}) => EntrySheetOptions(
    sort: switch (sort) {
      'last_name' => EntrySheetSort.lastName,
      'employee_code' => EntrySheetSort.employeeCode,
      _ => throw ArgumentError.value(sort, 'sort', 'must be last_name or employee_code'),
    },
    mode: switch (mode) {
      'period_totals' => EntrySheetMode.periodTotals,
      'daily' => EntrySheetMode.daily,
      _ => throw ArgumentError.value(mode, 'mode', 'must be period_totals or daily'),
    },
  );
}

/// An extra column on the sheet (a differential, TIPMU, or other code).
class EntrySheetCodeColumn {
  const EntrySheetCodeColumn({required this.code, required this.name, required this.kind, required this.paycomCode});

  final String code;
  final String name;
  final PayCodeKind kind;

  /// Paycom's code, falling back to [code] when the venue has not entered one.
  final String paycomCode;
}

class EntrySheetRow {
  const EntrySheetRow({
    required this.workerId,
    required this.employeeCode,
    required this.lastName,
    required this.firstName,
    required this.workDate,
    required this.regularHundredths,
    required this.regularCents,
    required this.overtimeHundredths,
    required this.overtimeCents,
    required this.codes,
    required this.bonusCents,
    required this.tipsCents,
    required this.grossCents,
    required this.missingEmployeeCode,
  });

  /// Null on the grand totals row.
  final String? workerId;
  final String employeeCode;
  final String lastName;
  final String firstName;

  /// Set in daily mode.
  final DateTime? workDate;
  final int regularHundredths;
  final int regularCents;
  final int overtimeHundredths;
  final int overtimeCents;

  /// Extra code columns: code -> hours and amount.
  final Map<String, ({int hundredths, int cents})> codes;
  final int bonusCents;
  final int tipsCents;
  final int grossCents;

  /// The worker has no Paycom employee code (or is not in the worker list).
  final bool missingEmployeeCode;
}

class EntrySheet {
  const EntrySheet({
    required this.period,
    required this.columns,
    required this.rows,
    required this.totals,
    required this.missingPaycomCode,
  });

  final PayPeriod period;
  final List<EntrySheetCodeColumn> columns;
  final List<EntrySheetRow> rows;

  /// Grand totals (workerId null).
  final EntrySheetRow totals;

  /// Worker ids with no Paycom employee code. They are still on the sheet, flagged.
  final List<String> missingPaycomCode;
}

/// Field keys a CSV column can show.
enum CsvField {
  employeeCode('employee_code'),
  lastName('last_name'),
  firstName('first_name'),
  workDate('work_date'),
  periodStart('period_start'),
  periodEnd('period_end'),
  payCode('pay_code'),
  paycomCode('paycom_code'),
  hours('hours'),
  rate('rate'),
  amount('amount'),
  department('department'),
  jobRole('job_role');

  const CsvField(this.key);
  final String key;

  static CsvField fromKey(String key) =>
      values.firstWhere((v) => v.key == key, orElse: () => throw ArgumentError.value(key, 'key', 'unknown CSV field'));
}

class CsvColumn {
  const CsvColumn(this.header, this.field);

  final String header;
  final CsvField field;

  factory CsvColumn.fromJson(Map<String, dynamic> j) =>
      CsvColumn(j['header'] as String, CsvField.fromKey(j['field'] as String));

  Map<String, dynamic> toJson() => {'header': header, 'field': field.key};
}

enum CsvStyle {
  /// One row per pay line (import file).
  lines,

  /// One row per worker (entry style): hours = regular + overtime hours, amount =
  /// gross; rate, pay code and work date are blank; department and job role are
  /// filled only when all of the worker's lines agree.
  workers,
}

class CsvOptions {
  const CsvOptions({
    this.columns = PaycomExporter.defaultColumns,
    this.style = CsvStyle.lines,
    this.sort = EntrySheetSort.lastName,
    this.includeHeader = true,
    this.rateDecimals = 4,
    this.guardFormulas = false,
  });

  final List<CsvColumn> columns;
  final CsvStyle style;
  final EntrySheetSort sort;
  final bool includeHeader;

  /// Rate is stored to 4 decimals (an OT rate can be 23.2550); 2 rounds half-up.
  final int rateDecimals;

  /// Prefix text cells starting with = + - @ with an apostrophe, so a spreadsheet
  /// does not run them as formulas. Off by default because it changes the data.
  final bool guardFormulas;
}

class CsvExport {
  const CsvExport({
    required this.text,
    required this.rowCount,
    required this.workedHoursHundredths,
    required this.hoursColumnHundredths,
    required this.totalAmountCents,
  });

  /// RFC 4180 text, CRLF line endings (including after the last row).
  final String text;

  /// Data rows, not counting the header.
  final int rowCount;

  /// Hours worked: lines of kind regular and overtime. Use this for
  /// payroll_exports.total_hours (differential hours repeat worked hours).
  final int workedHoursHundredths;

  /// Sum of the hours column as written (differential hours included).
  final int hoursColumnHundredths;
  final int totalAmountCents;
}

/// A payroll provider's output.
abstract interface class PayrollExporter {
  /// Stored in payroll_exports.provider.
  String get provider;

  EntrySheet entrySheet({
    required PayPeriod period,
    required List<PayLine> lines,
    required Map<String, Worker> workers,
    required List<PayCode> payCodes,
    EntrySheetOptions options,
  });

  CsvExport csv({
    required PayPeriod period,
    required List<PayLine> lines,
    required Map<String, Worker> workers,
    required List<PayCode> payCodes,
    Map<String, Storefront> storefronts,
    CsvOptions options,
  });
}

/// Paycom: manual entry sheet and CSV.
class PaycomExporter implements PayrollExporter {
  const PaycomExporter();

  static const defaultColumns = [
    CsvColumn('Employee Code', CsvField.employeeCode),
    CsvColumn('Last Name', CsvField.lastName),
    CsvColumn('First Name', CsvField.firstName),
    CsvColumn('Work Date', CsvField.workDate),
    CsvColumn('Earning Code', CsvField.paycomCode),
    CsvColumn('Hours', CsvField.hours),
    CsvColumn('Rate', CsvField.rate),
    CsvColumn('Amount', CsvField.amount),
    CsvColumn('Department', CsvField.department),
    CsvColumn('Job', CsvField.jobRole),
  ];

  @override
  String get provider => 'paycom';

  @override
  EntrySheet entrySheet({
    required PayPeriod period,
    required List<PayLine> lines,
    required Map<String, Worker> workers,
    required List<PayCode> payCodes,
    EntrySheetOptions options = const EntrySheetOptions(),
  }) {
    final codes = {for (final c in payCodes) c.code: c};
    PayCodeKind kindOf(String code) => codes[code]?.kind ?? PayCodes.defaultKind(code);
    bool isExtra(PayCodeKind k) =>
        k == PayCodeKind.differential || k == PayCodeKind.tipCreditMakeup || k == PayCodeKind.other;

    final extra =
        <String>{
          for (final c in payCodes)
            if (c.kind == PayCodeKind.differential) c.code,
          for (final l in lines)
            if (isExtra(kindOf(l.payCode))) l.payCode,
        }.toList()..sort((a, b) {
          final c = (codes[a]?.sort ?? 1 << 20).compareTo(codes[b]?.sort ?? 1 << 20);
          return c != 0 ? c : a.compareTo(b);
        });
    final columns = [
      for (final code in extra)
        EntrySheetCodeColumn(
          code: code,
          name: codes[code]?.name ?? code,
          kind: kindOf(code),
          paycomCode: _paycomCode(codes[code], code),
        ),
    ];

    final groups = <String, List<PayLine>>{};
    for (final l in lines) {
      final key = options.mode == EntrySheetMode.daily ? '${l.workerId}|${formatDate(l.workDate)}' : l.workerId;
      groups.putIfAbsent(key, () => []).add(l);
    }

    EntrySheetRow build(String? workerId, DateTime? date, List<PayLine> ls) {
      var regH = 0, regC = 0, otH = 0, otC = 0, bonus = 0, tips = 0, gross = 0;
      final byCode = <String, ({int hundredths, int cents})>{for (final c in extra) c: (hundredths: 0, cents: 0)};
      for (final l in ls) {
        gross += l.amountCents;
        switch (kindOf(l.payCode)) {
          case PayCodeKind.regular:
            regH += l.hoursHundredths;
            regC += l.amountCents;
          case PayCodeKind.overtime:
            otH += l.hoursHundredths;
            otC += l.amountCents;
          case PayCodeKind.bonus:
            bonus += l.amountCents;
          case PayCodeKind.tips:
            tips += l.amountCents;
          default:
            final prev = byCode[l.payCode]!;
            byCode[l.payCode] = (hundredths: prev.hundredths + l.hoursHundredths, cents: prev.cents + l.amountCents);
        }
      }
      final w = workerId == null ? null : workers[workerId];
      return EntrySheetRow(
        workerId: workerId,
        employeeCode: w?.paycomEmployeeCode.trim() ?? '',
        lastName: w?.lastName ?? '',
        firstName: w?.firstName ?? '',
        workDate: date,
        regularHundredths: regH,
        regularCents: regC,
        overtimeHundredths: otH,
        overtimeCents: otC,
        codes: Map.unmodifiable(byCode),
        bonusCents: bonus,
        tipsCents: tips,
        grossCents: gross,
        missingEmployeeCode: workerId != null && (w == null || w.paycomEmployeeCode.trim().isEmpty),
      );
    }

    final rows = [
      for (final ls in groups.values)
        build(ls.first.workerId, options.mode == EntrySheetMode.daily ? ls.first.workDate : null, ls),
    ]..sort((a, b) => _compareRows(a, b, options.sort));
    final missing = <String>{
      for (final r in rows)
        if (r.missingEmployeeCode) r.workerId!,
    }.toList()..sort();
    return EntrySheet(
      period: period,
      columns: List.unmodifiable(columns),
      rows: List.unmodifiable(rows),
      totals: build(null, null, lines),
      missingPaycomCode: List.unmodifiable(missing),
    );
  }

  @override
  CsvExport csv({
    required PayPeriod period,
    required List<PayLine> lines,
    required Map<String, Worker> workers,
    required List<PayCode> payCodes,
    Map<String, Storefront> storefronts = const {},
    CsvOptions options = const CsvOptions(),
  }) {
    final codes = {for (final c in payCodes) c.code: c};
    PayCodeKind kindOf(String code) => codes[code]?.kind ?? PayCodes.defaultKind(code);
    bool worked(PayLine l) => kindOf(l.payCode) == PayCodeKind.regular || kindOf(l.payCode) == PayCodeKind.overtime;
    String dept(String? storefrontId) => storefrontId == null ? '' : (storefronts[storefrontId]?.code ?? '');

    String text(String v) {
      if (options.guardFormulas && v.isNotEmpty && '=+-@\t\r'.contains(v[0])) return "'$v";
      return v;
    }

    final buffer = StringBuffer();
    void writeRow(List<String> cells) {
      buffer.write(cells.map(csvEscape).join(','));
      buffer.write('\r\n');
    }

    if (options.includeHeader) writeRow([for (final c in options.columns) c.header]);

    var rowCount = 0, workedHours = 0, hoursColumn = 0, amount = 0;
    final hasHours = options.columns.any((c) => c.field == CsvField.hours);

    String workerText(Worker? w, CsvField f) => switch (f) {
      CsvField.employeeCode => text(w?.paycomEmployeeCode.trim() ?? ''),
      CsvField.lastName => text(w?.lastName ?? ''),
      CsvField.firstName => text(w?.firstName ?? ''),
      CsvField.periodStart => formatDate(period.startsOn),
      CsvField.periodEnd => formatDate(period.endsOn),
      _ => '',
    };

    final sortRows = <(EntrySheetRow, List<String>, int, int)>[];
    if (options.style == CsvStyle.lines) {
      for (final l in lines) {
        final w = workers[l.workerId];
        final cells = [
          for (final c in options.columns)
            switch (c.field) {
              CsvField.workDate => formatDate(l.workDate),
              CsvField.payCode => text(l.payCode),
              CsvField.paycomCode => text(_paycomCode(codes[l.payCode], l.payCode)),
              CsvField.hours => formatHundredths(l.hoursHundredths),
              CsvField.rate => l.rateE4 == null ? '' : formatE4(l.rateE4!, decimals: options.rateDecimals),
              CsvField.amount => formatCents(l.amountCents),
              CsvField.department => text(dept(l.storefrontId)),
              CsvField.jobRole => text(l.jobRoleCode ?? ''),
              _ => workerText(w, c.field),
            },
        ];
        sortRows.add((_sortKey(l.workerId, w, l.workDate), cells, l.hoursHundredths, l.amountCents));
        if (worked(l)) workedHours += l.hoursHundredths;
      }
    } else {
      final byWorker = <String, List<PayLine>>{};
      for (final l in lines) {
        byWorker.putIfAbsent(l.workerId, () => []).add(l);
      }
      for (final e in byWorker.entries) {
        final w = workers[e.key];
        final ls = e.value;
        final hours = ls.where(worked).fold(0, (s, l) => s + l.hoursHundredths);
        final gross = ls.fold(0, (s, l) => s + l.amountCents);
        final depts = {for (final l in ls) dept(l.storefrontId)};
        final roles = {for (final l in ls.where(worked)) l.jobRoleCode ?? ''};
        final cells = [
          for (final c in options.columns)
            switch (c.field) {
              CsvField.hours => formatHundredths(hours),
              CsvField.amount => formatCents(gross),
              CsvField.department => text(depts.length == 1 ? depts.first : ''),
              CsvField.jobRole => text(roles.length == 1 ? roles.first : ''),
              CsvField.workDate || CsvField.payCode || CsvField.paycomCode || CsvField.rate => '',
              _ => workerText(w, c.field),
            },
        ];
        sortRows.add((_sortKey(e.key, w, null), cells, hours, gross));
        workedHours += hours;
      }
    }
    // Stable sort by worker (per options.sort), then date; lines keep their order within.
    final indexed = [for (var i = 0; i < sortRows.length; i++) (i, sortRows[i])];
    indexed.sort((a, b) {
      final c = _compareRows(a.$2.$1, b.$2.$1, options.sort);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    for (final (_, r) in indexed) {
      writeRow(r.$2);
      rowCount++;
      if (hasHours) hoursColumn += r.$3;
      amount += r.$4;
    }
    return CsvExport(
      text: buffer.toString(),
      rowCount: rowCount,
      workedHoursHundredths: workedHours,
      hoursColumnHundredths: hoursColumn,
      totalAmountCents: amount,
    );
  }
}

String _paycomCode(PayCode? c, String code) => (c == null || c.paycomCode.trim().isEmpty) ? code : c.paycomCode.trim();

/// A row used only for sorting.
EntrySheetRow _sortKey(String workerId, Worker? w, DateTime? date) => EntrySheetRow(
  workerId: workerId,
  employeeCode: w?.paycomEmployeeCode.trim() ?? '',
  lastName: w?.lastName ?? '',
  firstName: w?.firstName ?? '',
  workDate: date,
  regularHundredths: 0,
  regularCents: 0,
  overtimeHundredths: 0,
  overtimeCents: 0,
  codes: const {},
  bonusCents: 0,
  tipsCents: 0,
  grossCents: 0,
  missingEmployeeCode: false,
);

final _digits = RegExp(r'^\d+$');

int _compareCodes(String a, String b) {
  if (a.isEmpty != b.isEmpty) return a.isEmpty ? 1 : -1; // Missing codes last.
  if (_digits.hasMatch(a) && _digits.hasMatch(b)) {
    final c = BigInt.parse(a).compareTo(BigInt.parse(b));
    if (c != 0) return c;
  }
  return a.compareTo(b);
}

int _compareNames(EntrySheetRow a, EntrySheetRow b) {
  var c = a.lastName.toLowerCase().compareTo(b.lastName.toLowerCase());
  if (c != 0) return c;
  c = a.firstName.toLowerCase().compareTo(b.firstName.toLowerCase());
  return c;
}

int _compareRows(EntrySheetRow a, EntrySheetRow b, EntrySheetSort sort) {
  var c = sort == EntrySheetSort.lastName ? _compareNames(a, b) : _compareCodes(a.employeeCode, b.employeeCode);
  if (c != 0) return c;
  c = sort == EntrySheetSort.lastName ? _compareCodes(a.employeeCode, b.employeeCode) : _compareNames(a, b);
  if (c != 0) return c;
  c = (a.workerId ?? '').compareTo(b.workerId ?? '');
  if (c != 0) return c;
  final da = a.workDate, db = b.workDate;
  if (da != null && db != null) return da.compareTo(db);
  return 0;
}

/// One CSV cell per RFC 4180: quoted when it has a comma, quote, CR or LF, with
/// quotes doubled.
String csvEscape(String v) {
  if (v.contains(',') || v.contains('"') || v.contains('\r') || v.contains('\n')) {
    return '"${v.replaceAll('"', '""')}"';
  }
  return v;
}
