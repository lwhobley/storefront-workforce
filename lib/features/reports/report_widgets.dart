import 'package:flutter/material.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../core/download.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import 'print_view.dart';
import 'report_tables.dart';

/// A KPI tile: the number, colored by its target, with a short detail line.
class KpiTile extends StatelessWidget {
  const KpiTile({super.key, required this.label, required this.value, this.detail, this.rag = Rag.none, this.onTap});

  final String label;
  final String value;
  final String? detail;
  final Rag rag;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tone = ragTone(rag);
    return Semantics(
      label: rag == Rag.none ? null : '$label $value, ${ragLabel(rag)}',
      child: Stack(
        children: [
          SizedBox(width: double.infinity, child: StatTile(label: label, value: value, detail: detail, tone: tone, onTap: onTap)),
          if (tone != null)
            Positioned(
              right: 10,
              top: 10,
              child: Tooltip(
                message: ragLabel(rag),
                child: Icon(
                  switch (rag) {
                    Rag.green => Icons.check_circle,
                    Rag.yellow => Icons.error_outline,
                    _ => Icons.cancel_outlined,
                  },
                  size: 16,
                  color: toneColor(tone, context),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Tiles in a grid: two across on phones, as many as fit on wider screens.
class KpiGrid extends StatelessWidget {
  const KpiGrid({super.key, required this.tiles});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
        child: LayoutBuilder(builder: (context, box) {
          final across = box.maxWidth >= 1000 ? 5 : box.maxWidth >= 700 ? 4 : 2;
          final w = (box.maxWidth - 10 * (across - 1)) / across;
          return Wrap(spacing: 10, runSpacing: 10, children: [for (final t in tiles) SizedBox(width: w, child: t)]);
        }),
      );
}

/// A table on wide screens; on phones, one card per row with the columns as label and value.
class KpiTableView extends StatelessWidget {
  const KpiTableView(this.view, {super.key, this.maxRows, this.showTitle = true});

  final ViewTable view;
  final int? maxRows;
  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final t = view.table;
    final rows = maxRows == null ? t.rows : t.rows.take(maxRows!).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showTitle) SectionHeading(t.title),
        if (t.note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.screen, 0, AppSpace.screen, AppSpace.s),
            child: Text(t.note, style: AppText.meta),
          ),
        if (rows.isEmpty) const EmptyNote('Nothing to show yet.'),
        if (rows.isNotEmpty)
          LayoutBuilder(builder: (context, box) {
            if (box.maxWidth >= 760) return _wide(context, rows);
            return Column(children: [for (var i = 0; i < rows.length; i++) _card(context, i, rows[i])]);
          }),
        if (maxRows != null && t.rows.length > maxRows!)
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.s, AppSpace.screen, 0),
            child: Text('Showing ${maxRows!} of ${t.rows.length}. The CSV has them all.', style: AppText.meta),
          ),
      ],
    );
  }

  Widget _cell(BuildContext context, int r, int c, String text, {bool bold = false}) {
    final tone = view.tones[(r, c)];
    if (tone == null) return Text(text, style: bold ? const TextStyle(fontWeight: FontWeight.w600) : null);
    return StatusTag(text, tone);
  }

  Widget _wide(BuildContext context, List<List<String>> rows) {
    final t = view.table;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen - 4),
      child: DataTable(
        headingRowHeight: 40,
        dataRowMinHeight: 36,
        dataRowMaxHeight: 52,
        columnSpacing: 18,
        horizontalMargin: 4,
        showCheckboxColumn: false,
        headingTextStyle: AppText.meta.copyWith(fontWeight: FontWeight.w700),
        columns: [for (final c in t.columns) DataColumn(label: Text(c))],
        rows: [
          for (var r = 0; r < rows.length; r++)
            DataRow(
              onSelectChanged: view.onTap[r] == null ? null : (_) => view.onTap[r]!(),
              cells: [
                for (var c = 0; c < t.columns.length; c++)
                  DataCell(
                    c == 1 && t.columns.length > 6
                        ? ConstrainedBox(constraints: const BoxConstraints(maxWidth: 260), child: _cell(context, r, c, c < rows[r].length ? rows[r][c] : ''))
                        : _cell(context, r, c, c < rows[r].length ? rows[r][c] : '', bold: c == 0),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, int r, List<String> row) {
    final t = view.table;
    // Title: the first column, or the first two when the first is a date.
    final dated = t.columns.first == 'Date' && row.length > 1;
    final title = dated ? row[1] : row.first;
    final subtitle = dated ? row.first : null;
    final skip = dated ? {0, 1} : {0};
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: AppSpace.screen, vertical: 4),
      child: InkWell(
        onTap: view.onTap[r],
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
                if (view.onTap[r] != null) const Icon(Icons.chevron_right, size: 20, color: AppColors.muted),
              ]),
              if (subtitle != null) Text(subtitle, style: AppText.meta),
              const SizedBox(height: 6),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  for (var c = 0; c < t.columns.length && c < row.length; c++)
                    if (!skip.contains(c) && row[c].isNotEmpty)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(t.columns[c], style: AppText.meta.copyWith(fontSize: 11)),
                          _cell(context, r, c, row[c], bold: true),
                        ],
                      ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Downloads [tables] as one CSV file.
Future<void> exportCsv(BuildContext context, String fileName, List<ViewTable> tables) async {
  final csv = tablesToCsv([for (final t in tables) t.table]);
  final downloaded = await saveTextFile(fileName, csv);
  if (context.mounted) showMessage(context, downloaded ? 'Downloaded $fileName.' : 'Copied the CSV to the clipboard.');
}

/// Opens the print-friendly page (print or save as PDF from the browser).
Future<void> printTables(BuildContext context, {required String title, required String subtitle, required List<ViewTable> tables, required String fileName}) async {
  final html = reportHtml(title: title, subtitle: subtitle, tables: [for (final t in tables) t.table]);
  final opened = await openPrintView(html, fileName: fileName);
  if (context.mounted && !opened) showMessage(context, 'Printing works in the web app. The printable page was copied to the clipboard.');
}

/// The CSV and print buttons.
class ExportButtons extends StatelessWidget {
  const ExportButtons({super.key, required this.onCsv, required this.onPrint});

  final VoidCallback onCsv;
  final VoidCallback onPrint;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(onPressed: onCsv, icon: const Icon(Icons.download, size: 18), label: const Text('CSV')),
        OutlinedButton.icon(onPressed: onPrint, icon: const Icon(Icons.print_outlined, size: 18), label: const Text('Print / PDF')),
      ]);
}
