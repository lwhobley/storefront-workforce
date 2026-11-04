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

/// Pay: pay periods (approve and enter into Paycom), tips, NPO payouts, agency invoices.
class PayScreen extends ConsumerStatefulWidget {
  const PayScreen({super.key});

  @override
  ConsumerState<PayScreen> createState() => _PayScreenState();
}

class _PayScreenState extends ConsumerState<PayScreen> {
  String? _periodId;

  @override
  Widget build(BuildContext context) {
    final setupAsync = ref.watch(paySetupProvider);
    final venue = ref.watch(venueProvider).value;
    final session = ref.watch(sessionProvider)!;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        body: SafeArea(
          child: setupAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(paySetupProvider)),
            data: (setup) {
              final period = (_periodId == null ? null : findPeriod(setup, _periodId!)) ?? lastClosedPeriod(setup) ?? currentPeriod(setup);
              return NestedScrollView(
                headerSliverBuilder: (context, _) => [
                  SliverToBoxAdapter(child: ScreenHeader(kicker: session.venue.name, title: 'Pay')),
                  const SliverToBoxAdapter(
                    child: TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      padding: EdgeInsets.symmetric(horizontal: AppSpace.m),
                      tabs: [Tab(text: 'Pay periods'), Tab(text: 'Tips'), Tab(text: 'NPO payouts'), Tab(text: 'Agencies')],
                    ),
                  ),
                ],
                body: venue == null || period == null
                    ? const Center(child: CircularProgressIndicator())
                    : TabBarView(children: [
                        _PeriodsTab(setup: setup),
                        _PeriodScoped(setup: setup, period: period, onPeriod: (id) => setState(() => _periodId = id),
                            child: (data) => _TipsTab(setup: setup, period: period, venue: venue)),
                        _PeriodScoped(setup: setup, period: period, onPeriod: (id) => setState(() => _periodId = id),
                            child: (data) => _NpoTab(setup: setup, period: period, venue: venue)),
                        _PeriodScoped(setup: setup, period: period, onPeriod: (id) => setState(() => _periodId = id),
                            child: (data) => _AgencyTab(setup: setup, period: period, venue: venue)),
                      ]),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PeriodsTab extends StatelessWidget {
  const _PeriodsTab({required this.setup});

  final PaySetup setup;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);
    return ListView(
      padding: const EdgeInsets.only(bottom: 48),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.l, AppSpace.screen, AppSpace.s),
          child: Text('Every two weeks. Approve a period after it ends, then key it into Paycom from its entry sheet.', style: AppText.meta),
        ),
        for (final p in setup.periods)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
            title: Text(periodLabel(p)),
            subtitle: Text('Payday ${DateFormat('EEE MMM d').format(p.payDate)}'
                '${!today.isAfter(p.endsOn) && !today.isBefore(p.startsOn) ? ' · current period' : ''}'),
            trailing: StatusTag(
              switch (p.status) {
                'approved' => 'Approved',
                'exported' => 'Exported',
                _ => p.endsOn.isBefore(today) ? 'Ready to review' : p.startsOn.isAfter(today) ? 'Upcoming' : 'In progress',
              },
              switch (p.status) { 'approved' => Tone.good, 'exported' => Tone.info, _ => p.endsOn.isBefore(today) ? Tone.warn : Tone.idle },
            ),
            onTap: () => context.go('/pay/period/${p.id}'),
          ),
      ],
    );
  }
}

/// A pay period picker above a tab that works on one period's dates.
class _PeriodScoped extends StatelessWidget {
  const _PeriodScoped({required this.setup, required this.period, required this.onPeriod, required this.child});

  final PaySetup setup;
  final PayPeriod period;
  final ValueChanged<String> onPeriod;
  final Widget Function(PayPeriod period) child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, 0),
          child: DropdownButtonFormField<String>(
            initialValue: period.id,
            decoration: const InputDecoration(labelText: 'Pay period'),
            items: [for (final p in setup.periods) DropdownMenuItem(value: p.id, child: Text(periodLabel(p)))],
            onChanged: (v) {
              if (v != null) onPeriod(v);
            },
          ),
        ),
        Expanded(child: child(period)),
      ],
    );
  }
}

// ------------------------------------------------------------------------- tips

class _TipsTab extends ConsumerWidget {
  const _TipsTab({required this.setup, required this.period, required this.venue});

  final PaySetup setup;
  final PayPeriod period;
  final VenueContext venue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataAsync = ref.watch(periodDataProvider(period.id!));
    return dataAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorNote(e),
      data: (d) {
        final zone = venue.venue.timeZone;
        final start = startOfLocalDay(period.startsOn, zone);
        final end = startOfLocalDay(addCalendarDays(period.endsOn, 1), zone);
        final events = [for (final e in d.events.values) if (!e.startTime.isBefore(start) && e.startTime.isBefore(end)) e]
          ..sort((a, b) => a.startTime.compareTo(b.startTime));
        final tipped = [for (final s in venue.storefronts) if (s.kind == StorefrontKind.bar && s.active) s];
        if (events.isEmpty) return const EmptyNote('No events in this pay period.');
        final unsplit = unsplitPools(d, zone);
        return ListView(
          padding: const EdgeInsets.only(bottom: 48),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.l, AppSpace.screen, 0),
              child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                const Text('Pooled tips are split by hours worked among eligible roles (leads are left out by default). '
                    'Each split goes on the pay period as TIPS.', style: AppText.meta),
                if (d.isOpen && unsplit.isNotEmpty)
                  FilledButton.tonal(
                    onPressed: () async {
                      try {
                        for (final t in unsplit) {
                          final pool = TipPool.fromJson({...t.toJson(), 'status': 'final'});
                          await ref.read(repositoryProvider).saveTipPool(pool, computeTipSplit(pool, d, venue).allocations);
                        }
                        ref.invalidate(periodDataProvider(period.id!));
                        if (context.mounted) showMessage(context, '${unsplit.length} tip pools split by hours');
                      } on AppFailure catch (e) {
                        if (context.mounted) showMessage(context, e.message);
                      }
                    },
                    child: Text('Split all ${unsplit.length} by hours'),
                  ),
              ]),
            ),
            for (final e in events) ...[
              SectionHeading('${DateFormat('EEE MMM d').format(atVenue(e.startTime, venue.venue.timeZone))} · ${e.name}'),
              for (final s in tipped)
                Builder(builder: (context) {
                  final pool = d.tipPools.where((t) => t.eventId == e.id && t.storefrontId == s.id).firstOrNull;
                  final split = pool != null && d.tipAllocations.any((a) => a.poolId == pool.id);
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                    title: Text(s.name),
                    subtitle: Text(pool == null ? 'No tips entered' : '${money(pool.amountCents)} · split by ${pool.method.replaceAll('_', ' ')}'),
                    trailing: pool == null
                        ? const StatusTag('None', Tone.idle)
                        : StatusTag(split ? 'Split' : 'Not split', split ? Tone.good : Tone.warn),
                    onTap: !d.isOpen
                        ? () => showMessage(context, 'This pay period is approved. Reopen it to change tips.')
                        : () => _editPool(context, ref, d, e, s, pool),
                  );
                }),
            ],
          ],
        );
      },
    );
  }

  Future<void> _editPool(BuildContext context, WidgetRef ref, PeriodData d, Event e, Storefront s, TipPool? existing) async {
    final controller = TextEditingController(text: existing == null ? '' : formatCents(existing.amountCents));
    var method = existing?.method ?? 'hours';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(builder: (context, setState) {
        final cents = parseCents(controller.text.trim().isEmpty ? '0' : controller.text.trim().replaceAll(r'$', ''));
        final pool = TipPool(
          id: existing?.id ?? 'pool-${e.id}-${s.id}',
          venueId: venue.venue.id,
          eventId: e.id,
          storefrontId: s.id,
          amountCents: cents,
          method: method,
          source: existing?.source ?? 'manual',
          status: 'final',
        );
        final result = computeTipSplit(pool, d, venue);
        return FractionallySizedBox(
          heightFactor: 0.8,
          child: ListView(
            padding: const EdgeInsets.all(AppSpace.screen),
            children: [
              Text('Tips · ${s.name}', style: AppText.sectionHeading),
              Text(e.name, style: AppText.meta),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Total pooled tips', prefixText: r'$ '),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'hours', label: Text('By hours')),
                  ButtonSegment(value: 'equal', label: Text('Equal')),
                ],
                selected: {method},
                onSelectionChanged: (v) => setState(() => method = v.first),
              ),
              const SizedBox(height: 12),
              for (final a in result.allocations)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(d.workers[a.workerId]?.displayName ?? a.workerId),
                  subtitle: Text('${hours(a.hoursHundredths)} h'),
                  trailing: Text(money(a.amountCents), style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              for (final x in result.excluded)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(d.workers[x.workerId]?.displayName ?? x.workerId, style: const TextStyle(color: AppColors.muted)),
                  subtitle: Text('Not in the pool: ${switch (x.reason) {
                    TipExclusionReason.roleNotEligible => 'role not eligible',
                    TipExclusionReason.roleNotInPoolPoints => 'role not in this pool',
                    TipExclusionReason.workerTypeNotIncluded => 'temp or NPO member',
                    TipExclusionReason.noPaidTime => 'no time worked',
                    TipExclusionReason.releasedBeforeArrival => 'sent home before arriving',
                  }}'),
                ),
              if (result.allocations.isEmpty) const Text('No one eligible worked here.', style: AppText.meta),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: cents <= 0 || result.allocations.isEmpty
                    ? null
                    : () async {
                        try {
                          await ref.read(repositoryProvider).saveTipPool(pool, result.allocations);
                          ref.invalidate(periodDataProvider(period.id!));
                          if (context.mounted) Navigator.pop(context);
                        } on AppFailure catch (err) {
                          if (context.mounted) showMessage(context, err.message);
                        }
                      },
                child: Text('Save split (${money(result.distributedCents)})'),
              ),
            ],
          ),
        );
      }),
    );
  }
}

// -------------------------------------------------------------------- NPO payouts

class _NpoTab extends ConsumerWidget {
  const _NpoTab({required this.setup, required this.period, required this.venue});

  final PaySetup setup;
  final PayPeriod period;
  final VenueContext venue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataAsync = ref.watch(partnerDataProvider(period.id!));
    final session = ref.watch(sessionProvider)!;
    return dataAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorNote(e),
      data: (d) {
        final zone = venue.venue.timeZone;
        final start = startOfLocalDay(period.startsOn, zone);
        final end = startOfLocalDay(addCalendarDays(period.endsOn, 1), zone);
        final npoIds = {for (final w in d.workers.values) if (w.type == WorkerType.npo) w.id};
        final rows = <(Event, NpoGroup, NpoPayoutResult, NpoPayout?)>[];
        for (final e in d.events.values.where((e) => !e.startTime.isBefore(start) && e.startTime.isBefore(end))) {
          for (final g in venue.npoGroups) {
            final scheduled = d.shifts.any((s) => s.eventId == e.id && npoIds.contains(s.workerId) && d.workers[s.workerId]?.npoGroupId == g.id);
            if (!scheduled) continue;
            final saved = d.payouts.where((p) => p.eventId == e.id && p.npoGroupId == g.id).firstOrNull;
            final calc = computeNpoPayout(d, setup, venue, e, g.id,
                adjustmentCents: saved?.adjustmentCents ?? 0, adjustmentReason: saved?.adjustmentReason ?? '');
            rows.add((e, g, calc, saved));
          }
        }
        rows.sort((a, b) => a.$1.startTime.compareTo(b.$1.startTime));
        final approved = [for (final r in rows) if (r.$4 != null && r.$4!.status != 'pending') r];
        final canApprove = session.canVenueWide('approve_time');

        Future<void> act(Future<void> Function() f, String done) async {
          try {
            await f();
            ref.invalidate(partnerDataProvider(period.id!));
            if (context.mounted) showMessage(context, done);
          } on AppFailure catch (e) {
            if (context.mounted) showMessage(context, e.message);
          }
        }

        return ListView(
          padding: const EdgeInsets.only(bottom: 48),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.l, AppSpace.screen, 0),
              child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('Paid to the nonprofit through accounts payable, not payroll. '
                    '${setup.npoAgreements.isEmpty ? 'No NPO agreement is set up yet.' : 'Standard rate ${money(setup.npoAgreements.first.hourlyRateCents)}/h.'}',
                    style: AppText.meta),
                if (approved.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => _paymentList(context, approved),
                    icon: const Icon(Icons.download),
                    label: const Text('AP payment list'),
                  ),
              ]),
            ),
            if (rows.isEmpty) const EmptyNote('No NPO groups worked in this pay period.'),
            for (final (e, g, calc, saved) in rows)
              Card(
                margin: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, 0),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.l),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(child: Text(g.displayName, style: AppText.sectionHeading)),
                        StatusTag(
                          saved == null ? 'Not saved' : saved.status[0].toUpperCase() + saved.status.substring(1),
                          switch (saved?.status) { 'paid' => Tone.good, 'approved' => Tone.info, 'pending' => Tone.warn, _ => Tone.idle },
                        ),
                      ]),
                      Text('${DateFormat('EEE MMM d').format(atVenue(e.startTime, venue.venue.timeZone))} · ${e.name}', style: AppText.meta),
                      const SizedBox(height: 8),
                      Text(
                        '${calc.payout.membersWorked} of ${calc.payout.membersScheduled} members worked · ${calc.payout.noShows} no-shows · '
                        '${hours(calc.payout.hoursHundredths)} h × ${money(calc.payout.hourlyRateCents)} = ${money(calc.payout.grossCents)}',
                        style: AppText.body,
                      ),
                      if (calc.payout.deductionsCents > 0)
                        Text('Deductions ${money(calc.payout.deductionsCents)}'
                            '${calc.shortfall > 0 ? ' (${calc.shortfall} short of the ${calc.agreement?.minHeadcount}-person minimum)' : ''}',
                            style: AppText.body.copyWith(color: AppColors.bad)),
                      if (calc.payout.adjustmentCents != 0)
                        Text('Adjustment ${money(calc.payout.adjustmentCents)}: ${calc.payout.adjustmentReason}', style: AppText.body),
                      const SizedBox(height: 4),
                      Text('Total ${money(calc.payout.totalCents)}', style: AppText.sectionHeading),
                      if (saved != null && saved.status != 'pending' && saved.totalCents != calc.payout.totalCents)
                        Text('Approved at ${money(saved.totalCents)}; time records have changed since.', style: AppText.meta.copyWith(color: AppColors.warn)),
                      if (canApprove) ...[
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, children: [
                          if (saved == null || saved.status == 'pending')
                            OutlinedButton(onPressed: () => act(() => ref.read(repositoryProvider).saveNpoPayout(calc.payout), 'Saved'), child: const Text('Save')),
                          if (saved == null || saved.status == 'pending')
                            TextButton(onPressed: () => _adjust(context, ref, d, e, g, saved), child: const Text('Adjust')),
                          if (saved != null && saved.status == 'pending')
                            FilledButton(onPressed: () => act(() => ref.read(repositoryProvider).setNpoPayoutStatus(saved.id!, 'approved'), 'Approved'), child: const Text('Approve')),
                          if (saved != null && saved.status == 'approved')
                            FilledButton(
                              onPressed: () async {
                                final ref0 = await askReason(context, title: 'Mark paid', hint: 'Check or ACH number', action: 'Mark paid');
                                if (ref0 == null) return;
                                await act(() => ref.read(repositoryProvider).setNpoPayoutStatus(saved.id!, 'paid', reference: ref0), 'Marked paid');
                              },
                              child: const Text('Mark paid'),
                            ),
                        ]),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _adjust(BuildContext context, WidgetRef ref, PartnerData d, Event e, NpoGroup g, NpoPayout? saved) async {
    final amount = TextEditingController(text: saved == null ? '' : formatCents(saved.adjustmentCents));
    final reason = TextEditingController(text: saved?.adjustmentReason ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Adjust ${g.displayName}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: amount, decoration: const InputDecoration(labelText: 'Adjustment (use - to reduce)', prefixText: r'$ ')),
          const SizedBox(height: 8),
          TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason (required)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final calc = computeNpoPayout(d, setup, venue, e, g.id,
          adjustmentCents: parseCents(amount.text.trim().isEmpty ? '0' : amount.text.trim()), adjustmentReason: reason.text.trim());
      await ref.read(repositoryProvider).saveNpoPayout(calc.payout);
      ref.invalidate(partnerDataProvider(period.id!));
    } on AppFailure catch (err) {
      if (context.mounted) showMessage(context, err.message);
    } on ArgumentError catch (err) {
      if (context.mounted) showMessage(context, '${err.message}');
    }
  }

  Future<void> _paymentList(BuildContext context, List<(Event, NpoGroup, NpoPayoutResult, NpoPayout?)> rows) async {
    final buf = StringBuffer('Payee,Event,Event date,Hours,Amount,Status,Reference\r\n');
    for (final (e, g, _, p) in rows) {
      buf.write('${csvEscape(g.legalName)},${csvEscape(e.name)},${formatDate(localDateOf(e.startTime, venue.venue.timeZone))},'
          '${formatHundredths(p!.hoursHundredths)},${formatCents(p.totalCents)},${p.status},${csvEscape(p.paymentReference)}\r\n');
    }
    final name = 'npo-payments-${formatDate(period.startsOn)}_${formatDate(period.endsOn)}.csv';
    final downloaded = await saveTextFile(name, buf.toString());
    if (context.mounted) showMessage(context, downloaded ? 'Downloaded $name' : 'Copied to the clipboard');
  }
}

// ---------------------------------------------------------------------- agencies

class _AgencyTab extends ConsumerWidget {
  const _AgencyTab({required this.setup, required this.period, required this.venue});

  final PaySetup setup;
  final PayPeriod period;
  final VenueContext venue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataAsync = ref.watch(partnerDataProvider(period.id!));
    return dataAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorNote(e),
      data: (d) {
        final billing = computeAgencyBilling(d, setup, venue, period.startsOn, period.endsOn);
        return ListView(
          padding: const EdgeInsets.only(bottom: 48),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.l, AppSpace.screen, 0),
              child: Text('Temps are paid by their agency. These are the hours to bill at each agency\'s rates, '
                  'with overtime billed past 40 hours in a week at this venue.', style: AppText.meta),
            ),
            for (final p in billing.problems)
              ListTile(dense: true, leading: const Icon(Icons.info_outline, color: AppColors.warn), title: Text(p.message)),
            if (billing.invoices.isEmpty) const EmptyNote('No temp hours in this pay period.'),
            for (final inv in billing.invoices) ...[
              SectionHeading(
                venue.agencyName(inv.agencyId),
                trailing: TextButton.icon(
                  onPressed: () => _download(context, d, inv),
                  icon: const Icon(Icons.download),
                  label: Text(money(inv.lines.fold(0, (s, l) => s + l.regularAmountCents + l.overtimeAmountCents))),
                ),
              ),
              for (final l in inv.lines)
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                  title: Text('${d.workers[l.workerId]?.displayName ?? ''} · ${venue.roleName(l.jobRoleCode ?? '')}'),
                  subtitle: Text('${DateFormat('EEE MMM d').format(l.firstWorkDate)} · ${d.events[l.eventId]?.name ?? ''}\n'
                      '${hours(minutesToHundredths(l.regularMinutes))} h × ${l.billRateCents == null ? 'no rate' : money(l.billRateCents!)}'
                      '${l.overtimeMinutes > 0 ? ' + ${hours(minutesToHundredths(l.overtimeMinutes))} OT h × ${money(l.overtimeBillRateCents ?? 0)}' : ''}'),
                  isThreeLine: true,
                  trailing: Text(money(l.regularAmountCents + l.overtimeAmountCents)),
                ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _download(BuildContext context, PartnerData d, AgencyInvoice inv) async {
    final buf = StringBuffer('Worker,Employee Number,Date,Event,Role,Regular Hours,Bill Rate,Overtime Hours,Overtime Bill Rate,Amount\r\n');
    for (final l in inv.lines) {
      final w = d.workers[l.workerId];
      buf.write('${csvEscape(w?.displayName ?? '')},${w?.employeeNumber ?? ''},${formatDate(l.firstWorkDate)},'
          '${csvEscape(d.events[l.eventId]?.name ?? '')},${venue.roleName(l.jobRoleCode ?? '')},'
          '${formatHundredths(minutesToHundredths(l.regularMinutes))},${l.billRateCents == null ? '' : formatCents(l.billRateCents!)},'
          '${formatHundredths(minutesToHundredths(l.overtimeMinutes))},${l.overtimeBillRateCents == null ? '' : formatCents(l.overtimeBillRateCents!)},'
          '${formatCents(l.regularAmountCents + l.overtimeAmountCents)}\r\n');
    }
    final name = '${venue.agencyName(inv.agencyId).replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').toLowerCase()}-${formatDate(period.startsOn)}_${formatDate(period.endsOn)}.csv';
    final downloaded = await saveTextFile(name, buf.toString());
    if (context.mounted) showMessage(context, downloaded ? 'Downloaded $name' : 'Copied to the clipboard');
  }
}
