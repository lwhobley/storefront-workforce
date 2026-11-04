import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/download.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/operations_repository.dart';
import 'incident_detail.dart';
import 'incident_form.dart';
import 'operations_logic.dart';
import 'operations_providers.dart';
import 'ops_queue.dart';
import 'ops_widgets.dart';

/// The incidents with this device's waiting reports, notes and photos on top.
List<Incident>? incidentsView(WidgetRef ref) {
  final list = ref.watch(incidentsProvider).value;
  ref.watch(opsQueueProvider);
  if (list == null) return null;
  final q = ref.read(opsQueueProvider.notifier);
  return withPendingIncidents(
    list,
    drafts: q.pendingIncidents(),
    notes: q.pendingIncidentNotes(),
    photos: q.pendingIncidentPhotos(),
    byName: ref.read(sessionProvider)?.displayName ?? '',
  );
}

IconData incidentIcon(IncidentKind k) => switch (k) {
      IncidentKind.injury => Icons.medical_services_outlined,
      IncidentKind.safety => Icons.warning_amber_outlined,
      IncidentKind.employee => Icons.badge_outlined,
      IncidentKind.other => Icons.report_outlined,
    };

Tone severityTone(IncidentSeverity s) => switch (s) {
      IncidentSeverity.high => Tone.bad,
      IncidentSeverity.medium => Tone.warn,
      IncidentSeverity.low => Tone.idle,
    };

Tone statusTone(IncidentStatus s) => switch (s) {
      IncidentStatus.open => Tone.bad,
      IncidentStatus.followingUp => Tone.warn,
      IncidentStatus.closed => Tone.good,
    };

enum _Show { open, closed, all }

/// Injuries, safety issues and employee incidents, with follow-up. Leads see their
/// storefront's; employee incidents only show to people who manage staff. Manager
/// screen: English.
class IncidentsScreen extends ConsumerStatefulWidget {
  const IncidentsScreen({super.key});

  @override
  ConsumerState<IncidentsScreen> createState() => _IncidentsScreenState();
}

class _IncidentsScreenState extends ConsumerState<IncidentsScreen> {
  _Show _show = _Show.open;
  IncidentKind? _kind;

  Future<void> _export(List<Incident> list, VenueContext venue) async {
    final stamp = DateFormat('yyyy-MM-dd').format(atVenue(DateTime.now().toUtc(), venue.venue.timeZone));
    final downloaded = await saveTextFile('incidents-$stamp.csv', incidentsCsv(list, venue));
    if (mounted) showMessage(context, downloaded ? 'Downloaded ${list.length} incidents.' : 'Copied ${list.length} incidents as CSV.');
  }

  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(venueProvider).value;
    final async = ref.watch(incidentsProvider);
    final all = incidentsView(ref);
    final open = all?.where((i) => i.status != IncidentStatus.closed).length;
    final shown = [
      for (final i in all ?? const <Incident>[])
        if ((_show == _Show.all || (_show == _Show.closed) == (i.status == IncidentStatus.closed)) && (_kind == null || i.kind == _kind)) i,
    ];

    final header = <Widget>[
      ScreenHeader(
        title: 'Incidents',
        subtitle: open == null ? 'Injuries, safety issues and staff incidents' : open == 0 ? 'Nothing open' : '$open open',
        actions: [
          FilledButton.icon(onPressed: () => showIncidentForm(context), icon: const Icon(Icons.add), label: const Text('Log incident')),
          if (venue != null && shown.isNotEmpty)
            OutlinedButton.icon(onPressed: () => _export(shown, venue), icon: const Icon(Icons.download_outlined), label: const Text('CSV')),
          IconButton(tooltip: 'Reload', icon: const Icon(Icons.refresh), onPressed: () => ref.read(incidentsProvider.notifier).refresh()),
        ],
      ),
      const OpsQueueBanner(),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
        child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SegmentedButton<_Show>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _Show.open, label: Text('Open')),
              ButtonSegment(value: _Show.closed, label: Text('Closed')),
              ButtonSegment(value: _Show.all, label: Text('All')),
            ],
            selected: {_show},
            onSelectionChanged: (v) => setState(() => _show = v.first),
          ),
          for (final k in [null, ...IncidentKind.values])
            ChoiceChip(label: Text(k == null ? 'Every kind' : k.label), selected: _kind == k, onSelected: (_) => setState(() => _kind = k)),
        ]),
      ),
      const SizedBox(height: AppSpace.s),
    ];

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => ref.read(incidentsProvider.notifier).refresh(),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              ...header,
              if (all == null && async.hasError) ErrorNote(async.error!, onRetry: () => ref.invalidate(incidentsProvider)),
              if (all == null && !async.hasError) const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
              if (all != null && shown.isEmpty) EmptyNote(_show == _Show.open ? 'No open incidents.' : 'No incidents here.'),
              if (venue != null)
                for (final i in shown) _IncidentRow(incident: i, venue: venue),
            ],
          ),
        ),
      ),
    );
  }
}

class _IncidentRow extends StatelessWidget {
  const _IncidentRow({required this.incident, required this.venue});

  final Incident incident;
  final VenueContext venue;

  @override
  Widget build(BuildContext context) {
    final i = incident;
    final when = DateFormat('MMM d, h:mm a').format(atVenue(i.occurredAt, venue.venue.timeZone));
    final where = venue.storefront(i.storefrontId ?? '')?.name ?? 'Venue';
    final tone = severityTone(i.severity);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen - 4, vertical: 4),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => showIncidentDetail(context, i.id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  backgroundColor: toneSoft(tone, context),
                  foregroundColor: toneColor(tone, context),
                  child: Icon(incidentIcon(i.kind), semanticLabel: i.kind.label),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${i.kind.label} · $where', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                      Text(i.summary, style: AppText.body.copyWith(fontSize: 14), maxLines: 2, overflow: TextOverflow.ellipsis),
                      Text(
                        [when, if (i.people.isNotEmpty) i.people.map((p) => p.name).join(', '), if (i.assignedToName.isNotEmpty) 'Owner: ${i.assignedToName}'].join(' · '),
                        style: AppText.meta,
                      ),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 4, children: [
                        StatusTag(i.severity.label, tone),
                        StatusTag(i.status.label, statusTone(i.status)),
                        if (i.photoPaths.isNotEmpty || i.pendingPhotos > 0)
                          StatusTag('${i.photoPaths.length + i.pendingPhotos}', Tone.idle, icon: Icons.photo_outlined),
                        if (i.pending) const StatusTag('Waiting to send', Tone.warn, icon: Icons.cloud_upload_outlined),
                      ]),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: AppColors.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
