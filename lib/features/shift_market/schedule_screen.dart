import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/shift_market_repository.dart';
import 'market_providers.dart';
import 'market_widgets.dart';
import 'shift_strings.dart';

/// The employee's schedule: their shifts (drop or give away), open shifts to pick up,
/// requests and offers, and which events they can work. English and Spanish.
class ScheduleScreen extends ConsumerWidget {
  const ScheduleScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final session = ref.watch(sessionProvider)!;
    final requests = ref.watch(myRequestsProvider).value ?? const <ShiftRequest>[];
    final offers = requests.where((r) => r.status == ShiftRequestStatus.offered && r.targetWorkerId == session.workerId).length;

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ScreenHeader(
                kicker: session.venue.name,
                title: t.schedule,
                actions: [TextButton(onPressed: () => ref.read(languageProvider.notifier).toggle(), child: Text(t.language))],
              ),
              TabBar(
                labelPadding: const EdgeInsets.symmetric(horizontal: 2),
                labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                unselectedLabelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                tabs: [
                  Tab(height: 64, icon: const Icon(Icons.event_note_outlined), text: t.myShifts),
                  Tab(height: 64, icon: const Icon(Icons.add_task), text: t.tabOpen),
                  Tab(
                    height: 64,
                    icon: Badge(isLabelVisible: offers > 0, label: Text('$offers'), child: const Icon(Icons.swap_horiz)),
                    text: t.requests,
                  ),
                  Tab(height: 64, icon: const Icon(Icons.event_available_outlined), text: t.tabAvailability),
                ],
              ),
              const Divider(height: 1),
              Expanded(
                child: session.workerId == null
                    ? EmptyNote(t.noUpcoming)
                    : const TabBarView(children: [_MyShiftsTab(), _OpenShiftsTab(), _RequestsTab(), _AvailabilityTab()]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Runs an action, shows the result, and reloads the schedule.
Future<bool> _run(BuildContext context, WidgetRef ref, Future<String> Function(ShiftMarketRepository repo) action) async {
  try {
    final message = await action(ref.read(repositoryProvider) as ShiftMarketRepository);
    if (context.mounted) showMessage(context, message);
    return true;
  } on AppFailure catch (e) {
    if (context.mounted) showMessage(context, e.message);
    return false;
  } finally {
    refreshMarket(ref);
  }
}

Future<void> _refresh(WidgetRef ref) async {
  refreshMarket(ref);
  await Future.wait([ref.read(myRequestsProvider.future), ref.read(openShiftsProvider.future)]).catchError((_) => const <List<Object>>[]);
}

// ---------------------------------------------------------------------------
// My shifts
// ---------------------------------------------------------------------------

class _MyShiftsTab extends ConsumerWidget {
  const _MyShiftsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final session = ref.watch(sessionProvider)!;
    final dayAsync = ref.watch(myDayProvider);
    final requests = ref.watch(myRequestsProvider).value ?? const <ShiftRequest>[];
    final now = ref.watch(clockProvider).value ?? DateTime.now().toUtc();
    final zone = session.venue.timeZone;
    final cfg = SelfServiceSettings.fromVenueSettings(session.venue.settings);

    return RefreshIndicator(
      onRefresh: () => _refresh(ref),
      child: dayAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ListView(children: [ErrorNote(e, onRetry: () => ref.invalidate(myDayProvider))]),
        data: (day) {
          if (day.shifts.isEmpty) return ListView(children: [EmptyNote(t.noUpcoming)]);
          return MarketList(children: [
            for (final s in day.shifts)
              Builder(builder: (context) {
                final open = requests
                    .where((r) => r.shift.id == s.shift.id && r.status.isOpen && r.requesterWorkerId == session.workerId)
                    .firstOrNull;
                final started = !s.shift.callTime.isAfter(now) || day.punches.any((p) => p.eventId == s.event.id);
                final canAct = !started && s.shift.status == ShiftStatus.assigned;
                final dropOpen = now.isBefore(cfg.dropDeadline(s.shift.callTime));
                return ShiftCard(
                  t: t,
                  zone: zone,
                  callTime: s.shift.callTime,
                  storefront: s.storefront?.name ?? '',
                  role: s.roleName,
                  eventName: s.event.name,
                  detail: [if (s.stationName.isNotEmpty) s.stationName, if ((s.storefront?.section ?? '').isNotEmpty) 'Sec ${s.storefront!.section}'].join(' · '),
                  tags: [
                    if (started && s.shift.status == ShiftStatus.assigned) StatusTag(t.inProgress, Tone.good),
                    if (s.shift.status == ShiftStatus.released) StatusTag(t.sentHome, Tone.idle),
                  ],
                  children: [
                    if (open != null) ...[
                      StatusLine(
                        icon: Icons.hourglass_top,
                        tone: Tone.warn,
                        text: switch (open.kind) {
                          ShiftRequestKind.drop => t.dropRequested,
                          ShiftRequestKind.swap when open.status == ShiftRequestStatus.offered => t.offeredTo(open.targetName),
                          _ => t.swapWaiting(open.targetName),
                        },
                      ),
                      const SizedBox(height: AppSpace.s),
                      BigButton.outlined(
                        label: t.cancelRequest,
                        icon: Icons.undo,
                        onPressed: () => _run(context, ref, (repo) async {
                          await repo.cancelShiftRequest(open.id);
                          return t.cancelled;
                        }),
                      ),
                    ] else if (canAct) ...[
                      if (cfg.allowDrops && !dropOpen) StatusLine(icon: Icons.lock_clock, tone: Tone.idle, text: t.dropClosed(cfg.dropCutoffHours)),
                      if ((cfg.allowDrops && dropOpen) || cfg.allowSwaps) ...[
                        const SizedBox(height: AppSpace.s),
                        ButtonPair(
                          left: cfg.allowDrops && dropOpen
                              ? BigButton.outlined(label: t.drop, icon: Icons.event_busy, onPressed: () => _drop(context, ref, s))
                              : null,
                          right: cfg.allowSwaps
                              ? BigButton.outlined(label: t.giveToCoworker, icon: Icons.swap_horiz, onPressed: () => _give(context, ref, s))
                              : null,
                        ),
                      ],
                    ],
                  ],
                );
              }),
          ]);
        },
      ),
    );
  }

  Future<void> _drop(BuildContext context, WidgetRef ref, MyShift s) async {
    final t = ref.read(stringsProvider);
    final reason = await askText(
      context,
      t: t,
      title: t.dropTitle,
      message: t.dropHelp,
      hint: t.whyHint,
      action: t.sendRequest,
      suggestions: t.dropReasons,
      required: true,
    );
    if (reason == null || !context.mounted) return;
    await _run(context, ref, (repo) async {
      await repo.requestDrop(s.shift.id, reason: reason);
      return t.requestSent;
    });
  }

  Future<void> _give(BuildContext context, WidgetRef ref, MyShift s) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: _GiveSheet(shift: s)),
    );
  }
}

class _GiveSheet extends ConsumerStatefulWidget {
  const _GiveSheet({required this.shift});

  final MyShift shift;

  @override
  ConsumerState<_GiveSheet> createState() => _GiveSheetState();
}

class _GiveSheetState extends ConsumerState<_GiveSheet> {
  late final Future<List<SwapCandidate>> _people = (ref.read(repositoryProvider) as ShiftMarketRepository).swapCandidates(widget.shift.shift.id);
  String _query = '';

  Future<void> _offer(SwapCandidate c) async {
    final t = ref.read(stringsProvider);
    final note = await askText(context, t: t, title: t.offerTitle(c.name), message: t.giveHelp, hint: t.noteOptional, action: t.offer);
    if (note == null || !mounted) return;
    final ok = await _run(context, ref, (repo) async {
      await repo.offerSwap(widget.shift.shift.id, c.id, note: note);
      return t.offerSent(c.name);
    });
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final s = widget.shift;
    final zone = ref.watch(sessionProvider)!.venue.timeZone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.giveTitle, style: AppText.sectionHeading),
            const SizedBox(height: 4),
            Text('${s.storefront?.name ?? ''} · ${s.roleName} · ${t.day(s.shift.callTime, zone)} ${t.clock(s.shift.callTime, zone)}', style: AppText.body),
            Text(t.giveHelp, style: AppText.meta),
            const SizedBox(height: AppSpace.m),
            TextField(
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: t.searchName),
              onChanged: (v) => setState(() => _query = v.toLowerCase().trim()),
            ),
          ]),
        ),
        const SizedBox(height: AppSpace.s),
        Expanded(
          child: FutureBuilder<List<SwapCandidate>>(
            future: _people,
            builder: (context, snap) {
              if (snap.hasError) return ErrorNote(snap.error!);
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final people = [for (final c in snap.data!) if (_query.isEmpty || c.name.toLowerCase().contains(_query)) c]
                ..sort((a, b) {
                  int rank(SwapCandidate c) => switch (c.availability) {
                        AvailabilityStatus.available => 0,
                        null => 1,
                        AvailabilityStatus.unavailable => 2,
                      };
                  final r = rank(a).compareTo(rank(b));
                  return r != 0 ? r : a.name.compareTo(b.name);
                });
              if (people.isEmpty) return EmptyNote(t.noCoworkers);
              return ListView.separated(
                itemCount: people.length,
                separatorBuilder: (_, _) => const Divider(height: 1, indent: AppSpace.screen),
                itemBuilder: (context, i) {
                  final c = people[i];
                  return ListTile(
                    minTileHeight: 60,
                    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                    title: Text(c.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                    subtitle: c.availability == null
                        ? null
                        : Align(
                            alignment: Alignment.centerLeft,
                            child: c.availability == AvailabilityStatus.available
                                ? StatusTag(t.saidAvailable, Tone.good, icon: Icons.check)
                                : StatusTag(t.saidUnavailable, Tone.bad, icon: Icons.close),
                          ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _offer(c),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Open shifts
// ---------------------------------------------------------------------------

class _OpenShiftsTab extends ConsumerWidget {
  const _OpenShiftsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final session = ref.watch(sessionProvider)!;
    final zone = session.venue.timeZone;
    final cfg = SelfServiceSettings.fromVenueSettings(session.venue.settings);
    final async = ref.watch(openShiftsProvider);

    return RefreshIndicator(
      onRefresh: () => _refresh(ref),
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ListView(children: [ErrorNote(e, onRetry: () => ref.invalidate(openShiftsProvider))]),
        data: (rows) {
          final children = <Widget>[];
          String? lastEvent;
          for (final o in rows) {
            if (o.event.id != lastEvent) children.add(GroupHeading(kicker: t.day(o.event.callTime, zone), title: o.event.name));
            lastEvent = o.event.id;
            children.add(_openCard(context, ref, t, zone, cfg, o));
          }
          return MarketList(children: [
            InfoBanner(
              icon: cfg.allowPickups ? Icons.info_outline : Icons.block,
              text: !cfg.allowPickups ? t.pickupsOff : (cfg.pickupsNeedApproval ? t.managerApproves : t.pickupsInstant),
            ),
            if (rows.isEmpty) EmptyNote(t.noOpenShifts),
            ...children,
          ]);
        },
      ),
    );
  }

  Widget _openCard(BuildContext context, WidgetRef ref, T t, String zone, SelfServiceSettings cfg, OpenShift o) => ShiftCard(
                showDay: false,
                t: t,
                zone: zone,
                callTime: o.shift.callTime,
                storefront: o.storefrontName,
                role: o.roleName,
                detail: o.section.isEmpty ? '' : 'Sec ${o.section}',
                tags: [
                  if (o.myRequestId != null) StatusTag(t.requested, Tone.info, icon: Icons.hourglass_top),
                  if (o.availability == AvailabilityStatus.unavailable) StatusTag(t.youSaidCant, Tone.warn),
                ],
                children: [
                  if (o.blocked != null)
                    StatusLine(icon: Icons.block, tone: Tone.bad, text: '${t.cannotTake}: ${o.blocked}')
                  else if (o.myRequestId != null)
                    BigButton.outlined(
                      label: t.cancelRequest,
                      icon: Icons.undo,
                      onPressed: () => _run(context, ref, (repo) async {
                        await repo.cancelShiftRequest(o.myRequestId!);
                        return t.cancelled;
                      }),
                    )
                  else if (cfg.allowPickups)
                    BigButton.filled(label: t.pickUp, icon: Icons.add_task, onPressed: () => _pickUp(context, ref, o, cfg)),
                ],
              );

  Future<void> _pickUp(BuildContext context, WidgetRef ref, OpenShift o, SelfServiceSettings cfg) async {
    final t = ref.read(stringsProvider);
    if (!cfg.pickupsNeedApproval) {
      final zone = ref.read(sessionProvider)!.venue.timeZone;
      final ok = await askText(
        context,
        t: t,
        title: t.pickUpTitle,
        message: '${o.event.name}\n${o.storefrontName} · ${o.roleName} · ${t.day(o.shift.callTime, zone)} ${t.clock(o.shift.callTime, zone)}',
        action: t.pickUp,
        showField: false,
      );
      if (ok == null || !context.mounted) return;
    }
    await _run(context, ref, (repo) async {
      final r = await repo.requestPickup(o.shift.id);
      return r.status == ShiftRequestStatus.approved ? t.itsYours : t.requestSent;
    });
  }
}

// ---------------------------------------------------------------------------
// Requests and offers
// ---------------------------------------------------------------------------

class _RequestsTab extends ConsumerWidget {
  const _RequestsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final session = ref.watch(sessionProvider)!;
    final me = session.workerId;
    final zone = session.venue.timeZone;
    final async = ref.watch(myRequestsProvider);

    return RefreshIndicator(
      onRefresh: () => _refresh(ref),
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ListView(children: [ErrorNote(e, onRetry: () => ref.invalidate(myRequestsProvider))]),
        data: (all) {
          final offers = [for (final r in all) if (r.status == ShiftRequestStatus.offered && r.targetWorkerId == me) r];
          final waiting = [for (final r in all) if (r.status.isOpen && !offers.contains(r)) r];
          final past = [for (final r in all) if (!r.status.isOpen) r];
          if (all.isEmpty) return ListView(children: [EmptyNote(t.noRequests)]);

          return MarketList(children: [
            if (offers.isNotEmpty) GroupHeading(title: t.offersToYou),
            for (final r in offers)
              ShiftCard(
                t: t,
                zone: zone,
                callTime: r.shift.callTime,
                storefront: r.storefrontName,
                role: r.roleName,
                eventName: r.event.name,
                tags: [_kindTag(t, r.kind)],
                children: [
                  StatusLine(icon: Icons.person_outline, tone: Tone.info, text: t.offerFrom(r.requesterName)),
                  if (r.note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('“${r.note}”', style: AppText.body)),
                  const SizedBox(height: 4),
                  Text(t.acceptHelp, style: AppText.meta),
                  const SizedBox(height: AppSpace.s),
                  ButtonPair(
                    left: BigButton.outlined(
                      label: t.decline,
                      icon: Icons.close,
                      onPressed: () => _run(context, ref, (repo) async {
                        await repo.respondSwap(r.id, accept: false);
                        return t.declined;
                      }),
                    ),
                    right: BigButton.filled(
                      label: t.accept,
                      icon: Icons.check,
                      onPressed: () => _run(context, ref, (repo) async {
                        await repo.respondSwap(r.id, accept: true);
                        return t.accepted;
                      }),
                    ),
                  ),
                ],
              ),
            if (waiting.isNotEmpty) GroupHeading(title: t.waiting),
            for (final r in waiting)
              ShiftCard(
                t: t,
                zone: zone,
                callTime: r.shift.callTime,
                storefront: r.storefrontName,
                role: r.roleName,
                eventName: r.event.name,
                tags: [_kindTag(t, r.kind)],
                children: [
                  StatusLine(icon: Icons.hourglass_top, tone: Tone.warn, text: t.statusLabel(r.status)),
                  if (r.kind == ShiftRequestKind.swap)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(r.requesterWorkerId == me ? t.swapTo(r.targetName) : t.swapFrom(r.requesterName), style: AppText.body),
                    ),
                  if (r.requesterWorkerId == me) ...[
                    const SizedBox(height: AppSpace.s),
                    BigButton.outlined(
                      label: t.cancelRequest,
                      icon: Icons.undo,
                      onPressed: () => _run(context, ref, (repo) async {
                        await repo.cancelShiftRequest(r.id);
                        return t.cancelled;
                      }),
                    ),
                  ],
                ],
              ),
            if (past.isNotEmpty) GroupHeading(title: t.history),
            for (final r in past)
              ShiftCard(
                t: t,
                zone: zone,
                callTime: r.shift.callTime,
                storefront: r.storefrontName,
                role: r.roleName,
                eventName: r.event.name,
                tags: [_kindTag(t, r.kind)],
                children: [
                  StatusLine(
                    icon: switch (r.status) {
                      ShiftRequestStatus.approved => Icons.check_circle_outline,
                      ShiftRequestStatus.denied => Icons.cancel_outlined,
                      _ => Icons.remove_circle_outline,
                    },
                    tone: switch (r.status) {
                      ShiftRequestStatus.approved => Tone.good,
                      ShiftRequestStatus.denied => Tone.bad,
                      _ => Tone.idle,
                    },
                    text: [
                      t.statusLabel(r.status),
                      if (r.decidedByName.isNotEmpty && r.status != ShiftRequestStatus.cancelled) t.decidedBy(r.decidedByName),
                    ].join(' '),
                  ),
                  if (r.kind == ShiftRequestKind.swap)
                    Text(r.requesterWorkerId == me ? t.swapTo(r.targetName) : t.swapFrom(r.requesterName), style: AppText.meta),
                  if (r.decisionNote.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('“${r.decisionNote}”', style: AppText.body)),
                ],
              ),
          ]);
        },
      ),
    );
  }
}

Widget _kindTag(T t, ShiftRequestKind k) => StatusTag(
      t.kindLabel(k),
      switch (k) {
        ShiftRequestKind.pickup => Tone.info,
        ShiftRequestKind.drop => Tone.warn,
        ShiftRequestKind.swap => Tone.info,
      },
      icon: switch (k) {
        ShiftRequestKind.pickup => Icons.add_task,
        ShiftRequestKind.drop => Icons.event_busy,
        ShiftRequestKind.swap => Icons.swap_horiz,
      },
    );

// ---------------------------------------------------------------------------
// Availability
// ---------------------------------------------------------------------------

class _AvailabilityTab extends ConsumerWidget {
  const _AvailabilityTab();

  Future<void> _addDates(BuildContext context, WidgetRef ref) async {
    final t = ref.read(stringsProvider);
    final zone = ref.read(sessionProvider)!.venue.timeZone;
    final today = venueDate(DateTime.now().toUtc(), zone);
    final first = DateTime(today.year, today.month, today.day);
    final range = await showDateRangePicker(
      context: context,
      firstDate: first,
      lastDate: first.add(const Duration(days: 366)),
      helpText: t.daysOff,
    );
    if (range == null || !context.mounted) return;
    final note = await askText(context, t: t, title: t.addDates, message: '${t.date(range.start)} – ${t.date(range.end)}', hint: t.noteOptional, action: t.save);
    if (note == null || !context.mounted) return;
    await _run(context, ref, (repo) async {
      await repo.setBlackout(
        DateTime.utc(range.start.year, range.start.month, range.start.day),
        DateTime.utc(range.end.year, range.end.month, range.end.day),
        note: note,
      );
      return t.saved;
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final zone = ref.watch(sessionProvider)!.venue.timeZone;
    final async = ref.watch(myAvailabilityProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(myAvailabilityProvider);
        await ref.read(myAvailabilityProvider.future);
      },
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ListView(children: [ErrorNote(e, onRetry: () => ref.invalidate(myAvailabilityProvider))]),
        data: (data) => MarketList(children: [
          GroupHeading(
            title: t.daysOff,
            trailing: TextButton.icon(onPressed: () => _addDates(context, ref), icon: const Icon(Icons.add), label: Text(t.addDates)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
            child: Text(t.daysOffHelp, style: AppText.meta),
          ),
          if (data.blackouts.isEmpty) EmptyNote(t.noDaysOff),
          for (final b in data.blackouts)
            Card(
              margin: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.s, AppSpace.screen, 0),
              child: ListTile(
                minTileHeight: 60,
                leading: const Icon(Icons.beach_access_outlined),
                title: Text(b.startsOn == b.endsOn ? t.date(b.startsOn) : '${t.date(b.startsOn)} – ${t.date(b.endsOn)}',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                subtitle: b.note.isEmpty ? null : Text(b.note),
                trailing: IconButton(
                  tooltip: t.remove,
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _run(context, ref, (repo) async {
                    await repo.deleteBlackout(b.id);
                    return t.saved;
                  }),
                ),
              ),
            ),
          GroupHeading(title: t.upcomingEvents),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
            child: Text(t.availabilityHelp, style: AppText.meta),
          ),
          if (data.events.isEmpty) EmptyNote(t.noEvents),
          for (final e in data.events)
            _AvailabilityCard(
              item: e,
              t: t,
              zone: zone,
              inDaysOff: data.blackouts.any((b) => b.covers(venueDate(e.event.callTime, zone))),
            ),
        ]),
      ),
    );
  }
}

class _AvailabilityCard extends ConsumerWidget {
  const _AvailabilityCard({required this.item, required this.t, required this.zone, required this.inDaysOff});

  final EventAvailability item;
  final T t;
  final String zone;
  final bool inDaysOff;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = item.event;
    return Card(
      margin: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.s, AppSpace.screen, 0),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(child: Text('${t.day(e.callTime, zone)} · ${t.clock(e.callTime, zone)}'.toUpperCase(), style: AppText.kicker)),
              if (item.scheduled) StatusTag(t.scheduledTag, Tone.good, icon: Icons.event_available),
              if (inDaysOff) ...[const SizedBox(width: 4), StatusTag(t.inDaysOff, Tone.warn)],
            ]),
            const SizedBox(height: 4),
            Text(e.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, height: 1.25)),
            const SizedBox(height: AppSpace.m),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<AvailabilityStatus>(
                emptySelectionAllowed: true,
                showSelectedIcon: false,
                style: SegmentedButton.styleFrom(
                  minimumSize: const Size(0, 52),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  selectedBackgroundColor: item.status == AvailabilityStatus.unavailable ? AppColors.badSoft : AppColors.goodSoft,
                  selectedForegroundColor: item.status == AvailabilityStatus.unavailable ? AppColors.bad : AppColors.good,
                ),
                segments: [
                  ButtonSegment(value: AvailabilityStatus.available, icon: const Icon(Icons.check), label: Text(t.iCanWork)),
                  ButtonSegment(value: AvailabilityStatus.unavailable, icon: const Icon(Icons.close), label: Text(t.iCant)),
                ],
                selected: {?item.status},
                onSelectionChanged: (sel) => _run(context, ref, (repo) async {
                  await repo.setEventAvailability(e.id, sel.isEmpty ? null : sel.first);
                  return t.saved;
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
