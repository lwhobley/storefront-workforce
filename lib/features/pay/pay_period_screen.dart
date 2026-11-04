import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/download.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/pay_data.dart';
import 'pay_logic.dart';
import 'pay_providers.dart';

/// One pay period. Open: review calculated pay, fix time, approve. Approved: the Paycom
/// entry sheet, downloads, and the export history.
class PayPeriodScreen extends ConsumerWidget {
  const PayPeriodScreen({super.key, required this.periodId});

  final String periodId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setupAsync = ref.watch(paySetupProvider);
    final dataAsync = ref.watch(periodDataProvider(periodId));
    final venue = ref.watch(venueProvider).value;
    return Scaffold(
      body: SafeArea(
        child: switch ((setupAsync, dataAsync, venue)) {
          (AsyncData(value: final setup), AsyncData(value: final data), final VenueContext venue) =>
            _PeriodBody(setup: setup, data: data, venue: venue),
          (AsyncError(:final error), _, _) || (_, AsyncError(:final error), _) =>
            ErrorNote(error, onRetry: () => ref.invalidate(periodDataProvider(periodId))),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

class _PeriodBody extends ConsumerStatefulWidget {
  const _PeriodBody({required this.setup, required this.data, required this.venue});

  final PaySetup setup;
  final PeriodData data;
  final VenueContext venue;

  @override
  ConsumerState<_PeriodBody> createState() => _PeriodBodyState();
}

class _PeriodBodyState extends ConsumerState<_PeriodBody> {
  EntrySheetSort _sort = EntrySheetSort.lastName;
  EntrySheetMode _mode = EntrySheetMode.periodTotals;
  bool _busy = false;

  PayPeriod get _period => widget.data.period;

  void _reload() {
    ref.invalidate(paySetupProvider);
    ref.invalidate(periodDataProvider(_period.id!));
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) showMessage(context, done);
      _reload();
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve(EarningsResult result) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Approve this pay period?'),
        content: Text(
          '${result.workers.where((w) => w.lines.isNotEmpty).length} people, ${money(result.totalCents)} including tips. '
          'Approving locks these hours and amounts for the Paycom entry sheet. '
          'A later change needs the period reopened, with a reason.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Approve')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => ref.read(repositoryProvider).approvePayPeriod(_period, result.lines, widget.setup.rulesVersion), 'Pay period approved');
  }

  Future<void> _reopen() async {
    final reason = await askReason(context,
        title: 'Reopen this pay period?',
        message: 'The approved lines are removed and the entry sheet must be redone. Anything already keyed into Paycom must be corrected there too.',
        action: 'Reopen',
        suggestions: const ['Late time correction', 'Wrong pay rate', 'Missing tips']);
    if (reason == null) return;
    await _run(() => ref.read(repositoryProvider).reopenPayPeriod(_period, reason), 'Pay period reopened');
  }

  Future<void> _download({required bool importStyle}) async {
    final exporter = const PaycomExporter();
    final csv = exporter.csv(
      period: _period,
      lines: widget.data.approvedLines,
      workers: widget.data.workers,
      payCodes: widget.setup.payCodes,
      storefronts: {for (final s in widget.venue.storefronts) s.id: s},
      options: CsvOptions(style: importStyle ? CsvStyle.lines : CsvStyle.workers, sort: _sort),
    );
    final name = 'paycom-${importStyle ? 'import' : 'entry'}-${formatDate(_period.startsOn)}_${formatDate(_period.endsOn)}.csv';
    final downloaded = await saveTextFile(name, csv.text);
    final sha = sha256.convert(utf8.encode(csv.text)).toString();
    await _run(
      () => ref.read(repositoryProvider).recordExport(
            _period,
            format: importStyle ? 'import_csv' : 'entry_sheet_csv',
            fileName: name,
            rows: csv.rowCount,
            hours: formatHundredths(csv.workedHoursHundredths),
            amount: formatCents(csv.totalAmountCents),
            sha256: sha,
          ),
      downloaded ? 'Downloaded $name' : 'Copied to the clipboard ($name)',
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider)!;
    final d = widget.data;
    final status = _period.status;
    final tone = switch (status) { 'approved' => Tone.good, 'exported' => Tone.info, _ => Tone.warn };
    final statusLabel = switch (status) { 'approved' => 'Approved', 'exported' => 'Exported', _ => 'Open' };

    return ListView(
      padding: const EdgeInsets.only(bottom: 48),
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, top: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: () => context.go('/pay'), icon: const Icon(Icons.arrow_back), label: const Text('Pay')),
          ),
        ),
        ScreenHeader(
          kicker: 'Pay period',
          title: periodLabel(_period),
          subtitle: 'Payday ${DateFormat('EEEE, MMMM d').format(_period.payDate)}',
          actions: [StatusTag(statusLabel, tone)],
        ),
        if (d.isOpen) ..._openView(session) else ..._approvedView(session),
      ],
    );
  }

  // ---------------------------------------------------------------- open period

  List<Widget> _openView(AppSession session) {
    final d = widget.data;
    final result = computeEarnings(d, widget.setup, widget.venue);
    // The data reaches a week past each end of the period (for overtime); only problems
    // with work inside the period, or with no date, belong to this period.
    bool inPeriod(PayProblem p) =>
        p.workDate == null || (!p.workDate!.isBefore(d.period.startsOn) && !p.workDate!.isAfter(d.period.endsOn));
    final blocking = [for (final p in result.problems) if (p.isBlocking && inPeriod(p)) p];
    final warnings = [for (final p in result.problems) if (!p.isBlocking && inPeriod(p)) p];
    final paid = [for (final w in result.workers) if (w.lines.isNotEmpty) w];
    final pending = d.pendingCorrections;
    final unsplit = unsplitPools(d, widget.venue.venue.timeZone);
    final regular = result.workers.fold(0, (s, w) => s + w.regularHoursHundredths);
    final overtime = result.workers.fold(0, (s, w) => s + w.overtimeHoursHundredths);
    final tips = result.workers.fold(0, (s, w) => s + w.tipsCents);
    final canApprove = session.canVenueWide('approve_time');
    final names = d.workers;

    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
        child: Wrap(spacing: 10, runSpacing: 10, children: [
          for (final t in [
            StatTile(label: 'People paid', value: '${paid.length}', detail: '${result.excludedWorkerIds.length} temps/NPO billed separately'),
            StatTile(label: 'Regular hours', value: hours(regular)),
            StatTile(label: 'Overtime hours', value: hours(overtime), tone: overtime > 0 ? Tone.warn : null),
            StatTile(label: 'Wages', value: money(result.totalCents - tips)),
            StatTile(label: 'Tips', value: money(tips)),
          ])
            SizedBox(width: 196, child: t),
        ]),
      ),
      const SizedBox(height: AppSpace.l),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
        child: Row(children: [
          Expanded(
            child: Text(
              unsplit.isNotEmpty
                  ? 'Split the tip pools first, so tips are paid this payday.'
                  : blocking.isNotEmpty
                  ? 'Fix the ${blocking.length} problem${blocking.length == 1 ? '' : 's'} below before approving.'
                  : pending.isNotEmpty
                      ? 'Decide the ${pending.length} pending time correction${pending.length == 1 ? '' : 's'} first.'
                      : 'Ready to approve.',
              style: AppText.body.copyWith(fontWeight: FontWeight.w600, color: blocking.isEmpty && pending.isEmpty && unsplit.isEmpty ? AppColors.good : AppColors.bad),
            ),
          ),
          if (canApprove)
            FilledButton.icon(
              onPressed: _busy || blocking.isNotEmpty || pending.isNotEmpty || unsplit.isNotEmpty ? null : () => _approve(result),
              icon: const Icon(Icons.lock_outline),
              label: const Text('Approve period'),
            ),
        ]),
      ),
      if (blocking.isNotEmpty || warnings.isNotEmpty || unsplit.isNotEmpty) ...[
        const SectionHeading('Problems'),
        for (final p in [...blocking, ...warnings])
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
            leading: Icon(p.isBlocking ? Icons.error_outline : Icons.info_outline, color: p.isBlocking ? AppColors.bad : AppColors.warn),
            title: Text(p.message),
            subtitle: p.workerId == null ? null : Text(names[p.workerId]?.displayName ?? ''),
            trailing: p.workerId == null || !session.canVenueWide('edit_time')
                ? null
                : TextButton(onPressed: () => _fixTime(p.workerId!), child: const Text('Fix time')),
          ),
        if (unsplit.isNotEmpty)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
            leading: const Icon(Icons.info_outline, color: AppColors.warn),
            title: Text('${unsplit.length} tip pool${unsplit.length == 1 ? '' : 's'} not split yet (${money(unsplit.fold(0, (s, t) => s + t.amountCents))}).'),
            subtitle: const Text('Split them under Pay → Tips so they reach the right people.'),
          ),
      ],
      if (d.corrections.isNotEmpty) ...[
        SectionHeading('Time corrections (${pending.length} pending)'),
        for (final c in d.corrections.take(20)) _correctionTile(c, session),
      ],
      SectionHeading('People (${paid.length})'),
      for (final w in [...paid]..sort((a, b) => (names[a.workerId]?.lastName ?? '').compareTo(names[b.workerId]?.lastName ?? '')))
        ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
          title: Text(names[w.workerId]?.displayName ?? w.workerId),
          subtitle: Text('${hours(w.regularHoursHundredths)} reg · ${hours(w.overtimeHoursHundredths)} OT'
              '${w.tipsCents > 0 ? ' · ${money(w.tipsCents)} tips' : ''}'
              '${w.problems.any((p) => p.isBlocking) ? ' · needs attention' : ''}'),
          trailing: Text(money(w.grossCents), style: const TextStyle(fontWeight: FontWeight.w700)),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: [
            for (final l in w.lines)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen * 1.5),
                title: Text('${DateFormat('EEE MMM d').format(l.workDate)} · ${l.payCode}'
                    '${l.jobRoleCode == null ? '' : ' · ${widget.venue.roleName(l.jobRoleCode!)}'}'),
                subtitle: Text([
                  if (l.hoursHundredths > 0) '${hours(l.hoursHundredths)} h',
                  if (l.rateE4 != null) '@ \$${formatE4(l.rateE4!)}',
                  if (l.roundingAdjustmentCents != 0) 'includes ${l.roundingAdjustmentCents}¢ rounding',
                ].join(' ')),
                trailing: Text(money(l.amountCents)),
              ),
            if (session.canVenueWide('edit_time'))
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: AppSpace.screen),
                  child: TextButton.icon(onPressed: () => _fixTime(w.workerId), icon: const Icon(Icons.edit_calendar), label: const Text('Fix time')),
                ),
              ),
          ],
        ),
    ];
  }

  Widget _correctionTile(TimeCorrection c, AppSession session) {
    final name = widget.data.workers[c.workerId]?.displayName ?? '';
    final zone = widget.venue.venue.timeZone;
    final when = c.newOccurredAt == null ? '' : DateFormat('EEE MMM d h:mm a').format(atVenue(c.newOccurredAt!, zone));
    final what = switch (c.action) {
      'add' => 'Add ${(c.newKind ?? '').replaceAll('_', ' ')} at $when',
      'void' => 'Remove a punch',
      _ => 'Change a punch to $when',
    };
    final mine = c.requestedBy == session.userId;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
      title: Text('$name: $what'),
      subtitle: Text('Reason: ${c.reason}${c.status != 'pending' ? ' · ${c.status}' : mine ? ' · waiting for another manager' : ''}'),
      trailing: c.status != 'pending' || mine || !session.canVenueWide('approve_time')
          ? StatusTag(c.status, c.status == 'approved' ? Tone.good : c.status == 'rejected' ? Tone.idle : Tone.warn)
          : Wrap(spacing: 4, children: [
              TextButton(
                  onPressed: _busy ? null : () => _run(() => ref.read(repositoryProvider).decideCorrection(c.id, approve: false), 'Rejected'),
                  child: const Text('Reject')),
              FilledButton.tonal(
                  onPressed: _busy ? null : () => _run(() => ref.read(repositoryProvider).decideCorrection(c.id, approve: true), 'Approved'),
                  child: const Text('Approve')),
            ]),
    );
  }

  Future<void> _fixTime(String workerId) async {
    final d = widget.data;
    final zone = widget.venue.venue.timeZone;
    final worker = d.workers[workerId];
    final start = startOfLocalDay(d.period.startsOn, zone);
    final end = startOfLocalDay(addCalendarDays(d.period.endsOn, 1), zone);
    final punches = [
      for (final p in d.punches)
        if (p.workerId == workerId && p.status != PunchStatus.voided && !p.occurredAt.isBefore(start) && p.occurredAt.isBefore(end)) p,
    ]..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
    final request = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _CorrectionDialog(workerName: worker?.displayName ?? '', workerId: workerId, punches: punches, zone: zone, events: d.events),
    );
    if (request == null) return;
    await _run(() => ref.read(repositoryProvider).requestCorrection(request), 'Correction sent for approval');
  }

  // ------------------------------------------------------------- approved period

  List<Widget> _approvedView(AppSession session) {
    final d = widget.data;
    final sheet = const PaycomExporter().entrySheet(
      period: _period,
      lines: d.approvedLines,
      workers: d.workers,
      payCodes: widget.setup.payCodes,
      options: EntrySheetOptions(sort: _sort, mode: _mode),
    );
    final canExport = session.canVenueWide('export_payroll');
    final entered = d.enteredWorkerIds;
    final people = {for (final r in sheet.rows) ?r.workerId};
    final t = sheet.totals;

    return [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
        child: Text(
          'Key these into Paycom. Tick each person as you go; ${entered.intersection(people).length} of ${people.length} entered. '
          'Overtime: enter the amount shown, not hours times Paycom\'s rate, because it includes the blended rate for people who worked more than one role.',
          style: AppText.body,
        ),
      ),
      const SizedBox(height: AppSpace.m),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
        child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SegmentedButton<EntrySheetSort>(
            segments: const [ButtonSegment(value: EntrySheetSort.lastName, label: Text('Last name')), ButtonSegment(value: EntrySheetSort.employeeCode, label: Text('Employee code'))],
            selected: {_sort},
            onSelectionChanged: (v) => setState(() => _sort = v.first),
          ),
          SegmentedButton<EntrySheetMode>(
            segments: const [ButtonSegment(value: EntrySheetMode.periodTotals, label: Text('Period totals')), ButtonSegment(value: EntrySheetMode.daily, label: Text('By day'))],
            selected: {_mode},
            onSelectionChanged: (v) => setState(() => _mode = v.first),
          ),
          if (canExport) ...[
            OutlinedButton.icon(onPressed: _busy ? null : () => _download(importStyle: false), icon: const Icon(Icons.download), label: const Text('Entry sheet CSV')),
            OutlinedButton.icon(onPressed: _busy ? null : () => _download(importStyle: true), icon: const Icon(Icons.download), label: const Text('Import CSV')),
          ],
          if (session.canVenueWide('approve_time'))
            TextButton.icon(onPressed: _busy ? null : _reopen, icon: const Icon(Icons.lock_open), label: const Text('Reopen')),
        ]),
      ),
      if (sheet.missingPaycomCode.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, 0),
          child: Text('${sheet.missingPaycomCode.length} people have no Paycom employee code. Add it on their staff record.',
              style: AppText.body.copyWith(color: AppColors.bad)),
        ),
      const SizedBox(height: AppSpace.m),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
        child: DataTable(
          headingTextStyle: AppText.meta.copyWith(fontWeight: FontWeight.w700, color: AppColors.text),
          columnSpacing: 22,
          columns: [
            const DataColumn(label: Text('Entered')),
            const DataColumn(label: Text('Code')),
            const DataColumn(label: Text('Name')),
            if (_mode == EntrySheetMode.daily) const DataColumn(label: Text('Date')),
            const DataColumn(label: Text('Reg hrs'), numeric: true),
            const DataColumn(label: Text('OT hrs'), numeric: true),
            const DataColumn(label: Text('OT amount'), numeric: true),
            for (final c in sheet.columns) DataColumn(label: Text(c.paycomCode), numeric: true),
            const DataColumn(label: Text('Bonus'), numeric: true),
            const DataColumn(label: Text('Tips'), numeric: true),
            const DataColumn(label: Text('Gross'), numeric: true),
          ],
          rows: [
            for (final r in sheet.rows)
              DataRow(
                selected: entered.contains(r.workerId),
                cells: [
                  DataCell(Checkbox(
                    value: entered.contains(r.workerId),
                    onChanged: !canExport || r.workerId == null
                        ? null
                        : (v) => _run(() => ref.read(repositoryProvider).setEntered(_period, r.workerId!, v ?? false), v == true ? 'Marked entered' : 'Unmarked'),
                  )),
                  DataCell(Text(r.missingEmployeeCode ? 'MISSING' : r.employeeCode,
                      style: TextStyle(fontWeight: FontWeight.w700, color: r.missingEmployeeCode ? AppColors.bad : null))),
                  DataCell(Text('${r.lastName}, ${r.firstName}')),
                  if (_mode == EntrySheetMode.daily) DataCell(Text(r.workDate == null ? '' : DateFormat('EEE MMM d').format(r.workDate!))),
                  DataCell(Text(hours(r.regularHundredths))),
                  DataCell(Text(hours(r.overtimeHundredths))),
                  DataCell(Text(r.overtimeCents == 0 ? '' : money(r.overtimeCents))),
                  for (final c in sheet.columns) DataCell(Text(_codeCell(r.codes[c.code]))),
                  DataCell(Text(r.bonusCents == 0 ? '' : money(r.bonusCents))),
                  DataCell(Text(r.tipsCents == 0 ? '' : money(r.tipsCents))),
                  DataCell(Text(money(r.grossCents))),
                ],
              ),
            DataRow(
              color: WidgetStatePropertyAll(AppColors.ink(0.05)),
              cells: [
                const DataCell(Text('')),
                const DataCell(Text('')),
                const DataCell(Text('Totals', style: TextStyle(fontWeight: FontWeight.w800))),
                if (_mode == EntrySheetMode.daily) const DataCell(Text('')),
                DataCell(Text(hours(t.regularHundredths), style: const TextStyle(fontWeight: FontWeight.w800))),
                DataCell(Text(hours(t.overtimeHundredths), style: const TextStyle(fontWeight: FontWeight.w800))),
                DataCell(Text(money(t.overtimeCents), style: const TextStyle(fontWeight: FontWeight.w800))),
                for (final c in sheet.columns) DataCell(Text(_codeCell(t.codes[c.code]), style: const TextStyle(fontWeight: FontWeight.w800))),
                DataCell(Text(money(t.bonusCents), style: const TextStyle(fontWeight: FontWeight.w800))),
                DataCell(Text(money(t.tipsCents), style: const TextStyle(fontWeight: FontWeight.w800))),
                DataCell(Text(money(t.grossCents), style: const TextStyle(fontWeight: FontWeight.w800))),
              ],
            ),
          ],
        ),
      ),
      if (d.exports.isNotEmpty) ...[
        const SectionHeading('Export history'),
        for (final e in d.exports)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
            leading: const Icon(Icons.description_outlined),
            title: Text(e.fileName),
            subtitle: Text('${e.rowCount} rows · ${DateFormat('MMM d, h:mm a').format(e.createdAt.toLocal())}'
                '${e.createdByName.isEmpty ? '' : ' · ${e.createdByName}'}'),
          ),
      ],
    ];
  }

  String _codeCell(({int hundredths, int cents})? v) {
    if (v == null || (v.hundredths == 0 && v.cents == 0)) return '';
    return v.hundredths > 0 ? '${hours(v.hundredths)} h · ${money(v.cents)}' : money(v.cents);
  }
}

/// Proposes a fix to one person's time: change a punch, remove one, or add a missing one.
class _CorrectionDialog extends StatefulWidget {
  const _CorrectionDialog({required this.workerName, required this.workerId, required this.punches, required this.zone, required this.events});

  final String workerName;
  final String workerId;
  final List<Punch> punches;
  final String zone;
  final Map<String, Event> events;

  @override
  State<_CorrectionDialog> createState() => _CorrectionDialogState();
}

class _CorrectionDialogState extends State<_CorrectionDialog> {
  String _action = 'replace';
  Punch? _punch;
  PunchKind _kind = PunchKind.clockOut;
  DateTime? _when;
  final _reason = TextEditingController();

  String _label(Punch p) =>
      '${DateFormat('EEE MMM d h:mm a').format(atVenue(p.occurredAt, widget.zone))} · ${p.kind.code.replaceAll('_', ' ')}';

  Future<void> _pickTime() async {
    final base = atVenue(_when ?? _punch?.occurredAt ?? DateTime.now().toUtc(), widget.zone);
    final date = await showDatePicker(context: context, initialDate: base, firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay(hour: base.hour, minute: base.minute));
    if (time == null) return;
    try {
      setState(() => _when = venueWallTimeUtc(DateTime(date.year, date.month, date.day, time.hour, time.minute), widget.zone));
    } on ArgumentError catch (e) {
      if (mounted) showMessage(context, '${e.message}');
    }
  }

  bool get _valid =>
      _reason.text.trim().length >= 3 &&
      switch (_action) {
        'add' => _when != null,
        'void' => _punch != null,
        _ => _punch != null && _when != null,
      };

  @override
  Widget build(BuildContext context) {
    final eventId = _punch?.eventId ?? (widget.punches.isEmpty ? null : widget.punches.last.eventId);
    return AlertDialog(
      title: Text('Fix time for ${widget.workerName}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'replace', label: Text('Change')),
                  ButtonSegment(value: 'add', label: Text('Add missing')),
                  ButtonSegment(value: 'void', label: Text('Remove')),
                ],
                selected: {_action},
                onSelectionChanged: (v) => setState(() => _action = v.first),
              ),
              const SizedBox(height: 12),
              if (_action != 'add')
                DropdownButtonFormField<Punch>(
                  initialValue: _punch,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Punch'),
                  items: [for (final p in widget.punches) DropdownMenuItem(value: p, child: Text(_label(p)))],
                  onChanged: (v) => setState(() => _punch = v),
                ),
              if (_action == 'add')
                DropdownButtonFormField<PunchKind>(
                  initialValue: _kind,
                  decoration: const InputDecoration(labelText: 'Missing punch'),
                  items: [for (final k in PunchKind.values) DropdownMenuItem(value: k, child: Text(k.code.replaceAll('_', ' ')))],
                  onChanged: (v) => setState(() => _kind = v ?? _kind),
                ),
              if (_action != 'void') ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _pickTime,
                  icon: const Icon(Icons.schedule),
                  label: Text(_when == null ? 'Choose the correct time' : DateFormat('EEE MMM d h:mm a').format(atVenue(_when!, widget.zone))),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _reason,
                decoration: const InputDecoration(labelText: 'Reason (required, kept in the record)'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              const Text('Another manager approves it. The original punch is kept, marked as corrected.', style: AppText.meta),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: !_valid
              ? null
              : () => Navigator.pop(context, {
                    'worker_id': widget.workerId,
                    'event_id': eventId,
                    'action': _action,
                    'punch_id': _action == 'add' ? null : _punch!.id,
                    'new_kind': _action == 'add' ? _kind.code : null,
                    'new_break_kind': _action == 'add' && _kind == PunchKind.breakStart ? 'rest' : null,
                    'new_occurred_at': _action == 'void' ? null : _when!.toUtc().toIso8601String(),
                    'reason': _reason.text.trim(),
                  }),
          child: const Text('Send for approval'),
        ),
      ],
    );
  }
}
