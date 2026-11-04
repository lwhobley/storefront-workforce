/// Report tables as CSV files and as a print-friendly HTML page.
library;

/// One table of a report: a title, column headers, and rows of display text.
class ReportTable {
  const ReportTable({required this.title, required this.columns, required this.rows, this.note = ''});

  final String title;
  final List<String> columns;
  final List<List<String>> rows;

  /// A line under the title (definitions, "estimated", ...).
  final String note;

  /// RFC 4180 CSV with a header row and CRLF line ends.
  String toCsv() {
    final buf = StringBuffer();
    buf.write(csvRow(columns));
    for (final r in rows) {
      buf.write(csvRow(r));
    }
    return buf.toString();
  }
}

/// One CSV line. Fields with commas, quotes or line breaks are quoted; a field that a
/// spreadsheet would run as a formula (=, +, -, @ followed by text) gets a leading quote
/// mark, except plain numbers such as -12.5.
String csvRow(List<String> fields) => '${fields.map(csvField).join(',')}\r\n';

String csvField(String v) {
  var s = v;
  if (s.isNotEmpty && '=+-@'.contains(s[0]) && double.tryParse(s.replaceAll(',', '').replaceAll(r'$', '').replaceAll('%', '')) == null) {
    s = "'$s";
  }
  if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
    s = '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

/// Several tables in one CSV file, each under its title, separated by a blank line.
String tablesToCsv(List<ReportTable> tables) {
  final buf = StringBuffer();
  for (var i = 0; i < tables.length; i++) {
    if (i > 0) buf.write('\r\n');
    buf.write(csvRow([tables[i].title]));
    buf.write(tables[i].toCsv());
  }
  return buf.toString();
}

String htmlEscape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;');

/// A self-contained page that prints cleanly (letter or A4, landscape-friendly tables).
/// With [autoPrint] the browser's print dialog opens when the page loads.
String reportHtml({required String title, required String subtitle, required List<ReportTable> tables, bool autoPrint = true}) {
  final buf = StringBuffer()
    ..writeln('<!doctype html>')
    ..writeln('<html lang="en"><head><meta charset="utf-8">')
    ..writeln('<meta name="viewport" content="width=device-width, initial-scale=1">')
    ..writeln('<title>${htmlEscape(title)}</title>')
    ..writeln('<style>')
    ..writeln('body{font-family:-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:#1b1f23;margin:24px;font-size:12px}')
    ..writeln('h1{font-size:20px;margin:0 0 4px}h2{font-size:14px;margin:20px 0 4px}')
    ..writeln('.sub,.note{color:#57606a;margin:0 0 8px}')
    ..writeln('table{border-collapse:collapse;width:100%;margin-bottom:8px}')
    ..writeln('th,td{border-bottom:1px solid #d0d7de;padding:4px 6px;text-align:left;vertical-align:top}')
    ..writeln('th{background:#f3f4f6;font-weight:600}td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}')
    ..writeln('section{break-inside:avoid-page}')
    ..writeln('@media print{body{margin:0}.noprint{display:none}thead{display:table-header-group}tr{break-inside:avoid}}')
    ..writeln('</style></head><body>')
    ..writeln('<p class="noprint"><button onclick="window.print()">Print</button></p>')
    ..writeln('<h1>${htmlEscape(title)}</h1>')
    ..writeln('<p class="sub">${htmlEscape(subtitle)}</p>');
  for (final t in tables) {
    final numeric = [
      for (var c = 0; c < t.columns.length; c++) c > 0 && t.rows.isNotEmpty && t.rows.every((r) => c >= r.length || _looksNumeric(r[c])),
    ];
    buf
      ..writeln('<section><h2>${htmlEscape(t.title)}</h2>')
      ..writeln(t.note.isEmpty ? '' : '<p class="note">${htmlEscape(t.note)}</p>')
      ..write('<table><thead><tr>');
    for (var c = 0; c < t.columns.length; c++) {
      buf.write('<th${numeric[c] ? ' class="n"' : ''}>${htmlEscape(t.columns[c])}</th>');
    }
    buf.writeln('</tr></thead><tbody>');
    if (t.rows.isEmpty) buf.writeln('<tr><td colspan="${t.columns.length}">Nothing to show.</td></tr>');
    for (final r in t.rows) {
      buf.write('<tr>');
      for (var c = 0; c < t.columns.length; c++) {
        final v = c < r.length ? r[c] : '';
        buf.write('<td${numeric[c] ? ' class="n"' : ''}>${htmlEscape(v)}</td>');
      }
      buf.writeln('</tr>');
    }
    buf.writeln('</tbody></table></section>');
  }
  if (autoPrint) buf.writeln('<script>window.addEventListener("load",function(){setTimeout(function(){window.print()},300)})</script>');
  buf.writeln('</body></html>');
  return buf.toString();
}

bool _looksNumeric(String s) {
  if (s.isEmpty || s == '—') return true;
  return RegExp(r'^[-+]?\$?[\d,]+(\.\d+)?(%|h| min| hrs?)?$').hasMatch(s.trim());
}
