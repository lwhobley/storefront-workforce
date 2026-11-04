import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:storefront_workforce/data/demo_repository.dart';
import 'package:storefront_workforce/data/models.dart';
import 'package:storefront_workforce/data/people_repository.dart';
import 'package:storefront_workforce/features/people/people_logic.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4, 1, 42);

  Future<(DemoWorkforceRepository, AppSession)> signIn(String pin, [DemoWorkforceRepository? repo]) async {
    final r = repo ?? DemoWorkforceRepository(now: now);
    await r.signOut();
    return (r, await r.signInWithPin(pin));
  }

  group('employee hours and tips', () {
    test('hours per event equal the timeline math, and carry no money', () async {
      final (repo, session) = await signIn('400004');
      final data = await repo.loadMyHours(session, now.subtract(const Duration(days: 130)), now.add(const Duration(days: 1)));
      expect(data.punches, isNotEmpty, reason: 'the sample employee has worked this season');
      expect(data.punches.every((p) => p.workerId == session.workerId), isTrue, reason: 'only their own time records');

      final zone = session.venue.timeZone;
      final breaks = session.rules.breaks;
      final items = hoursByEvent(data, timeZone: zone, breakRules: breaks, now: now);
      for (final item in items) {
        final punches = [for (final p in data.punches) if (p.eventId == item.key && p.status != PunchStatus.voided) p];
        final timeline = WorkTimeline.fromPunches(punches, now: now);
        expect(item.workedMinutes, timeline.workedMinutes, reason: item.event?.name);
        expect(item.breakMinutes, timeline.breakMinutes);
        expect(item.paidMinutes, timeline.paidIntervals(breaks).fold(0, (s, i) => s + i.minutes));
        expect(item.paidMinutes, greaterThanOrEqualTo(item.workedMinutes), reason: 'paid short breaks only add time');
      }

      // Pay periods follow the venue's rule and hold every item dated inside them.
      final today = localDateOf(now, zone);
      final periods = hoursByPayPeriod(items, venueSettings: session.venue.settings, from: today.subtract(const Duration(days: 120)), to: today);
      final expected = generatePayPeriodsFor(
        venueRules: session.rules,
        payRules: PayRules.fromVenueSettings(session.venue.settings),
        from: today.subtract(const Duration(days: 120)),
        to: today,
      );
      expect(periods.map((p) => p.period.startsOn).toList(), expected.reversed.map((p) => p.startsOn).toList());
      final inRange = items.where((i) => !i.date.isBefore(expected.first.startsOn));
      expect(periods.fold(0, (s, p) => s + p.paidMinutes), inRange.fold(0, (s, i) => s + i.paidMinutes));

      // No wages: the pay setup (rates) is refused for an employee.
      expect(() => repo.loadPaySetup(session), throwsA(isA<AppFailure>()));
    });

    test('tips are the person\'s own pool shares', () async {
      final (repo, session) = await signIn('400004');
      final tips = await repo.loadMyTips(session);
      expect(tips.every((t) => t.amountCents >= 0), isTrue);
      final events = {for (final t in tips) t.eventId};
      expect(events.length, tips.length, reason: 'one line per event and stand');
    });
  });

  group('onboarding', () {
    test('a manager reviews a card upload and approving finishes the card step', () async {
      final (repo, manager) = await signIn('200002');
      final overview = await repo.onboardingOverview(manager);
      final summary = OnboardingSummary.of(overview);
      expect(summary.finished / summary.people, greaterThan(0.8), reason: 'most returning staff are done');
      expect(summary.averageDaysToComplete, isNotNull);
      final waiting = overview.firstWhere((s) => s.needsReview);
      final detail = await repo.workerOnboarding(waiting.workerId);
      final cards = detail.step('certifications')!;
      expect(cards.status, StepStatus.submitted);
      expect(cards.pendingCerts, isNotEmpty);
      expect((await repo.workerCertifications(waiting.workerId)).where((c) => !c.verified), isNotEmpty);

      await expectLater(repo.reviewOnboardingStep(waiting.workerId, 'certifications', approve: false), throwsA(isA<AppFailure>()),
          reason: 'sending back needs a note');
      final after = await repo.reviewOnboardingStep(waiting.workerId, 'certifications', approve: true);
      expect(after.step('certifications')!.done, isTrue);
      expect((await repo.workerCertifications(waiting.workerId)).every((c) => c.verified), isTrue);

      // Overdue and percentages.
      final overdue = overview.where((s) => s.overdue);
      expect(overdue, isNotEmpty, reason: 'a new hire started 9 days ago');
      for (final s in overview) {
        expect(s.percent, s.required == 0 ? 100 : (100 * s.done) ~/ s.required);
      }
    });

    test('an employee signs an updated document with their own name', () async {
      final (repo, me) = await signIn('400004');
      var state = await repo.myOnboarding(me);
      final step = state.steps.firstWhere((s) => s.kind == StepKind.document && s.missingDocumentIds.isNotEmpty);
      expect(step.done, isFalse, reason: 'the document was updated after they signed it');
      final doc = step.missingDocumentIds.first;
      final worker = (await repo.listWorkers(me)).single;
      final guardian = step.guardianRequired ? {'guardian_name': 'Pat Guardian'} : const <String, String>{};
      await expectLater(
        repo.submitOnboardingStep(me, step.code, {
          'acknowledgments': [
            {'document_id': doc, 'typed_name': 'Somebody Else', ...guardian},
          ],
        }),
        throwsA(isA<AppFailure>()),
      );
      state = await repo.submitOnboardingStep(me, step.code, {
        'acknowledgments': [
          {'document_id': doc, 'typed_name': '  ${worker.firstName.toUpperCase()}   ${worker.lastName} ', ...guardian},
        ],
      });
      expect(state.step(step.code)!.status, StepStatus.complete);
      expect(state.step(step.code)!.acknowledgments.last['at'], isNotNull, reason: 'signed with a time');
      await expectLater(repo.submitOnboardingStep(me, 'training', const {'items': ['cash_handling']}), throwsA(isA<AppFailure>()),
          reason: 'a trainer ticks training');
      await expectLater(repo.onboardingOverview(me), throwsA(isA<AppFailure>()), reason: 'employees see only their own');
      await expectLater(repo.workerOnboarding(worker.id), throwsA(isA<AppFailure>()));
    });

    test('the application changes only the contact fields', () async {
      final (repo, me) = await signIn('400005');
      final worker = (await repo.listWorkers(me)).single;
      expect(worker.type, WorkerType.regular);
      await expectLater(repo.submitOnboardingStep(me, 'paycom', const {}), throwsA(isA<AppFailure>()), reason: 'a manager marks Paycom');
      await expectLater(
        repo.submitOnboardingStep(me, 'application', const {'phone': '', 'emergency_contact_name': 'A', 'emergency_contact_phone': '1'}),
        throwsA(isA<AppFailure>()),
        reason: 'a phone is required',
      );
      final state = await repo.submitOnboardingStep(me, 'application', {
        'address': '12 Elm St',
        'phone': '(512) 555-0000',
        'emergency_contact_name': 'Pat Doe',
        'emergency_contact_phone': '(512) 555-0001',
        'uniform_size': 'L',
        'preferred_language': 'en',
        'paycom_employee_code': 'HACKED',
        'worker_type': 'temp',
        'hourly_rate': '99',
      });
      expect(state.step('application')!.status, StepStatus.complete);
      expect(state.step('application')!.data.keys, isNot(contains('paycom_employee_code')));
      expect(state.step('application')!.data.keys, isNot(contains('hourly_rate')));
      final updated = (await repo.listWorkers(me)).single;
      expect(updated.phone, '(512) 555-0000');
      expect(updated.uniformSize, 'L');
      expect(updated.preferredLanguage, 'en');
      expect(updated.paycomEmployeeCode, worker.paycomEmployeeCode);
      expect(updated.type, worker.type);
      expect(updated.jobRoles, worker.jobRoles);
    });

    test('a new hire is added, gets a PIN, uploads a card, and a manager sends it back', () async {
      final (repo, manager) = await signIn('200002');
      final venue = await repo.loadVenue(manager);
      final all = await repo.listWorkers(manager);
      final number = suggestEmployeeNumber(WorkerType.regular, all.map((w) => w.employeeNumber));
      expect(all.any((w) => w.employeeNumber == number), isFalse);
      final w = await repo.addWorker(
        manager,
        NewPerson(type: WorkerType.regular, employeeNumber: number, firstName: 'Nina', lastName: 'Cole', dateOfBirth: DateTime.utc(2000, 2, 2), jobRoles: const ['bartender']),
      );
      await expectLater(
        repo.addWorker(manager, NewPerson(type: WorkerType.regular, employeeNumber: number, firstName: 'X', lastName: 'Y')),
        throwsA(isA<AppFailure>()),
        reason: 'employee numbers are unique',
      );
      var state = await repo.workerOnboarding(w.id);
      expect(state.percent, 0);
      expect(state.steps.map((s) => s.code), ['application', 'policies', 'certifications', 'training', 'paycom']);
      expect(state.step('certifications')!.missingCerts, ['tabc']);
      expect(state.step('training')!.items.map((i) => i.code), contains('alcohol_service'));

      final pin = await repo.issuePin(manager, w);
      final (_, nina) = await signIn(pin, repo);
      expect(nina.workerId, w.id);
      final path = await repo.uploadOnboardingFile(nina, 'tabc.jpg', Uint8List.fromList([1, 2, 3]));
      await expectLater(
        repo.submitOnboardingStep(nina, 'certifications', {
          'certs': [
            {'cert_type_code': 'tabc', 'file_path': 'someone/else/x.jpg'},
          ],
        }, files: ['someone/else/x.jpg']),
        throwsA(isA<AppFailure>()),
        reason: 'uploads only to your own folder',
      );
      state = await repo.submitOnboardingStep(nina, 'certifications', {
        'certs': [
          {'cert_type_code': 'tabc', 'number': 'TABC-1', 'expires_on': '2028-01-31', 'file_path': path},
        ],
      }, files: [path]);
      expect(state.step('certifications')!.status, StepStatus.submitted);
      expect((await repo.workerCertifications(w.id)).single.verified, isFalse, reason: 'an upload is unverified');
      expect(await repo.downloadOnboardingFile(path), [1, 2, 3]);

      await signIn('200002', repo);
      final back = await repo.reviewOnboardingStep(w.id, 'certifications', approve: false, note: 'Photo is blurry');
      expect(back.step('certifications')!.status, StepStatus.needsChanges);
      expect(back.step('certifications')!.note, 'Photo is blurry');
      expect(await repo.workerCertifications(w.id), isEmpty, reason: 'the sent-back card is removed');

      // Training and Paycom are ticked by a manager.
      state = await repo.completeOnboardingStep(w.id, 'training', {'items': ['cash_handling', 'food_safety']});
      expect(state.step('training')!.done, isFalse);
      state = await repo.completeOnboardingStep(w.id, 'training', {'items': [for (final i in state.step('training')!.items) i.code]});
      expect(state.step('training')!.done, isTrue);
      await expectLater(repo.completeOnboardingStep(w.id, 'paycom', {'completed_on': '2030-01-01'}), throwsA(isA<AppFailure>()));
      state = await repo.completeOnboardingStep(w.id, 'paycom', {'completed_on': '2026-11-03'});
      expect(state.step('paycom')!.done, isTrue);
      expect(state.done, 2);
      await repo.sendOnboardingReminder(w.id);
      expect(venue.jobRoles, isNotEmpty);
    });
  });

  group('roster import', () {
    test('rows are checked for dates, roles, agencies and repeated numbers', () async {
      final (repo, manager) = await signIn('200002');
      final venue = await repo.loadVenue(manager);
      final all = await repo.listWorkers(manager);
      final existing = all.first;
      final agency = venue.agencies.first;
      final group = venue.npoGroups.first;
      final csv = [
        'Employee Number,First Name,Last Name,Type,Phone,Email,Date of Birth,Roles,Paycom Code,Agency,NPO Group,Hire Date,Shoe size',
        'E9001,Ana,Lopez,regular,555-1,ana@example.com,1999-02-30,cashier,AL1,,,2026-11-01,9', // bad date
        'E9002,Ben,Ray,regular,,,1998-01-01,cashier;juggler,,,,,', // unknown role
        'E9003,Cy,Ng,temp,,,1990-05-05,Cashier,,${agency.name.toUpperCase()},,11/02/2026,', // ok (role by name, US date)
        'E9003,Di,Ng,temp,,,1990-05-05,cashier,,${agency.name},,,', // repeated number
        'T9004,Ed,Fox,temp,,,1990-05-05,cashier,,,,,', // temp without agency
        'N9005,Flo,Kim,npo,,,2011-01-01,runner,,,"${group.displayName}",,', // ok, a minor volunteer
        '${existing.employeeNumber},${existing.firstName},${existing.lastName},${existing.type.code},555-9999,,,${existing.jobRoles.join(';')},,${existing.type == WorkerType.temp ? venue.agencyName(existing.agencyId) : ''},${existing.type == WorkerType.npo ? venue.npoName(existing.npoGroupId) : ''},,',
        'E9006,Gus,Day,regular,,,2020-01-01,cashier,,,,,', // too young
        'E9007,Hal,Ive,boss,,,,cashier,,,,,', // bad type
      ].join('\n');
      final preview = parseRoster(csv, venue: venue, existingNumbers: all.map((w) => w.employeeNumber), today: DateTime.utc(2026, 11, 4));
      String errorsOf(String number) => preview.rows.where((r) => r.cells['employee_number'] == number).map((r) => r.errors.join('; ')).join(' | ');

      expect(preview.problems.single, contains('shoe_size'));
      expect(errorsOf('E9001'), contains('not a date'));
      expect(errorsOf('E9002'), contains('Unknown role "juggler"'));
      expect(preview.rows.where((r) => r.cells['employee_number'] == 'E9003').map((r) => r.valid), [true, false]);
      expect(errorsOf('E9003'), contains('repeated'));
      expect(errorsOf('T9004'), contains('Temps need an agency'));
      expect(errorsOf('E9006'), contains('too young'));
      expect(errorsOf('E9007'), contains('must be regular, temp or npo'));
      final cy = preview.valid.firstWhere((r) => r.cells['employee_number'] == 'E9003').person!;
      expect(cy.agencyId, agency.id);
      expect(cy.jobRoles, ['cashier']);
      expect(cy.hireDate, DateTime.utc(2026, 11, 2));
      expect(preview.valid.firstWhere((r) => r.cells['employee_number'] == 'N9005').person!.npoGroupId, group.id);
      final update = preview.valid.singleWhere((r) => r.isUpdate);
      expect(update.person!.employeeNumber, existing.employeeNumber);
      expect(preview.newCount, 2);

      var result = await repo.importRoster(manager, [for (final r in preview.valid) r.person!], updateExisting: false);
      expect((result.added, result.updated, result.skipped), (2, 0, 1));
      expect((await repo.listWorkers(manager)).firstWhere((w) => w.id == existing.id).phone, existing.phone, reason: 'left as it was');
      result = await repo.importRoster(manager, [update.person!], updateExisting: true);
      expect((result.added, result.updated), (0, 1));
      final after = (await repo.listWorkers(manager)).firstWhere((w) => w.id == existing.id);
      expect(after.phone, '555-9999');
      expect(after.certifications.length, existing.certifications.length, reason: 'an update keeps certifications');

      final (_, employee) = await signIn('400004', repo);
      await expectLater(repo.importRoster(employee, [update.person!], updateExisting: true), throwsA(isA<AppFailure>()));
    });

    test('employee numbers are suggested per type', () {
      expect(suggestEmployeeNumber(WorkerType.regular, ['E1001', 'E1203', 'T2001']), 'E1204');
      expect(suggestEmployeeNumber(WorkerType.temp, const []), 'T2001');
      expect(suggestEmployeeNumber(WorkerType.npo, ['N3009', 'X1']), 'N3010');
      expect(parseDate('2/29/2027'), isNull);
      expect(parseDate('2028-02-29'), DateTime.utc(2028, 2, 29));
    });
  });

  group('partner portals', () {
    test('an NPO coordinator sees only their group, its hours and payouts', () async {
      final repo = DemoWorkforceRepository(now: now);
      final manager = await repo.signInWithPin('200002');
      final everyone = {for (final w in await repo.listWorkers(manager)) w.id: w};
      final venue = await repo.loadVenue(manager);
      final group = venue.npoGroups.first;

      final (_, coordinator) = await signIn('600006', repo);
      expect(coordinator.workerId, isNull);
      expect(coordinator.can('npo_portal'), isTrue);
      final from = DateTime.utc(2026, 8, 1), to = DateTime.utc(2027, 7, 31);
      final d = await repo.loadNpoPortal(coordinator, from, to);
      expect(d.groupId, group.id);
      expect(d.members, isNotEmpty);
      expect(d.members.every((m) => everyone[m.id]!.npoGroupId == group.id), isTrue);
      expect(d.members.length, everyone.values.where((w) => w.npoGroupId == group.id).length);
      expect(d.activity.punches.every((p) => everyone[p.workerId]!.npoGroupId == group.id), isTrue);
      expect(d.activity.punches.every((p) => p.photoPath == null && p.latitude == null), isTrue, reason: 'times only');
      expect(d.activity.shifts.every((s) => everyone[s.workerId]!.npoGroupId == group.id), isTrue);
      expect(d.payouts, isNotEmpty);
      expect(d.payouts.every((p) => p.npoGroupId == group.id), isTrue);
      expect(d.payouts.any((p) => p.status == 'paid' && p.paymentReference.isNotEmpty), isTrue);
      final hours = partnerHoursByEvent(d.activity, timeZone: venue.venue.timeZone, breakRules: venue.rules.breaks, from: from, to: to);
      expect(hours, isNotEmpty);
      final csv = npoStatementCsv(d, venue.venue.timeZone);
      expect(csv.split('\r\n').where((l) => l.isNotEmpty).length, d.payouts.length + 1);
      await expectLater(repo.loadAgencyPortal(coordinator, from, to), throwsA(isA<AppFailure>()));
      await expectLater(repo.loadNpoPortal(coordinator, from, to, groupId: venue.npoGroups.last.id), throwsA(isA<AppFailure>()), reason: 'another group');
      await expectLater(repo.loadPaySetup(coordinator), throwsA(isA<AppFailure>()), reason: 'no venue pay rates');
    });

    test('an agency contact sees only their temps and their own bill rates', () async {
      final repo = DemoWorkforceRepository(now: now);
      final manager = await repo.signInWithPin('200002');
      final everyone = {for (final w in await repo.listWorkers(manager)) w.id: w};
      final venue = await repo.loadVenue(manager);
      final agency = venue.agencies.first;

      final (_, contact) = await signIn('700007', repo);
      final from = DateTime.utc(2026, 8, 1), to = DateTime.utc(2026, 11, 3);
      final d = await repo.loadAgencyPortal(contact, from, to);
      expect(d.agencyId, agency.id);
      expect(d.members, isNotEmpty);
      expect(d.members.every((m) => everyone[m.id]!.agencyId == agency.id), isTrue);
      expect(d.members.every((m) => m.phone.isEmpty), isTrue, reason: 'agencies keep their own contact records');
      expect(d.billRates, isNotEmpty);
      expect(d.billRates.every((r) => r.agencyId == agency.id), isTrue);
      final billing = agencyBillingByPeriod(d, venueId: venue.venue.id, timeZone: venue.venue.timeZone, venueSettings: venue.venue.settings, from: from, to: to);
      expect(billing, isNotEmpty);
      final memberIds = {for (final m in d.members) m.id};
      for (final b in billing) {
        expect(b.lines.every((l) => memberIds.contains(l.workerId) && l.agencyId == agency.id), isTrue);
        expect(b.totalCents, b.lines.fold(0, (s, l) => s + l.amountCents));
        for (final l in b.lines.where((l) => l.billRateCents != null)) {
          expect(d.billRates.any((r) => r.billRateCents == l.billRateCents), isTrue, reason: 'billed at their own rates');
        }
      }
      await expectLater(repo.loadNpoPortal(contact, from, to), throwsA(isA<AppFailure>()));

      final (_, employee) = await signIn('400004', repo);
      await expectLater(repo.loadAgencyPortal(employee, from, to), throwsA(isA<AppFailure>()));
      await expectLater(repo.loadNpoPortal(employee, from, to), throwsA(isA<AppFailure>()));
    });
  });
}
