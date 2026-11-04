import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../core/time/venue_time.dart';
import '../../data/models.dart';
import '../../data/operations_repository.dart';
import '../people/people_logic.dart' show toCsv;
import 'ops_queue.dart';

/// Shows changes still waiting on this device on top of what the server sent: ticks,
/// notes and photo counts, marked as waiting. A run nobody had started shows as started.
EventChecklists withPendingChanges(
  EventChecklists data,
  List<PendingChecklistChange> pending, {
  required Map<String, StorefrontKind> kinds,
  String byName = '',
}) {
  if (pending.isEmpty) return data;
  final runs = [...data.runs];
  for (final p in pending) {
    final c = p.change;
    if (c.eventId != data.eventId) continue;
    final template = data.templates.where((t) => t.id == c.templateId).firstOrNull;
    var index = runs.indexWhere((r) => r.storefrontId == c.storefrontId && r.templateId == c.templateId);
    ChecklistRun run;
    if (index >= 0) {
      run = runs[index];
    } else if (template != null) {
      run = EventChecklists(eventId: data.eventId, storefrontIds: const [], templates: const [], runs: const [])
          .runFor(c.storefrontId, template, kinds[c.storefrontId] ?? StorefrontKind.permanentStand);
    } else {
      continue;
    }
    final items = [
      for (final i in run.items)
        if (i.templateItemId != c.templateItemId)
          i
        else
          i.copyWith(
            done: c.done,
            doneByName: c.done ? byName : '',
            doneAt: c.done ? c.occurredAt : null,
            clearDoneAt: !c.done,
            note: c.note,
            pendingPhotos: i.pendingPhotos + p.photos,
            pending: true,
            lastChangeAt: c.occurredAt,
          ),
    ];
    final updated = run.copyWith(items: items, status: _statusOf(run.status, items));
    if (index >= 0) {
      runs[index] = updated;
    } else {
      runs.add(updated);
    }
  }
  return data.copyWith(runs: runs);
}

ChecklistStatus _statusOf(ChecklistStatus before, List<ChecklistRunItem> items) {
  if (before == ChecklistStatus.signedOff) return before;
  if (items.isNotEmpty && items.every((i) => i.finished)) return ChecklistStatus.complete;
  return items.any((i) => i.done || i.pending) || before != ChecklistStatus.notStarted ? ChecklistStatus.inProgress : ChecklistStatus.notStarted;
}

/// Counts for the summary line on the Checklists screen.
class ChecklistSummary {
  const ChecklistSummary({this.signedOff = 0, this.ready = 0, this.inProgress = 0, this.notStarted = 0});

  final int signedOff;
  final int ready;
  final int inProgress;
  final int notStarted;

  int get total => signedOff + ready + inProgress + notStarted;

  static ChecklistSummary of(Iterable<ChecklistRun> runs) {
    var s = 0, r = 0, p = 0, n = 0;
    for (final run in runs) {
      switch (run.status) {
        case ChecklistStatus.signedOff:
          s++;
        case ChecklistStatus.complete:
          r++;
        case ChecklistStatus.inProgress:
          p++;
        case ChecklistStatus.notStarted:
          n++;
      }
    }
    return ChecklistSummary(signedOff: s, ready: r, inProgress: p, notStarted: n);
  }
}

/// The server's incidents plus reports, notes and photos still waiting on this device.
List<Incident> withPendingIncidents(
  List<Incident> server, {
  List<(IncidentDraft, int)> drafts = const [],
  List<IncidentNoteDraft> notes = const [],
  Map<String, int> photos = const {},
  String byName = '',
}) {
  final known = {for (final i in server) i.id};
  final all = [
    for (final (d, n) in drafts)
      if (!known.contains(d.id)) d.toPendingIncident(reportedByName: byName, photos: n),
    ...server,
  ];
  if (notes.isEmpty && photos.isEmpty) return all..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
  return [
    for (final i in all)
      i.copyWith(
        notes: [
          ...i.notes,
          for (final n in notes)
            if (n.incidentId == i.id && !i.notes.any((x) => x.id == n.id))
              IncidentNote(id: n.id, kind: 'note', body: n.body, authorName: byName, createdAt: n.createdAt, pending: true),
        ],
        pendingPhotos: i.pendingPhotos + (photos[i.id] ?? 0),
      ),
  ]..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
}

/// Storefronts where the person holds any of [perms] (venue, level or storefront scope).
Set<String> storefrontsInScope(AppSession s, VenueContext venue, Set<String> perms) {
  final out = <String>{};
  for (final g in s.grants) {
    if (!g.permissions.any(perms.contains)) continue;
    for (final f in venue.storefronts) {
      if (g.scopeType == 'venue' || (g.scopeType == 'storefront' && g.scopeId == f.id) || (g.scopeType == 'level' && g.scopeId == f.levelId)) {
        out.add(f.id);
      }
    }
  }
  return out;
}

String storefrontKindLabel(StorefrontKind k) => switch (k) {
      StorefrontKind.bar => 'Bar',
      StorefrontKind.portableCart => 'Cart',
      StorefrontKind.kiosk => 'Kiosk',
      StorefrontKind.permanentStand => 'Stand',
    };

/// The incident list as a spreadsheet, with times at the venue.
String incidentsCsv(List<Incident> incidents, VenueContext venue) {
  final zone = venue.venue.timeZone;
  final fmt = DateFormat('yyyy-MM-dd HH:mm');
  String at(DateTime? t) => t == null ? '' : fmt.format(atVenue(t, zone));
  return toCsv([
    ['Occurred', 'Kind', 'Severity', 'Status', 'Event', 'Storefront', 'People involved', 'Description', 'Reported by', 'Follow-up owner', 'Notes', 'Photos', 'Closing note', 'Closed'],
    for (final i in incidents)
      [
        at(i.occurredAt),
        i.kind.label,
        i.severity.label,
        i.status.label,
        i.eventName,
        venue.storefront(i.storefrontId ?? '')?.name ?? '',
        i.people.map((p) => p.name).join('; '),
        i.description,
        i.reportedByName,
        i.assignedToName,
        i.notes.where((n) => n.kind == 'note').length,
        i.photoPaths.length,
        i.closingNote,
        at(i.closedAt),
      ],
  ]);
}

/// Events to choose from on the operations screens: the last two weeks and the next
/// month, soonest first.
List<Event> recentEvents(List<Event> events, DateTime now) => [
      for (final e in events)
        if (e.status != EventStatus.cancelled &&
            e.startTime.isAfter(now.subtract(const Duration(days: 14))) &&
            e.startTime.isBefore(now.add(const Duration(days: 31))))
          e,
    ]..sort((a, b) => a.startTime.compareTo(b.startTime));
