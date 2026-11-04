import 'package:flutter_test/flutter_test.dart';
import 'package:storefront_workforce/data/admin_repository.dart';
import 'package:storefront_workforce/data/demo_repository.dart';
import 'package:storefront_workforce/data/models.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4, 1, 42);
  DemoWorkforceRepository repo() => DemoWorkforceRepository(now: now);

  group('retention', () {
    test('four years by default, and the two-year floor is enforced', () async {
      final r = repo();
      final session = await r.signInWithPin('100001');
      final policy = await r.loadRetention(session);
      expect(policy.timeRecordsMonths, 48, reason: 'four years');
      expect(policy.validate(), isNull);

      await expectLater(
        r.saveRetention(session, policy.copyWith(timeRecordsMonths: 12)),
        throwsA(isA<AppFailure>()),
        reason: 'below the legal floor',
      );
      expect(const RetentionPolicy(timeRecordsMonths: 24).validate(), isNull, reason: 'two years is allowed');
      expect(const RetentionPolicy(timeRecordsMonths: 240).validate(), isNotNull);
      expect(const RetentionPolicy(punchPhotoMonths: 0).validate(), isNotNull);
    });

    test('a saved period is kept, and clearing old photos leaves the punches', () async {
      final r = repo();
      final session = await r.signInWithPin('100001');
      await r.saveRetention(session, const RetentionPolicy(punchPhotoMonths: 1));
      expect((await r.loadRetention(session)).punchPhotoMonths, 1);

      final due = await r.retentionDue(session);
      expect(due.punchPhotos, greaterThan(0), reason: 'the sample season has older photos');

      final board = await r.loadBoard((await r.listEvents(session)).first.id);
      final punchesBefore = board.punches.length;
      final cleared = await r.purgeOldPunchPhotos(session);
      expect(cleared, due.punchPhotos);
      expect((await r.retentionDue(session)).punchPhotos, 0);

      final after = await r.loadBoard(board.event.id);
      expect(after.punches.length, punchesBefore, reason: 'the times stay; only the photos go');
    });

    test('an employee cannot read or change retention', () async {
      final r = repo();
      final session = await r.signInWithPin('400004');
      await expectLater(r.loadRetention(session), throwsA(isA<AppFailure>()));
      await expectLater(r.saveRetention(session, RetentionPolicy.defaults), throwsA(isA<AppFailure>()));
    });
  });

  group('removing personal data', () {
    test('the person who asks cannot approve it', () async {
      final r = repo();
      final session = await r.signInWithPin('100001');
      final person = (await r.listWorkers(session)).firstWhere((w) => w.type == WorkerType.regular);

      await r.requestDataDeletion(session, person.id, note: 'Asked by email');
      final request = (await r.loadDeletionRequests(session)).single;
      expect(request.isPending, isTrue);
      expect(request.requestedByMe, isTrue);
      await expectLater(r.approveDataDeletion(session, request.id), throwsA(isA<AppFailure>()));
      await expectLater(r.requestDataDeletion(session, person.id), throwsA(isA<AppFailure>()), reason: 'already waiting');
    });

    test('approving clears the personal details and keeps the hours', () async {
      final r = repo();
      final asker = await r.signInWithPin('200002'); // concessions manager asks
      final person = (await r.listWorkers(asker)).firstWhere((w) => w.type == WorkerType.regular);
      final event = (await r.listEvents(asker)).firstWhere((e) => e.status == EventStatus.completed);
      final punchesBefore = (await r.loadBoard(event.id)).punches.length;

      await r.requestDataDeletion(asker, person.id);
      final request = (await r.loadDeletionRequests(asker)).single;

      await r.signOut();
      final admin = await r.signInWithPin('100001'); // a different person decides
      await r.approveDataDeletion(admin, request.id, note: 'Verified by phone');

      final after = (await r.listWorkers(admin)).firstWhere((w) => w.id == person.id);
      expect(after.firstName, 'Removed');
      expect(after.phone, isEmpty);
      expect(after.email, isEmpty);
      expect(after.employeeNumber, startsWith('REMOVED-'));
      expect(after.status, 'inactive');

      expect((await r.loadBoard(event.id)).punches.length, punchesBefore, reason: 'hours are kept for payroll');
      final decided = (await r.loadDeletionRequests(admin)).single;
      expect(decided.status, 'completed');
      expect(decided.decisionNote, 'Verified by phone');
    });

    test('refusing needs a reason and leaves the record alone', () async {
      final r = repo();
      final asker = await r.signInWithPin('200002');
      final person = (await r.listWorkers(asker)).firstWhere((w) => w.type == WorkerType.regular);
      await r.requestDataDeletion(asker, person.id);
      final request = (await r.loadDeletionRequests(asker)).single;

      await r.signOut();
      final admin = await r.signInWithPin('100001');
      await expectLater(r.refuseDataDeletion(admin, request.id, '  '), throwsA(isA<AppFailure>()));
      await r.refuseDataDeletion(admin, request.id, 'Still inside the retention period');

      final after = (await r.loadDeletionRequests(admin)).single;
      expect(after.status, 'refused');
      expect((await r.listWorkers(admin)).firstWhere((w) => w.id == person.id).firstName, isNot('Removed'));
      await expectLater(r.approveDataDeletion(admin, request.id), throwsA(isA<AppFailure>()), reason: 'already decided');
    });

    test('a manager without manage_settings cannot decide', () async {
      final r = repo();
      final manager = await r.signInWithPin('200002');
      final person = (await r.listWorkers(manager)).firstWhere((w) => w.type == WorkerType.regular);
      await r.requestDataDeletion(manager, person.id);
      final request = (await r.loadDeletionRequests(manager)).single;
      expect(manager.canVenueWide('manage_settings'), isFalse);
      await expectLater(r.approveDataDeletion(manager, request.id), throwsA(isA<AppFailure>()));
      await expectLater(r.refuseDataDeletion(manager, request.id, 'no'), throwsA(isA<AppFailure>()));
    });
  });

  test('venue profile and branding are saved by an admin only', () async {
    final r = repo();
    final admin = await r.signInWithPin('100001');
    await r.saveVenueProfile(admin, name: 'Pecan Valley Arena', branding: {'app_name': 'PV Staff', 'primary_color': '#1D4ED8'});
    await expectLater(r.saveVenueProfile(admin, name: '   '), throwsA(isA<AppFailure>()));

    await r.signOut();
    final employee = await r.signInWithPin('400004');
    await expectLater(r.saveVenueProfile(employee, name: 'Nope'), throwsA(isA<AppFailure>()));
  });
}
