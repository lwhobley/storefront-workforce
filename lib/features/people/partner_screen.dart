import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/download.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/people_repository.dart';
import '../pay/pay_logic.dart' show money;
import 'people_logic.dart';
import 'people_providers.dart';

typedef _Key = ({DateTime from, DateTime to, String? id});

final _npoProvider = FutureProvider.autoDispose.family<NpoPortalData, _Key>((ref, k) async {
  final session = ref.watch(sessionProvider)!;
  return peopleRepo(ref).loadNpoPortal(session, k.from, k.to, groupId: k.id);
});

final _agencyProvider = FutureProvider.autoDispose.family<AgencyPortalData, _Key>((ref, k) async {
  final session = ref.watch(sessionProvider)!;
  return peopleRepo(ref).loadAgencyPortal(session, k.from, k.to, agencyId: k.id);
});

/// Season: August 1 to July 31.
({DateTime from, DateTime to}) _season(DateTime today, {int back = 0}) {
  final start = today.month >= 8 ? today.year : today.year - 1;
  return (from: DateTime.utc(start - back, 8, 1), to: DateTime.utc(start - back + 1, 7, 31));
}

/// The partner portal: an NPO coordinator's group or a temp agency contact's placed
/// workers. Shows their people, schedule, hours and what the venue owes them.
class PartnerScreen extends ConsumerStatefulWidget {
  const PartnerScreen({super.key});

  @override
  ConsumerState<PartnerScreen> createState() => _PartnerScreenState();
}

class _PartnerScreenState extends ConsumerState<PartnerScreen> {
  int _seasonBack = 0;
  String? _id;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider)!;
    final today = venueDate(DateTime.now().toUtc(), session.venue.timeZone);
    final season = _season(today, back: _seasonBack);
    final key = (from: season.from, to: season.to, id: _id);
    final isNpo = session.can('npo_portal');
    final rangePicker = DropdownButton<int>(
      value: _seasonBack,
      underline: const SizedBox.shrink(),
      items: [
        for (final b in const [0, 1])
          DropdownMenuItem(value: b, child: Text('Season ${_season(today, back: b).from.year}–${(_season(today, back: b).to.year % 100).toString().padLeft(2, '0')}')),
      ],
      onChanged: (v) => setState(() => _seasonBack = v ?? 0),
    );
    return Scaffold(
      body: SafeArea(
        child: isNpo
            ? ref.watch(_npoProvider(key)).when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(_npoProvider(key))),
                  data: (d) => _NpoView(data: d, season: season, rangePicker: rangePicker, onGroup: (id) => setState(() => _id = id)),
                )
            : ref.watch(_agencyProvider(key)).when(
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(_agencyProvider(key))),
                  data: (d) => _AgencyView(data: d, season: season, rangePicker: rangePicker, onAgency: (id) => setState(() => _id = id)),
                ),
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.header, required this.labels, required this.children});

  final Widget header;
  final List<String> labels;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 480;
    return DefaultTabController(
      length: labels.length,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        TabBar(
          isScrollable: narrow,
          tabAlignment: narrow ? TabAlignment.start : null,
          tabs: [for (final l in labels) Tab(height: 48, text: l)],
        ),
        Expanded(child: TabBarView(children: children)),
      ]),
    );
  }
}

Widget _switcher(List<(String, String)> options, String current, ValueChanged<String> onChanged) => options.length < 2
    ? const SizedBox.shrink()
    : DropdownButton<String>(
        value: current,
        underline: const SizedBox.shrink(),
        items: [for (final (id, name) in options) DropdownMenuItem(value: id, child: Text(name))],
        onChanged: (v) => v == null ? null : onChanged(v),
      );

/// Two summary tiles per row on phones, 180 wide otherwise.
double _tileWidth(BuildContext context) {
  final w = (MediaQuery.sizeOf(context).width - 2 * (AppSpace.screen - 4)) / 2;
  return w < 180 ? w.floorToDouble() : 180;
}

String _eventLine(Event e, String zone) => '${DateFormat('EEE MMM d').format(atVenue(e.startTime, zone))} · ${e.name}';

/// Upcoming shifts grouped by event.
class _ScheduleList extends ConsumerWidget {
  const _ScheduleList({required this.activity, required this.members});

  final PartnerActivity activity;
  final Map<String, PortalMember> members;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zone = ref.watch(sessionProvider)!.venue.timeZone;
    final venue = ref.watch(venueProvider).value;
    final shifts = upcomingShifts(activity, DateTime.now().toUtc());
    final byEvent = <String, List<Shift>>{};
    for (final s in shifts) {
      byEvent.putIfAbsent(s.eventId, () => []).add(s);
    }
    if (byEvent.isEmpty) return const EmptyNote('No upcoming shifts.');
    return ListView(padding: const EdgeInsets.only(bottom: 40), children: [
      for (final MapEntry(key: eventId, value: list) in byEvent.entries) ...[
        SectionHeading(_eventLine(activity.events[eventId]!, zone), trailing: Text('${list.length} people', style: AppText.meta)),
        for (final s in list)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
            title: Text(members[s.workerId]?.displayName ?? 'Someone'),
            subtitle: Text('${activity.storefrontNames[s.id] ?? ''} · ${venue?.roleName(s.jobRoleCode) ?? s.jobRoleCode}'),
            trailing: Text('Call ${DateFormat('h:mm a').format(atVenue(s.callTime, zone))}', style: AppText.meta.copyWith(fontWeight: FontWeight.w600)),
          ),
      ],
    ]);
  }
}

/// Hours per event from time records.
class _HoursList extends ConsumerWidget {
  const _HoursList({required this.activity, required this.members, required this.season});

  final PartnerActivity activity;
  final Map<String, PortalMember> members;
  final ({DateTime from, DateTime to}) season;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider)!;
    final zone = session.venue.timeZone;
    final rows = partnerHoursByEvent(activity, timeZone: zone, breakRules: session.rules.breaks, from: season.from, to: season.to)
        .where((h) => h.event.status == EventStatus.completed || h.worked > 0)
        .toList();
    final total = rows.fold(0, (s, r) => s + r.totalMinutes);
    if (rows.isEmpty) return const EmptyNote('No hours this season yet.');
    return ListView(padding: const EdgeInsets.only(bottom: 40), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.screen - 4, AppSpace.m, AppSpace.screen - 4, 0),
        child: Row(children: [
          Expanded(child: StatTile(label: 'Hours this season', value: decimalHours(total))),
          Expanded(child: StatTile(label: 'Events worked', value: '${rows.where((r) => r.worked > 0).length}')),
        ]),
      ),
      for (final r in rows)
        ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
          title: Text(_eventLine(r.event, zone)),
          subtitle: Text('${r.worked} of ${r.scheduled.length} scheduled worked${r.scheduled.length > r.worked ? ' · ${r.scheduled.difference(r.minutesByWorker.keys.toSet()).length} did not clock in' : ''}'),
          trailing: Text('${decimalHours(r.totalMinutes)} h', style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
          children: [
            for (final id in {...r.scheduled, ...r.minutesByWorker.keys})
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen + 12),
                title: Text(members[id]?.displayName ?? 'Someone'),
                trailing: r.minutesByWorker.containsKey(id)
                    ? Text('${decimalHours(r.minutesByWorker[id]!)} h')
                    : const StatusTag('No clock-in', Tone.bad),
              ),
          ],
        ),
      const Padding(
        padding: EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.l, AppSpace.screen, 0),
        child: Text('Hours from clock-in records, counted the same way as payouts. Short paid breaks count; unpaid meal breaks do not.', style: AppText.meta),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// NPO coordinator
// ---------------------------------------------------------------------------

class _NpoView extends ConsumerWidget {
  const _NpoView({required this.data, required this.season, required this.rangePicker, required this.onGroup});

  final NpoPortalData data;
  final ({DateTime from, DateTime to}) season;
  final Widget rangePicker;
  final ValueChanged<String> onGroup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(venueProvider).value;
    final zone = ref.watch(sessionProvider)!.venue.timeZone;
    final members = {for (final m in data.members) m.id: m};
    final p = data.payouts;
    int sum(String status) => p.where((x) => x.status == status).fold(0, (s, x) => s + x.totalCents);
    return _Tabs(
      header: ScreenHeader(
        kicker: 'NPO group',
        title: data.groupName,
        subtitle: '${data.members.length} members · ${data.legalName}',
        actions: [_switcher(data.groups, data.groupId, onGroup), rangePicker],
      ),
      labels: const ['Members', 'Schedule', 'Hours', 'Payouts'],
      children: [
        ListView(padding: const EdgeInsets.only(bottom: 40), children: [
          if (data.members.isEmpty) const EmptyNote('No members yet. The venue adds members to your group.'),
          for (final m in data.members)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
              title: Row(children: [
                Flexible(child: Text(m.displayName, overflow: TextOverflow.ellipsis)),
                if (m.minor) ...[const SizedBox(width: 6), const StatusTag('Under 18', Tone.warn)],
                if (m.status != 'active') ...[const SizedBox(width: 6), const StatusTag('Inactive', Tone.idle)],
              ]),
              subtitle: Text([
                m.employeeNumber,
                if (m.phone.isNotEmpty) m.phone,
                m.roles.map((r) => venue?.roleName(r) ?? r).join(', '),
                if (m.onboardingMissing.isNotEmpty) 'To do: ${m.onboardingMissing.join(', ')}',
              ].where((x) => x.isNotEmpty).join(' · ')),
              trailing: StatusTag(
                switch (m.waiverStatus) {
                  'complete' || 'approved' => 'Waiver signed',
                  'not_required' => '${m.onboardingPercent}% onboarded',
                  _ => 'Waiver not signed',
                },
                switch (m.waiverStatus) {
                  'complete' || 'approved' => Tone.good,
                  'not_required' => Tone.idle,
                  _ => Tone.bad,
                },
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.l, AppSpace.screen, 0),
            child: Text('Volunteers under 18 need a parent or guardian on the waiver. Birth dates stay with the venue; you see only who is under 18.', style: AppText.meta),
          ),
        ]),
        _ScheduleList(activity: data.activity, members: members),
        _HoursList(activity: data.activity, members: members, season: season),
        ListView(padding: const EdgeInsets.only(bottom: 40), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.screen - 4, AppSpace.m, AppSpace.screen - 4, 0),
            child: Wrap(children: [
              for (final (label, value, tone) in [
                ('Paid', money(sum('paid')), Tone.good),
                ('Approved, not paid yet', money(sum('approved')), Tone.info),
                ('Pending review', money(sum('pending')), Tone.idle),
                ('Hours paid for', formatHundredths(p.fold(0, (s, x) => s + x.hoursHundredths)), null),
              ])
                SizedBox(width: _tileWidth(context), child: StatTile(label: label, value: value, tone: tone)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: p.isEmpty
                    ? null
                    : () async {
                        final file = '${data.groupName.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')}-statement-${season.from.year}.csv';
                        final downloaded = await saveTextFile(file, npoStatementCsv(data, zone));
                        if (context.mounted) showMessage(context, downloaded ? 'Statement downloaded' : 'Statement copied to the clipboard');
                      },
                icon: const Icon(Icons.download),
                label: const Text('Download statement (CSV)'),
              ),
            ),
          ),
          if (p.isEmpty) const EmptyNote('No payouts this season yet.'),
          for (final x in p.reversed)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
              title: Text(data.eventNames[x.eventId] ?? data.activity.events[x.eventId]?.name ?? 'Event'),
              subtitle: Text([
                if (data.activity.events[x.eventId] case final e?) DateFormat('EEE MMM d').format(atVenue(e.startTime, zone)),
                '${x.membersWorked} of ${x.membersScheduled} worked',
                '${formatHundredths(x.hoursHundredths)} h at ${money(x.hourlyRateCents)}',
                if (x.deductionsCents > 0) 'deductions ${money(x.deductionsCents)}',
                if (x.adjustmentCents != 0) 'adjustment ${money(x.adjustmentCents)} (${x.adjustmentReason})',
                if (x.paymentReference.isNotEmpty) 'ref ${x.paymentReference}',
              ].join(' · ')),
              trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(money(x.totalCents), style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                StatusTag(x.status[0].toUpperCase() + x.status.substring(1), switch (x.status) {
                  'paid' => Tone.good,
                  'approved' => Tone.info,
                  _ => Tone.idle,
                }),
              ]),
            ),
        ]),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Temp agency contact
// ---------------------------------------------------------------------------

class _AgencyView extends ConsumerWidget {
  const _AgencyView({required this.data, required this.season, required this.rangePicker, required this.onAgency});

  final AgencyPortalData data;
  final ({DateTime from, DateTime to}) season;
  final Widget rangePicker;
  final ValueChanged<String> onAgency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider)!;
    final venue = ref.watch(venueProvider).value;
    final zone = session.venue.timeZone;
    final members = {for (final m in data.members) m.id: m};
    String roleName(String c) => venue?.roleName(c) ?? c;
    final today = venueDate(DateTime.now().toUtc(), zone);
    final billing = agencyBillingByPeriod(
      data,
      venueId: session.venue.id,
      timeZone: zone,
      venueSettings: session.venue.settings,
      from: season.from,
      to: season.to.isAfter(today) ? today : season.to,
    );
    final total = billing.fold(0, (s, b) => s + b.totalCents);
    return _Tabs(
      header: ScreenHeader(
        kicker: 'Temp agency',
        title: data.agencyName,
        subtitle: '${data.members.length} placed workers',
        actions: [_switcher(data.agencies, data.agencyId, onAgency), rangePicker],
      ),
      labels: const ['Workers', 'Schedule', 'Hours', 'Billing'],
      children: [
        ListView(padding: const EdgeInsets.only(bottom: 40), children: [
          if (data.members.isEmpty) const EmptyNote('No placed workers yet.'),
          for (final m in data.members)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
              title: Text(m.displayName),
              subtitle: Text([
                m.employeeNumber,
                m.roles.map(roleName).join(', '),
                if (m.onboardingMissing.isNotEmpty) 'To do: ${m.onboardingMissing.join(', ')}',
              ].where((x) => x.isNotEmpty).join(' · ')),
              trailing: StatusTag(m.onboardingPercent == 100 ? 'Onboarded' : '${m.onboardingPercent}% onboarded', m.onboardingPercent == 100 ? Tone.good : Tone.warn),
            ),
        ]),
        _ScheduleList(activity: data.activity, members: members),
        _HoursList(activity: data.activity, members: members, season: season),
        ListView(padding: const EdgeInsets.only(bottom: 40), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.screen - 4, AppSpace.m, AppSpace.screen - 4, 0),
            child: Wrap(children: [
              SizedBox(width: _tileWidth(context), child: StatTile(label: 'Billable this season', value: money(total), tone: Tone.info)),
              SizedBox(width: _tileWidth(context), child: StatTile(label: 'Hours', value: decimalHours(billing.fold(0, (s, b) => s + b.minutes)))),
            ]),
          ),
          SectionHeading('Your bill rates'),
          if (data.billRates.isEmpty) const EmptyNote('No bill rates on file. Ask the venue to add them.'),
          for (final r in data.billRates)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
              title: Text(roleName(r.jobRoleCode)),
              subtitle: Text('From ${DateFormat('MMM d, y').format(r.effectiveFrom)}${r.effectiveTo == null ? '' : ' to ${DateFormat('MMM d, y').format(r.effectiveTo!)}'}'),
              trailing: Text('${money(r.billRateCents)}/h${r.overtimeBillRateCents == null ? '' : ' · OT ${money(r.overtimeBillRateCents!)}/h'}'),
            ),
          SectionHeading(
            'By pay period',
            trailing: OutlinedButton.icon(
              onPressed: billing.isEmpty
                  ? null
                  : () async {
                      final file = '${data.agencyName.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')}-billable-${season.from.year}.csv';
                      final ok = await saveTextFile(file, agencyBillingCsv(data, billing, roleName: roleName));
                      if (context.mounted) showMessage(context, ok ? 'Billing downloaded' : 'Billing copied to the clipboard');
                    },
              icon: const Icon(Icons.download),
              label: const Text('CSV'),
            ),
          ),
          if (billing.isEmpty) const EmptyNote('No billable hours this season yet.'),
          for (final b in billing)
            ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
              title: Text('${DateFormat('MMM d').format(b.period.startsOn)} – ${DateFormat('MMM d, y').format(b.period.endsOn)}'),
              subtitle: Text('${b.lines.length} lines · ${decimalHours(b.minutes)} h${b.problems.isEmpty ? '' : ' · ${b.problems.length} to check with the venue'}'),
              trailing: Text(money(b.totalCents), style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
              children: [
                for (final l in b.lines)
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen + 12),
                    title: Text('${members[l.workerId]?.displayName ?? 'Someone'} · ${l.jobRoleCode == null ? '' : roleName(l.jobRoleCode!)}'),
                    subtitle: Text([
                      DateFormat('EEE MMM d').format(l.firstWorkDate),
                      data.activity.events[l.eventId]?.name ?? '',
                      '${formatHundredths(l.regularHoursHundredths)} h × ${l.billRateCents == null ? 'no rate' : money(l.billRateCents!)}',
                      if (l.overtimeMinutes > 0) 'OT ${formatHundredths(l.overtimeHoursHundredths)} h × ${money(l.overtimeBillRateCents ?? l.billRateCents ?? 0)}',
                    ].where((x) => x.isNotEmpty).join(' · ')),
                    trailing: Text(money(l.amountCents)),
                  ),
              ],
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.l, AppSpace.screen, 0),
            child: Text('Hours over 40 in a workweek at this venue bill at the overtime bill rate. The venue\'s invoice is final.', style: AppText.meta),
          ),
        ]),
      ],
    );
  }
}
