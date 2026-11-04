import 'package:flutter_test/flutter_test.dart';
import 'package:storefront_workforce/data/demo_repository.dart';
import 'package:storefront_workforce/data/models.dart';
import 'package:storefront_workforce/features/live/live_model.dart';
import 'package:storefront_workforce/features/schedule/assignment_checks.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4, 1, 42);

  Future<(DemoWorkforceRepository, EventBoard)> managerBoard() async {
    final repo = DemoWorkforceRepository(now: now);
    await repo.signInWithPin('200002');
    final board = await repo.loadBoard(repo.liveEvent!.id);
    return (repo, board);
  }

  test('manager sees every open storefront; lead sees only theirs', () async {
    final (repo, board) = await managerBoard();
    expect(board.storefrontIds.length, 40);
    await repo.signOut();
    await repo.signInWithPin('300003');
    final lead = await repo.loadBoard(repo.liveEvent!.id);
    expect(lead.storefrontIds.length, 1);
    expect(lead.shifts.every((s) => s.storefrontId == lead.storefrontIds.single), isTrue);
  });

  test('a minor cannot be put in a bartender position', () async {
    final (repo, board) = await managerBoard();
    final venue = await repo.loadVenue((await repo.restoreSession())!);
    final bartender = venue.jobRole('bartender')!;
    final shift = board.shifts.firstWhere((s) => s.jobRoleCode == 'bartender');
    final minor = BoardWorker(
      worker: Worker(id: 'w', venueId: venue.venue.id, type: WorkerType.regular, employeeNumber: 'E9', firstName: 'A', lastName: 'B', jobRoles: const ['bartender']),
      ageOnEvent: 16,
    );
    final check = checkAssignment(
      candidate: minor,
      role: bartender,
      event: board.event,
      shift: shift,
      rules: venue.rules,
      timeZone: board.timeZone,
      certName: venue.certName,
    );
    expect(check.blocks.map((b) => b.code), contains('minimum_age'));
  });

  test('assigning, moving, and sending home are logged in order', () async {
    final (repo, board) = await managerBoard();
    final eventId = board.event.id;
    final open = board.shifts.firstWhere((s) => s.isOpen && s.jobRoleCode == 'cashier', orElse: () => board.shifts.firstWhere((s) => s.isOpen));
    final candidates = await repo.candidates(eventId, open.jobRoleCode);
    final adult = candidates.firstWhere((c) => (c.ageOnEvent ?? 30) >= 18 && c.worker.certifications.isNotEmpty || open.jobRoleCode == 'cashier');
    await repo.assign(open.id, adult.id);

    var b = await repo.loadBoard(eventId);
    expect(b.shifts.firstWhere((s) => s.id == open.id).workerId, adult.id);

    // Move someone who is working to a different storefront.
    final working = b.shifts.firstWhere((s) => s.status == ShiftStatus.assigned && s.storefrontId != open.storefrontId && s.jobRoleCode == 'cashier');
    final dest = b.openStorefrontIds.firstWhere((id) => id != working.storefrontId);
    await repo.move(working.id, dest, reason: 'Long line');
    b = await repo.loadBoard(eventId);
    expect(b.shifts.any((s) => s.workerId == working.workerId && s.storefrontId == dest), isTrue);

    // Two releases get consecutive numbers after the ones already made.
    final before = b.shifts.fold<int>(0, (m, s) => (s.releaseOrder ?? 0) > m ? s.releaseOrder! : m);
    final toRelease = b.shifts.where((s) => s.status == ShiftStatus.assigned).take(2).toList();
    for (final s in toRelease) {
      await repo.release(s.id, 'Slow stand');
    }
    b = await repo.loadBoard(eventId);
    expect([for (final s in toRelease) b.shifts.firstWhere((x) => x.id == s.id).releaseOrder], [before + 1, before + 2]);
    expect(b.changes.map((c) => c.action).toList().reversed.toList(), ['assigned', 'moved', 'released', 'released']);
  });

  test('a punch sent twice is stored once', () async {
    final repo = DemoWorkforceRepository(now: now);
    final session = await repo.signInWithPin('400004');
    final day = await repo.loadMyDay(session);
    final draft = PunchDraft(id: 'aaaaaaaa-0000-4000-8000-000000000001', kind: PunchKind.clockIn, occurredAt: now, eventId: day.current!.event.id);
    await repo.sendPunch(session, draft);
    await repo.sendPunch(session, draft);
    final after = await repo.loadMyDay(session);
    expect(after.punches.where((p) => p.id == draft.id).length, 1);
  });

  test('live summary colors: missing or open is red', () async {
    final (repo, board) = await managerBoard();
    final venue = await repo.loadVenue((await repo.restoreSession())!);
    final cards = evaluateBoard(board, venue.rules, now);
    final summaries = summarizeByStorefront(board, cards);
    for (final s in summaries.values.where((s) => s.isOpen)) {
      if (s.missing > 0 || s.openPositions > 0) expect(s.tone.name, 'bad');
    }
    expect(summaries.values.where((s) => !s.isOpen).every((s) => s.tone.name == 'idle'), isTrue);
  });

  test('early-release suggestions put temps before regular staff', () async {
    final (repo, board) = await managerBoard();
    final venue = await repo.loadVenue((await repo.restoreSession())!);
    final cards = evaluateBoard(board, venue.rules, now);
    final order = releaseSuggestions(cards, board, venue.rules);
    final types = [for (final c in order) board.workers[c.shift.workerId]!.worker.type];
    final firstRegular = types.indexOf(WorkerType.regular);
    final lastTemp = types.lastIndexOf(WorkerType.temp);
    if (firstRegular >= 0 && lastTemp >= 0) expect(lastTemp, lessThan(firstRegular));
  });
}
