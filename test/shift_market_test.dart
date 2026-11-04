import 'package:flutter_test/flutter_test.dart';
import 'package:storefront_workforce/data/demo_repository.dart';
import 'package:storefront_workforce/data/models.dart';
import 'package:storefront_workforce/data/shift_market_repository.dart';
import 'package:storefront_workforce/features/shift_market/request_checks.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4, 1, 42);

  Future<(DemoWorkforceRepository, AppSession)> signIn(String pin, [DemoWorkforceRepository? existing]) async {
    final repo = existing ?? DemoWorkforceRepository(now: now);
    if (existing != null) await repo.signOut();
    final session = await repo.signInWithPin(pin);
    return (repo, session);
  }

  test('an employee sees only open shifts they are trained for, at events they do not work', () async {
    final (repo, session) = await signIn('400004');
    final open = await repo.openShiftsForMe();
    expect(open, isNotEmpty);
    final me = (await repo.listWorkers(session)).single;
    expect(open.every((o) => me.jobRoles.contains(o.shift.jobRoleCode)), isTrue);
    expect(open.every((o) => o.shift.isOpen && o.shift.callTime.isAfter(now)), isTrue);
    final day = await repo.loadMyDay(session);
    final myEvents = {for (final s in day.shifts) s.event.id};
    expect(open.any((o) => myEvents.contains(o.event.id)), isFalse);
  });

  test('a pickup waits for a manager; approval assigns it and is logged', () async {
    final (repo, session) = await signIn('400004');
    final pick = (await repo.openShiftsForMe()).firstWhere((o) => o.blocked == null);
    final request = await repo.requestPickup(pick.shift.id, note: 'Can stay late');
    expect(request.status, ShiftRequestStatus.pending);
    await expectLater(repo.requestPickup(pick.shift.id), throwsA(isA<AppFailure>()), reason: 'asking twice is refused');
    expect((await repo.openShiftsForMe()).firstWhere((o) => o.shift.id == pick.shift.id).myRequestId, request.id);

    await signIn('200002', repo);
    final queue = await repo.reviewShiftRequests();
    final mine = queue.firstWhere((r) => r.id == request.id);
    expect(mine.requester?.ageOnEvent, isNotNull, reason: 'the queue has what the rules engine needs');
    await repo.decideShiftRequest(request.id, approve: true, note: 'Good fit');
    final board = await repo.loadBoard(pick.event.id);
    expect(board.shifts.firstWhere((s) => s.id == pick.shift.id).workerId, session.workerId);
    expect(board.changes.first.reason, 'Pickup approved: Good fit');
    await expectLater(repo.decideShiftRequest(request.id, approve: false), throwsA(isA<AppFailure>()), reason: 'decided once');

    await signIn('400004', repo);
    final mineAfter = await repo.myShiftRequests();
    expect(mineAfter.firstWhere((r) => r.id == request.id).status, ShiftRequestStatus.approved);
  });

  test('a drop inside the cutoff is refused; outside it, approval opens the shift', () async {
    final (repo, _) = await signIn('200002');
    final live = await repo.loadBoard(repo.liveEvent!.id);
    final (_, session) = await signIn('400004', repo);
    final current = live.shifts.firstWhere((s) => s.workerId == session.workerId);
    await expectLater(repo.requestDrop(current.id, reason: 'Sick'), throwsA(isA<AppFailure>()), reason: 'the live shift is inside the cutoff');
    final day = await repo.loadMyDay(session);
    final later = day.shifts.firstWhere((s) => s.shift.callTime.isAfter(now.add(const Duration(days: 2))));
    await repo.requestDrop(later.shift.id, reason: 'Exam');
    await expectLater(repo.requestDrop(later.shift.id, reason: 'Exam'), throwsA(isA<AppFailure>()));

    await signIn('200002', repo);
    final drop = (await repo.reviewShiftRequests()).firstWhere((r) => r.kind == ShiftRequestKind.drop && r.shift.id == later.shift.id);
    await repo.decideShiftRequest(drop.id, approve: true);
    final board = await repo.loadBoard(later.event.id);
    expect(board.shifts.firstWhere((s) => s.id == later.shift.id).isOpen, isTrue);
    expect(board.changes.first.action, 'unassigned');
    expect(board.changes.first.reason, contains('Exam'));
  });

  test('a swap offer: only the coworker can accept, then a manager approves and the shift moves', () async {
    final (repo, session) = await signIn('400004');
    final offer = (await repo.myShiftRequests()).firstWhere((r) => r.status == ShiftRequestStatus.offered && r.targetWorkerId == session.workerId);

    await signIn('400005', repo);
    await expectLater(repo.respondSwap(offer.id, accept: true), throwsA(isA<AppFailure>()), reason: 'not their offer');
    await signIn('200002', repo);
    await expectLater(repo.decideShiftRequest(offer.id, approve: true), throwsA(isA<AppFailure>()), reason: 'the coworker has not accepted');

    await signIn('400004', repo);
    await repo.respondSwap(offer.id, accept: true);
    await signIn('200002', repo);
    final pending = (await repo.reviewShiftRequests()).firstWhere((r) => r.id == offer.id);
    expect(pending.status, ShiftRequestStatus.pending);
    expect(pending.incoming?.id, session.workerId);
    await repo.decideShiftRequest(offer.id, approve: true);
    final board = await repo.loadBoard(offer.event.id);
    expect(board.shifts.firstWhere((s) => s.id == offer.shift.id).workerId, session.workerId);
    expect(board.changes.take(2).map((c) => c.action).toList(), ['assigned', 'unassigned']);
  });

  test('an employee offers a shift to a coworker, who can decline', () async {
    final (repo, session) = await signIn('400004');
    final day = await repo.loadMyDay(session);
    final later = day.shifts.firstWhere((s) => s.shift.callTime.isAfter(now.add(const Duration(days: 2))));
    final candidates = await repo.swapCandidates(later.shift.id);
    expect(candidates, isNotEmpty);
    expect(candidates.any((c) => c.id == session.workerId), isFalse);
    final spanish = (await repo.signInWithPin('400005')).workerId!;
    await signIn('400004', repo);
    final target = candidates.firstWhere((c) => c.id == spanish, orElse: () => candidates.first);
    await repo.offerSwap(later.shift.id, target.id, note: 'Please?');
    final mine = (await repo.myShiftRequests()).firstWhere((r) => r.kind == ShiftRequestKind.swap && r.requesterWorkerId == session.workerId);
    expect(mine.status, ShiftRequestStatus.offered);
    await repo.cancelShiftRequest(mine.id);
    expect((await repo.myShiftRequests()).firstWhere((r) => r.id == mine.id).status, ShiftRequestStatus.cancelled);
  });

  test('a lead decides only requests at their own storefront', () async {
    final (repo, lead) = await signIn('300003');
    final store = lead.grants.firstWhere((g) => g.scopeType == 'storefront').scopeId;
    final mine = await repo.reviewShiftRequests();
    expect(mine.every((r) => r.shift.storefrontId == store), isTrue);
    await signIn('200002', repo);
    final outside = (await repo.reviewShiftRequests()).where((r) => r.shift.storefrontId != store && r.status == ShiftRequestStatus.pending).first;
    await signIn('300003', repo);
    await expectLater(repo.decideShiftRequest(outside.id, approve: true), throwsA(isA<AppFailure>()));
  });

  test('the rules engine flags a minor in the queue', () async {
    final (repo, session) = await signIn('200002');
    final venue = await repo.loadVenue(session);
    final queue = await repo.reviewShiftRequests();
    final minor = queue.firstWhere((r) => r.kind == ShiftRequestKind.pickup && (r.requester?.ageOnEvent ?? 99) < 18);
    final check = requestCheck(minor, venue);
    expect(check.warnings, isNotEmpty, reason: 'minor hour or time limits');
    await expectLater(repo.decideShiftRequest(minor.id, approve: true, warnings: check.warningCodes), throwsA(isA<AppFailure>()),
        reason: 'accepting warnings needs a note');
  });

  test('availability and blackouts reach the assign sheet, available people first', () async {
    final (repo, session) = await signIn('400004');
    final mine = await repo.myAvailability();
    expect(mine.events, isNotEmpty);
    expect(mine.blackouts, hasLength(1));
    final target = mine.events.firstWhere((e) => !e.scheduled);
    await repo.setEventAvailability(target.event.id, AvailabilityStatus.unavailable, note: 'Exam');
    final added = await repo.setBlackout(DateTime.utc(2026, 12, 20), DateTime.utc(2026, 12, 22), note: 'Trip');
    await expectLater(repo.setBlackout(DateTime.utc(2026, 12, 22), DateTime.utc(2026, 12, 20)), throwsA(isA<AppFailure>()));
    expect((await repo.myAvailability()).blackouts, hasLength(2));
    await repo.deleteBlackout(added.id);
    expect((await repo.myAvailability()).blackouts, hasLength(1));
    final me = (await repo.listWorkers(session)).single;

    await signIn('200002', repo);
    final list = await repo.candidatesWithAvailability(target.event.id, me.jobRoles.first);
    final row = list.firstWhere((c) => c.worker.id == me.id);
    expect(row.availability.status, AvailabilityStatus.unavailable);
    expect(row.availability.note, 'Exam');
    expect(list.any((c) => c.availability.status == AvailabilityStatus.available), isTrue);
    final sorted = sortByAvailability(list);
    expect(sorted.first.availability.status, AvailabilityStatus.available);
  });
}
