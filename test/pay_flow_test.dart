import 'package:flutter_test/flutter_test.dart';
import 'package:storefront_workforce/data/demo_repository.dart';
import 'package:storefront_workforce/data/models.dart';
import 'package:storefront_workforce/features/pay/pay_logic.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4, 1, 42);

  Future<(DemoWorkforceRepository, AppSession, VenueContext)> signIn(String pin) async {
    final repo = DemoWorkforceRepository(now: now);
    final session = await repo.signInWithPin(pin);
    return (repo, session, await repo.loadVenue(session));
  }

  test('a period with tips approves, and the entry sheet totals equal the approved lines', () async {
    final (repo, session, venue) = await signIn('200002');
    await repo.ensurePayPeriods(session, now);
    final setup = await repo.loadPaySetup(session);
    final period = setup.periods.firstWhere((p) => p.startsOn == DateTime.utc(2026, 10, 12));
    var data = await repo.loadPeriodData(session, period);

    final unsplit = unsplitPools(data, venue.venue.timeZone);
    expect(unsplit, isNotEmpty, reason: 'sample bars have tips to split');
    for (final t in unsplit) {
      final split = computeTipSplit(t, data, venue);
      expect(split.distributedCents, t.amountCents, reason: 'every cent of a pool reaches someone');
      await repo.saveTipPool(t, split.allocations);
    }
    data = await repo.loadPeriodData(session, period);
    expect(unsplitPools(data, venue.venue.timeZone), isEmpty);

    final result = computeEarnings(data, setup, venue);
    expect(result.hasBlockingProblems, isFalse, reason: '${result.problems.map((p) => p.message).toList()}');
    final tips = result.lines.where((l) => l.payCode == PayCodes.tips).fold(0, (s, l) => s + l.amountCents);
    final pooled = unsplit.fold(0, (s, t) => s + t.amountCents);
    expect(tips, pooled, reason: 'tips on payroll equal the pools split this period');

    await repo.approvePayPeriod(period, result.lines, setup.rulesVersion);
    data = await repo.loadPeriodData(session, (await repo.loadPaySetup(session)).periods.firstWhere((p) => p.id == period.id));
    expect(data.isOpen, isFalse);
    final sheet = const PaycomExporter().entrySheet(period: data.period, lines: data.approvedLines, workers: data.workers, payCodes: setup.payCodes);
    expect(sheet.totals.grossCents, data.approvedLines.fold(0, (s, l) => s + l.amountCents));
    expect(sheet.rows.every((r) => !r.missingEmployeeCode), isTrue, reason: 'sample regular staff all have Paycom codes');

    final csv = const PaycomExporter().csv(period: data.period, lines: data.approvedLines, workers: data.workers, payCodes: setup.payCodes);
    expect(csv.totalAmountCents, sheet.totals.grossCents);
    await repo.recordExport(data.period, format: 'import_csv', fileName: 'x.csv', rows: csv.rowCount, hours: '0', amount: '0', sha256: 'x');
    final after = (await repo.loadPaySetup(session)).periods.firstWhere((p) => p.id == period.id);
    expect(after.status, 'exported');
  });

  test('a time correction needs a second manager and blocks approval until decided', () async {
    final (repo, session, venue) = await signIn('200002');
    await repo.ensurePayPeriods(session, now);
    final setup = await repo.loadPaySetup(session);
    final period = setup.periods.firstWhere((p) => p.startsOn == DateTime.utc(2026, 10, 12));
    final data = await repo.loadPeriodData(session, period);
    final punch = data.punches.firstWhere((p) => p.kind == PunchKind.clockOut && data.workers[p.workerId]!.type == WorkerType.regular);

    await repo.requestCorrection({
      'worker_id': punch.workerId,
      'event_id': punch.eventId,
      'action': 'replace',
      'punch_id': punch.id,
      'new_occurred_at': punch.occurredAt.add(const Duration(minutes: 30)).toIso8601String(),
      'reason': 'Forgot to clock out at the end of cleanup',
    });
    final pending = (await repo.loadPeriodData(session, period)).pendingCorrections.single;
    expect(() => repo.decideCorrection(pending.id, approve: true), throwsA(isA<AppFailure>()), reason: 'cannot approve your own');
    expect(() => repo.approvePayPeriod(period, const [], 1), throwsA(isA<AppFailure>()));

    await repo.signOut();
    await repo.signInWithPin('100001'); // admin
    await repo.decideCorrection(pending.id, approve: true);
    final after = await repo.loadPeriodData(session, period);
    expect(after.punches.firstWhere((p) => p.id == punch.id).status, PunchStatus.voided, reason: 'the original is kept, voided');
    expect(after.punches.any((p) => p.source == PunchSource.manager && p.occurredAt == punch.occurredAt.add(const Duration(minutes: 30))), isTrue);
  });

  test('NPO payouts go pending → approved → paid, and temps are billed, not paid', () async {
    final (repo, session, venue) = await signIn('200002');
    await repo.ensurePayPeriods(session, now);
    final setup = await repo.loadPaySetup(session);
    final period = setup.periods.firstWhere((p) => p.startsOn == DateTime.utc(2026, 10, 12));
    final partners = await repo.loadPartnerData(session, period.startsOn, period.endsOn);
    final group = venue.npoGroups.first;
    final event = partners.events.values.firstWhere((e) =>
        partners.shifts.any((s) => s.eventId == e.id && partners.workers[s.workerId]?.npoGroupId == group.id));
    final calc = computeNpoPayout(partners, setup, venue, event, group.id);
    expect(calc.payout.totalCents, greaterThan(0));
    expect(calc.payout.totalCents, calc.payout.grossCents - calc.payout.deductionsCents);

    await repo.saveNpoPayout(calc.payout);
    var saved = (await repo.loadPartnerData(session, period.startsOn, period.endsOn)).payouts.single;
    await repo.setNpoPayoutStatus(saved.id!, 'approved');
    await repo.setNpoPayoutStatus(saved.id!, 'paid', reference: 'CHK 1042');
    saved = (await repo.loadPartnerData(session, period.startsOn, period.endsOn)).payouts.single;
    expect(saved.status, 'paid');
    expect(saved.paymentReference, 'CHK 1042');
    expect(() => repo.saveNpoPayout(calc.payout), throwsA(isA<AppFailure>()), reason: 'a paid payout cannot be recalculated over');

    final billing = computeAgencyBilling(partners, setup, venue, period.startsOn, period.endsOn);
    expect(billing.invoices, isNotEmpty);
    expect(billing.lines.every((l) => partners.workers[l.workerId]!.type == WorkerType.temp), isTrue);
  });
}
