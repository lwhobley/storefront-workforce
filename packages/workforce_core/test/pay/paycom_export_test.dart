import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

import 'pay_helpers.dart';

void main() {
  const exporter = PaycomExporter();
  final workers = {
    'w1': worker('w1', first: 'Zed', last: 'Adams', code: '1002'),
    'w2': worker('w2', first: 'Ann "AJ"', last: 'Smith, Jr.', code: '998'),
    'w3': worker('w3', first: 'Lou', last: 'Doe'), // no Paycom code
  };
  final payCodes = [
    const PayCode(venueId: 'v1', code: 'REG', name: 'Regular', kind: PayCodeKind.regular, paycomCode: 'E01', sort: 1),
    const PayCode(venueId: 'v1', code: 'OT', name: 'Overtime', kind: PayCodeKind.overtime, paycomCode: 'E02', sort: 2),
    const PayCode(venueId: 'v1', code: 'TIPS', name: 'Tips', kind: PayCodeKind.tips, paycomCode: 'T1', sort: 3),
    const PayCode(venueId: 'v1', code: 'LEAD', name: 'Lead differential', kind: PayCodeKind.differential, sort: 4),
    const PayCode(venueId: 'v1', code: 'BONUS', name: 'Bonus', kind: PayCodeKind.bonus, paycomCode: 'B1', sort: 5),
    const PayCode(venueId: 'v1', code: 'TIPMU', name: 'Tip credit make-up', kind: PayCodeKind.tipCreditMakeup, sort: 6),
  ];
  final storefronts = {
    'sf1': const Storefront(
      id: 'sf1',
      venueId: 'v1',
      levelId: 'l1',
      code: '214',
      name: 'Burgers',
      kind: StorefrontKind.permanentStand,
      section: '',
      mapX: 0,
      mapY: 0,
    ),
  };
  PayLine line(String w, int d, String code, int hundredths, int? rateE4, int cents, {String? sf = 'sf1'}) => PayLine(
    workerId: w,
    workDate: day(2026, 11, d),
    eventId: 'e$d',
    storefrontId: sf,
    jobRoleCode: code == 'TIPS' || code == 'BONUS' ? null : 'cashier',
    payCode: code,
    hoursHundredths: hundredths,
    rateE4: rateE4,
    amountCents: cents,
  );
  final lines = [
    line('w1', 9, 'REG', 800, 150000, 12000),
    line('w1', 10, 'REG', 800, 150000, 12000),
    line('w1', 10, 'OT', 100, 225000, 2250),
    line('w1', 10, 'LEAD', 900, 20000, 1800),
    line('w1', 10, 'BONUS', 0, null, 2000),
    line('w1', 10, 'TIPS', 0, null, 3525),
    line('w2', 9, 'REG', 600, 150000, 9000, sf: null),
    line('w3', 11, 'REG', 500, 150000, 7500),
    line('w3', 11, 'TIPMU', 0, null, 1000),
  ];
  // w1 gross 120 + 120 + 22.50 + 18 + 20 + 35.25 = 335.75; w2 90.00; w3 85.00. Total 510.75.

  group('entry sheet', () {
    test('period totals sorted by last name, with code columns and grand totals', () {
      final sheet = exporter.entrySheet(period: novPeriod, lines: lines, workers: workers, payCodes: payCodes);
      expect(sheet.rows.map((r) => r.lastName), ['Adams', 'Doe', 'Smith, Jr.']);
      expect(sheet.columns.map((c) => c.code), ['LEAD', 'TIPMU']);
      expect(sheet.columns.first.paycomCode, 'LEAD'); // no Paycom code entered: falls back to ours
      final w1 = sheet.rows.first;
      expect(w1.employeeCode, '1002');
      expect(w1.regularHundredths, 1600);
      expect(w1.regularCents, 24000);
      expect(w1.overtimeHundredths, 100);
      expect(w1.overtimeCents, 2250);
      expect(w1.codes['LEAD'], (hundredths: 900, cents: 1800));
      expect(w1.codes['TIPMU'], (hundredths: 0, cents: 0));
      expect(w1.bonusCents, 2000);
      expect(w1.tipsCents, 3525);
      expect(w1.grossCents, 33575);
      final t = sheet.totals;
      expect(t.workerId, isNull);
      expect(t.regularHundredths, 2700);
      expect(t.regularCents, 40500);
      expect(t.codes['TIPMU']!.cents, 1000);
      expect(t.grossCents, 51075);
      expect(sheet.rows.fold(0, (s, r) => s + r.grossCents), t.grossCents);
      expect(t.grossCents, sumCents(lines));
    });

    test('missing Paycom code is flagged, not dropped', () {
      final sheet = exporter.entrySheet(period: novPeriod, lines: lines, workers: workers, payCodes: payCodes);
      expect(sheet.missingPaycomCode, ['w3']);
      final w3 = sheet.rows.singleWhere((r) => r.workerId == 'w3');
      expect(w3.missingEmployeeCode, isTrue);
      expect(w3.grossCents, 8500);
    });

    test('sort by employee code: numeric order, missing codes last', () {
      final sheet = exporter.entrySheet(
        period: novPeriod,
        lines: lines,
        workers: workers,
        payCodes: payCodes,
        options: EntrySheetOptions.fromCodes(sort: 'employee_code'),
      );
      expect(sheet.rows.map((r) => r.employeeCode), ['998', '1002', '']);
    });

    test('daily mode: one row per worker per date', () {
      final sheet = exporter.entrySheet(
        period: novPeriod,
        lines: lines,
        workers: workers,
        payCodes: payCodes,
        options: const EntrySheetOptions(mode: EntrySheetMode.daily),
      );
      expect(sheet.rows.map((r) => '${r.workerId} ${formatDate(r.workDate!)} ${r.grossCents}'), [
        'w1 2026-11-09 12000',
        'w1 2026-11-10 21575',
        'w3 2026-11-11 8500',
        'w2 2026-11-09 9000',
      ]);
      expect(sheet.totals.grossCents, 51075);
    });

    test('bad option codes throw', () {
      expect(() => EntrySheetOptions.fromCodes(sort: 'first_name'), throwsArgumentError);
      expect(() => EntrySheetOptions.fromCodes(mode: 'weekly'), throwsArgumentError);
    });
  });

  group('CSV', () {
    test('import style: one row per line, RFC 4180 escaping, CRLF, fixed decimals', () {
      final csv = exporter.csv(
        period: novPeriod,
        lines: lines,
        workers: workers,
        payCodes: payCodes,
        storefronts: storefronts,
      );
      final rows = csv.text.split('\r\n');
      expect(rows.last, ''); // ends with CRLF
      expect(csv.text.replaceAll('\r\n', ''), isNot(contains('\n')));
      expect(rows.first, 'Employee Code,Last Name,First Name,Work Date,Earning Code,Hours,Rate,Amount,Department,Job');
      expect(rows[1], '1002,Adams,Zed,2026-11-09,E01,8.00,15.0000,120.00,214,cashier');
      expect(rows.contains('1002,Adams,Zed,2026-11-10,LEAD,9.00,2.0000,18.00,214,cashier'), isTrue);
      expect(rows.contains('1002,Adams,Zed,2026-11-10,T1,0.00,,35.25,214,'), isTrue);
      expect(rows.contains(',Doe,Lou,2026-11-11,TIPMU,0.00,,10.00,214,cashier'), isTrue);
      expect(rows.contains('998,"Smith, Jr.","Ann ""AJ""",2026-11-09,E01,6.00,15.0000,90.00,,cashier'), isTrue);
      expect(csv.rowCount, 9);
      expect(csv.totalAmountCents, 51075);
      expect(csv.workedHoursHundredths, 2800); // REG 27h + OT 1h
      expect(csv.hoursColumnHundredths, 3700); // plus 9 LEAD hours
    });

    test('configurable columns, 2-decimal rate, no header', () {
      final csv = exporter.csv(
        period: novPeriod,
        lines: [lines[2]],
        workers: workers,
        payCodes: payCodes,
        options: CsvOptions(
          columns: [
            const CsvColumn('ID', CsvField.employeeCode),
            const CsvColumn('Start', CsvField.periodStart),
            const CsvColumn('End', CsvField.periodEnd),
            const CsvColumn('Code', CsvField.payCode),
            CsvColumn.fromJson({'header': 'Rate, per hour', 'field': 'rate'}),
          ],
          rateDecimals: 2,
          includeHeader: false,
        ),
      );
      expect(csv.text, '1002,2026-11-09,2026-11-22,OT,22.50\r\n');
      expect(csv.hoursColumnHundredths, 0);
    });

    test('header text with a comma is quoted', () {
      final csv = exporter.csv(
        period: novPeriod,
        lines: const [],
        workers: workers,
        payCodes: payCodes,
        options: const CsvOptions(columns: [CsvColumn('Hours, total', CsvField.hours)]),
      );
      expect(csv.text, '"Hours, total"\r\n');
      expect(csv.rowCount, 0);
    });

    test('entry style: one row per worker', () {
      final csv = exporter.csv(
        period: novPeriod,
        lines: lines,
        workers: workers,
        payCodes: payCodes,
        storefronts: storefronts,
        options: const CsvOptions(
          style: CsvStyle.workers,
          sort: EntrySheetSort.employeeCode,
          columns: [
            CsvColumn('Code', CsvField.employeeCode),
            CsvColumn('Name', CsvField.lastName),
            CsvColumn('Hours', CsvField.hours),
            CsvColumn('Gross', CsvField.amount),
            CsvColumn('Dept', CsvField.department),
            CsvColumn('Pay code', CsvField.payCode),
          ],
        ),
      );
      expect(csv.text.split('\r\n'), [
        'Code,Name,Hours,Gross,Dept,Pay code',
        '998,"Smith, Jr.",6.00,90.00,,',
        '1002,Adams,17.00,335.75,214,',
        ',Doe,5.00,85.00,214,',
        '',
      ]);
      expect(csv.rowCount, 3);
      expect(csv.totalAmountCents, 51075);
      expect(csv.workedHoursHundredths, 2800);
    });

    test('formula guard (opt-in)', () {
      final w = {'x': worker('x', first: '=HYPERLINK("x")', last: '-Lee', code: '7')};
      final l = [PayLine(workerId: 'x', workDate: day(2026, 11, 9), payCode: 'REG', amountCents: -500)];
      const cols = [
        CsvColumn('Last', CsvField.lastName),
        CsvColumn('First', CsvField.firstName),
        CsvColumn('Amount', CsvField.amount),
      ];
      final plain = exporter.csv(
        period: novPeriod,
        lines: l,
        workers: w,
        payCodes: payCodes,
        options: const CsvOptions(columns: cols, includeHeader: false),
      );
      expect(plain.text, '-Lee,"=HYPERLINK(""x"")",-5.00\r\n');
      final guarded = exporter.csv(
        period: novPeriod,
        lines: l,
        workers: w,
        payCodes: payCodes,
        options: const CsvOptions(columns: cols, includeHeader: false, guardFormulas: true),
      );
      expect(guarded.text, '\'-Lee,"\'=HYPERLINK(""x"")",-5.00\r\n');
    });

    test('csvEscape', () {
      expect(csvEscape('plain'), 'plain');
      expect(csvEscape('a,b'), '"a,b"');
      expect(csvEscape('say "hi"'), '"say ""hi"""');
      expect(csvEscape('two\nlines'), '"two\nlines"');
      expect(csvEscape('cr\r'), '"cr\r"');
    });

    test('provider name for payroll_exports', () {
      const PayrollExporter e = PaycomExporter();
      expect(e.provider, 'paycom');
    });
  });
}
