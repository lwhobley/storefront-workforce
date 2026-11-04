import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:storefront_workforce/app/providers.dart';
import 'package:storefront_workforce/data/demo_repository.dart';
import 'package:storefront_workforce/data/models.dart';
import 'package:storefront_workforce/data/operations_repository.dart';
import 'package:storefront_workforce/features/operations/operations_logic.dart';
import 'package:storefront_workforce/features/operations/ops_queue.dart';
import 'package:workforce_core/workforce_core.dart';

/// The demo backend with a switch for "no signal", and one for "the server stored it
/// but the answer was lost on the way back".
class FlakyRepo extends DemoWorkforceRepository {
  FlakyRepo({super.now});

  bool offline = false;
  bool loseAnswer = false;
  int calls = 0;

  static const _down = AppFailure('No connection. Your change is saved on this device.', offline: true);

  @override
  Future<ChecklistRun> recordChecklistItem(AppSession session, ChecklistItemChange change, {List<Uint8List> photos = const []}) async {
    calls++;
    if (offline) throw _down;
    final run = await super.recordChecklistItem(session, change, photos: photos);
    if (loseAnswer) {
      loseAnswer = false;
      throw _down;
    }
    return run;
  }

  @override
  Future<Incident> logIncident(AppSession session, IncidentDraft draft, {List<Uint8List> photos = const []}) async {
    calls++;
    if (offline) throw _down;
    final i = await super.logIncident(session, draft, photos: photos);
    if (loseAnswer) {
      loseAnswer = false;
      throw _down;
    }
    return i;
  }
}

void main() {
  final now = DateTime.now().toUtc();
  final photo = Uint8List.fromList(List.filled(64, 7));
  var seq = 0;
  String uid() => '00000000-0000-4000-9000-${(++seq).toRadixString(16).padLeft(12, '0')}';

  Future<(DemoWorkforceRepository, AppSession)> signIn(String pin, [DemoWorkforceRepository? repo]) async {
    final r = repo ?? DemoWorkforceRepository(now: now);
    await r.signOut();
    return (r, await r.signInWithPin(pin));
  }

  ChecklistItemChange changeFor(ChecklistRun run, ChecklistRunItem item, {required bool done, DateTime? at, String? note}) => ChecklistItemChange(
        id: uid(),
        eventId: run.eventId,
        storefrontId: run.storefrontId,
        templateId: run.templateId,
        templateItemId: item.templateItemId,
        done: done,
        occurredAt: at ?? DateTime.now().toUtc(),
        note: note,
      );

  Future<(EventChecklists, VenueContext)> load(DemoWorkforceRepository repo, AppSession s) async {
    final venue = await repo.loadVenue(s);
    return (await repo.loadEventChecklists(s, repo.liveEvent!.id), venue);
  }

  group('checklists', () {
    test('sample data: signed off, ready, in progress, and photos', () async {
      final (repo, s) = await signIn('200002');
      final (data, venue) = await load(repo, s);
      final runs = [for (final id in data.storefrontIds) ...data.runsAt(id, venue.storefront(id)!.kind)];
      final summary = ChecklistSummary.of(runs);
      expect(summary.signedOff, greaterThan(0));
      expect(summary.ready, greaterThan(0));
      expect(summary.inProgress, greaterThan(0));
      expect(summary.notStarted, greaterThan(0), reason: 'closing has not started during the game');
      final withPhoto = runs.expand((r) => r.items).firstWhere((i) => i.photoPaths.isNotEmpty);
      expect(await repo.downloadChecklistPhoto(withPhoto.photoPaths.first), isNotNull);
      expect(data.signOffStorefrontIds, containsAll(data.storefrontIds), reason: 'a venue-wide manager signs off anywhere');
    });

    test('a lead works only their storefront and cannot sign off', () async {
      final (repo, lead) = await signIn('300003');
      final (data, venue) = await load(repo, lead);
      final mine = lead.grants.firstWhere((g) => g.scopeType == 'storefront').scopeId!;
      expect(data.storefrontIds, [mine]);
      expect(data.signOffStorefrontIds, isEmpty);
      final opening = data.runsAt(mine, venue.storefront(mine)!.kind).firstWhere((r) => r.templateKind == ChecklistKind.opening);
      expect(opening.chipLabel, '${opening.templateName} ${opening.doneCount}/${opening.total}');
      expect(opening.status, ChecklistStatus.inProgress);

      // Another storefront is refused.
      final other = venue.storefronts.firstWhere((f) => f.id != mine);
      final template = data.templates.first;
      await expectLater(
        repo.recordChecklistItem(lead, ChecklistItemChange(id: uid(), eventId: data.eventId, storefrontId: other.id, templateId: template.id,
            templateItemId: template.items.first.id, done: true, occurredAt: DateTime.now().toUtc())),
        throwsA(isA<AppFailure>()),
      );

      // Finish it: photo items need a photo.
      for (final item in opening.items.where((i) => !i.finished)) {
        if (item.photoRequired) {
          await expectLater(repo.recordChecklistItem(lead, changeFor(opening, item, done: true)), throwsA(isA<AppFailure>()));
          await repo.recordChecklistItem(lead, changeFor(opening, item, done: true), photos: [photo]);
        } else {
          await repo.recordChecklistItem(lead, changeFor(opening, item, done: true, note: 'ok'));
        }
      }
      final done = (await repo.loadEventChecklists(lead, data.eventId)).runs.firstWhere((r) => r.id == opening.id);
      expect(done.status, ChecklistStatus.complete);
      await expectLater(repo.signOffChecklist(done.id), throwsA(isA<AppFailure>()), reason: 'leads do not sign off');

      // The manager signs off; then it is locked until reopened with a reason.
      final (_, manager) = await signIn('200002', repo);
      final signed = await repo.signOffChecklist(done.id, note: 'Looks good');
      expect(signed.status, ChecklistStatus.signedOff);
      expect(signed.signedOffByName, manager.displayName);
      await expectLater(repo.recordChecklistItem(manager, changeFor(signed, signed.items.first, done: false)), throwsA(isA<AppFailure>()));
      await expectLater(repo.reopenChecklist(done.id, ' '), throwsA(isA<AppFailure>()));
      final reopened = await repo.reopenChecklist(done.id, 'Bartender swapped in');
      expect(reopened.status, ChecklistStatus.complete);
      expect(reopened.reopenReason, 'Bartender swapped in');
    });

    test('a resent change is stored once, and an older change does not undo a newer one', () async {
      final (repo, s) = await signIn('200002');
      final (data, venue) = await load(repo, s);
      final id = data.storefrontIds.first;
      final closing = data.runsAt(id, venue.storefront(id)!.kind).firstWhere((r) => r.templateKind == ChecklistKind.closing);
      final item = closing.items.firstWhere((i) => i.photoRequired);
      final change = changeFor(closing, item, done: true);
      final first = await repo.recordChecklistItem(s, change, photos: [photo]);
      final again = await repo.recordChecklistItem(s, change, photos: [photo]);
      expect(again.items.firstWhere((i) => i.templateItemId == item.templateItemId).photoPaths, hasLength(1));
      expect(again.id, first.id, reason: 'one run');

      final plain = closing.items.firstWhere((i) => !i.photoRequired);
      await repo.recordChecklistItem(s, changeFor(first, plain, done: true, at: DateTime.now().toUtc()));
      final stale = await repo.recordChecklistItem(s, changeFor(first, plain, done: false, at: DateTime.now().toUtc().subtract(const Duration(minutes: 5))));
      expect(stale.items.firstWhere((i) => i.templateItemId == plain.templateItemId).done, isTrue);
    });

    test('employees cannot open checklists', () async {
      final (repo, s) = await signIn('400004');
      await expectLater(repo.loadEventChecklists(s, repo.liveEvent!.id), throwsA(isA<AppFailure>()));
    });

    test('waiting changes show on top of the server data', () {
      const template = ChecklistTemplate(id: 't1', kind: ChecklistKind.opening, name: 'Opening', items: [
        ChecklistTemplateItem(id: 'i1', label: 'Clocked in'),
        ChecklistTemplateItem(id: 'i2', label: 'Uniforms', photoRequired: true),
        ChecklistTemplateItem(id: 'i3', label: 'TABC', storefrontKinds: ['bar']),
      ]);
      const data = EventChecklists(eventId: 'e1', storefrontIds: ['s1'], templates: [template], runs: []);
      final at = DateTime.utc(2026, 11, 4, 23);
      ChecklistItemChange c(String item) =>
          ChecklistItemChange(id: 'c-$item', eventId: 'e1', storefrontId: 's1', templateId: 't1', templateItemId: item, done: true, occurredAt: at);
      final view = withPendingChanges(data, [PendingChecklistChange(c('i1'), 0)], kinds: {'s1': StorefrontKind.permanentStand}, byName: 'Lee');
      final run = view.runsAt('s1', StorefrontKind.permanentStand).single;
      expect(run.items, hasLength(2), reason: 'TABC is for bars only');
      expect(run.status, ChecklistStatus.inProgress);
      expect(run.hasPending, isTrue);
      expect(run.items.first.doneByName, 'Lee');
      final both = withPendingChanges(data, [PendingChecklistChange(c('i1'), 0), PendingChecklistChange(c('i2'), 1)], kinds: {'s1': StorefrontKind.permanentStand});
      expect(both.runsAt('s1', StorefrontKind.permanentStand).single.status, ChecklistStatus.complete, reason: 'a waiting photo counts');
      expect(both.runsAt('s1', StorefrontKind.bar).single.items, hasLength(2), reason: 'the started run keeps its items');
    });
  });

  group('incidents', () {
    test('who sees what: employees none, leads their storefront, staff managers employee incidents', () async {
      final (repo, employee) = await signIn('400004');
      await expectLater(repo.listIncidents(employee), throwsA(isA<AppFailure>()));
      final (_, manager) = await signIn('200002', repo);
      final all = await repo.listIncidents(manager);
      expect(all.map((i) => i.kind), containsAll(IncidentKind.values.toSet()..remove(IncidentKind.injury)));
      expect(all.any((i) => i.kind == IncidentKind.employee), isTrue);
      expect(all.any((i) => i.photoPaths.isNotEmpty), isTrue);
      final (_, lead) = await signIn('300003', repo);
      final mine = lead.grants.firstWhere((g) => g.scopeType == 'storefront').scopeId;
      final seen = await repo.listIncidents(lead);
      expect(seen, isNotEmpty);
      expect(seen.every((i) => i.storefrontId == mine || i.reportedBy == lead.userId), isTrue);
      expect(seen.any((i) => i.kind == IncidentKind.employee), isFalse);
    });

    test('a lead logs for their storefront only; a resend is stored once; managers are alerted on injuries', () async {
      final (repo, lead) = await signIn('300003');
      final mine = lead.grants.firstWhere((g) => g.scopeType == 'storefront').scopeId!;
      final venue = await repo.loadVenue(lead);
      final other = venue.storefronts.firstWhere((f) => f.id != mine).id;
      IncidentDraft draft(String? sf) => IncidentDraft(id: uid(), venueId: lead.venue.id, kind: IncidentKind.injury, severity: IncidentSeverity.medium,
          occurredAt: DateTime.now().toUtc(), description: 'Slipped on ice, bruised knee', storefrontId: sf, eventId: repo.liveEvent?.id);
      await expectLater(repo.logIncident(lead, draft(other)), throwsA(isA<AppFailure>()));
      await expectLater(repo.logIncident(lead, draft(null)), throwsA(isA<AppFailure>()));
      final d = draft(mine);
      final before = (await repo.listIncidents(lead)).length;
      await repo.logIncident(lead, d, photos: [photo]);
      final again = await repo.logIncident(lead, d, photos: [photo]);
      expect(again.photoPaths, hasLength(1));
      expect((await repo.listIncidents(lead)).length, before + 1);

      final (_, manager) = await signIn('200002', repo);
      final alerts = await repo.myNotifications(manager);
      expect(alerts.where((n) => n.kind == 'incident'), isNotEmpty);
      expect(alerts.firstWhere((n) => n.kind == 'incident').body, isNot(contains('knee')), reason: 'no details on a lock screen');
    });

    test('follow-up: notes, owner, closing needs a note, closed takes no notes', () async {
      final (repo, manager) = await signIn('200002');
      final open = (await repo.listIncidents(manager)).firstWhere((i) => i.status != IncidentStatus.closed && i.kind != IncidentKind.employee);
      final note = IncidentNoteDraft(id: uid(), incidentId: open.id, body: 'Called HR', createdAt: DateTime.now().toUtc());
      await repo.addIncidentNote(manager, note);
      final withNote = await repo.addIncidentNote(manager, note);
      expect(withNote.notes.where((n) => n.id == note.id), hasLength(1));
      final owners = await repo.incidentAssignees(manager, open.kind);
      final owned = await repo.updateIncident(open.id, assignedTo: owners.first.userId);
      expect(owned.assignedToName, owners.first.name);
      await expectLater(repo.updateIncident(open.id, status: IncidentStatus.closed, closingNote: ' '), throwsA(isA<AppFailure>()));
      final closed = await repo.updateIncident(open.id, status: IncidentStatus.closed, closingNote: 'Reported to HR');
      expect(closed.status, IncidentStatus.closed);
      await expectLater(repo.addIncidentNote(manager, IncidentNoteDraft(id: uid(), incidentId: open.id, body: 'x', createdAt: DateTime.now().toUtc())),
          throwsA(isA<AppFailure>()));
      final (_, lead) = await signIn('300003', repo);
      final leadsOwn = (await repo.listIncidents(lead)).first;
      await expectLater(repo.updateIncident(leadsOwn.id, status: IncidentStatus.closed, closingNote: 'x'), throwsA(isA<AppFailure>()), reason: 'leads add notes, managers close');
    });

    test('CSV export has one row per incident, times at the venue', () async {
      final (repo, manager) = await signIn('200002');
      final venue = await repo.loadVenue(manager);
      final list = await repo.listIncidents(manager);
      final csv = incidentsCsv(list, venue);
      expect(csv.split('\r\n').where((l) => l.isNotEmpty).length, greaterThanOrEqualTo(list.length + 1));
      expect(csv, startsWith('Occurred,Kind,Severity,Status'));
    });

    test('waiting reports and notes show in the list', () {
      final d = IncidentDraft(id: 'x1', venueId: 'v', kind: IncidentKind.safety, severity: IncidentSeverity.low, occurredAt: DateTime.utc(2026, 11, 4), description: 'Wet floor');
      final list = withPendingIncidents(const [], drafts: [(d, 2)], notes: [IncidentNoteDraft(id: 'n1', incidentId: 'x1', body: 'Mopped', createdAt: DateTime.utc(2026, 11, 4, 1))]);
      expect(list.single.pending, isTrue);
      expect(list.single.pendingPhotos, 2);
      expect(list.single.notes.single.pending, isTrue);
    });
  });

  group('offline queue', () {
    test('ticks and reports made with no signal send later, once', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = FlakyRepo(now: now);
      final container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      await container.read(sessionProvider.notifier).signIn('300003');
      final lead = container.read(sessionProvider)!;
      final queue = container.read(opsQueueProvider.notifier);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final venue = await repo.loadVenue(lead);
      final data = await repo.loadEventChecklists(lead, repo.liveEvent!.id);
      final sf = data.storefrontIds.single;
      final closing = data.runsAt(sf, venue.storefront(sf)!.kind).firstWhere((r) => r.templateKind == ChecklistKind.closing);
      final item = closing.items.firstWhere((i) => i.photoRequired);

      repo.offline = true;
      final change = changeFor(closing, item, done: true);
      expect(await queue.recordChecklistItem(change, photos: [photo]), isFalse, reason: 'saved, waiting for signal');
      final incident = IncidentDraft(id: uid(), venueId: lead.venue.id, kind: IncidentKind.safety, severity: IncidentSeverity.low,
          occurredAt: DateTime.now().toUtc(), description: 'Cord across the walkway', storefrontId: sf);
      expect(await queue.logIncident(incident), isFalse);
      expect(container.read(opsQueueProvider).pending, 2);
      final view = withPendingChanges(data, queue.pendingChecklistChanges(), kinds: {sf: venue.storefront(sf)!.kind});
      expect(view.runsAt(sf, venue.storefront(sf)!.kind).firstWhere((r) => r.templateId == closing.templateId).items.firstWhere((i) => i.templateItemId == item.templateItemId).pending, isTrue);
      await queue.flush();
      expect(container.read(opsQueueProvider).pending, 2, reason: 'still no signal');

      // Signal returns, but the first answer is lost after the server stored it.
      repo.offline = false;
      repo.loseAnswer = true;
      await queue.flush();
      expect(container.read(opsQueueProvider).pending, 2, reason: 'a lost answer counts as no signal; the queue stops there');
      await queue.flush();
      expect(container.read(opsQueueProvider).pending, 0);

      final after = await repo.loadEventChecklists(lead, data.eventId);
      final stored = after.runs.firstWhere((r) => r.templateId == closing.templateId && r.storefrontId == sf).items.firstWhere((i) => i.templateItemId == item.templateItemId);
      expect(stored.done, isTrue);
      expect(stored.photoPaths, hasLength(1), reason: 'sent twice, stored once');
      expect((await repo.listIncidents(lead)).where((i) => i.id == incident.id), hasLength(1));
    });

    test('a refused change is set aside, not retried forever', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = FlakyRepo(now: now);
      final container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo)]);
      addTearDown(container.dispose);
      await container.read(sessionProvider.notifier).signIn('300003');
      final lead = container.read(sessionProvider)!;
      final queue = container.read(opsQueueProvider.notifier);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final data = await repo.loadEventChecklists(lead, repo.liveEvent!.id);
      final template = data.templates.first;
      final venue = await repo.loadVenue(lead);
      final other = venue.storefronts.firstWhere((f) => f.id != data.storefrontIds.single);
      await expectLater(
        queue.recordChecklistItem(ChecklistItemChange(id: uid(), eventId: data.eventId, storefrontId: other.id, templateId: template.id,
            templateItemId: template.items.first.id, done: true, occurredAt: DateTime.now().toUtc())),
        throwsA(isA<AppFailure>()),
      );
      expect(container.read(opsQueueProvider).needsReview, 1);
      expect(container.read(opsQueueProvider).pending, 0);
      final calls = repo.calls;
      await queue.flush();
      expect(repo.calls, calls);
      await queue.discard(queue.refused().single.id);
      expect(container.read(opsQueueProvider).needsReview, 0);
    });
  });
}
