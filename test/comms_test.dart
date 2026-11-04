import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:storefront_workforce/data/comms_repository.dart';
import 'package:storefront_workforce/data/demo_repository.dart';
import 'package:storefront_workforce/data/models.dart';
import 'package:storefront_workforce/features/comms/compose.dart';

void main() {
  final now = DateTime.utc(2026, 11, 4, 1, 42);

  Future<(DemoWorkforceRepository, AppSession)> signIn(String pin, {DemoWorkforceRepository? repo}) async {
    final r = repo ?? DemoWorkforceRepository(now: now);
    await r.signOut();
    final s = await r.signInWithPin(pin);
    return (r, s);
  }

  test('an employee sees messages to everyone, their storefront, their level, and to them; not to managers', () async {
    final (repo, emp) = await signIn('400004');
    final messages = await repo.myMessages(emp);
    final audiences = messages.map((m) => m.audience).toSet();
    expect(audiences, containsAll([MessageAudience.everyone, MessageAudience.storefront, MessageAudience.level, MessageAudience.worker]));
    expect(audiences, isNot(contains(MessageAudience.managers)));
    expect(messages.where((m) => m.urgent), isNotEmpty, reason: 'the seeded urgent alert reaches the level');
    expect(messages.every((m) => !m.isRead), isTrue, reason: 'demo sign-ins start with new messages');
    for (var i = 1; i < messages.length; i++) {
      expect(messages[i - 1].createdAt.isBefore(messages[i].createdAt), isFalse, reason: 'newest first');
    }
  });

  test('employees cannot send messages', () async {
    final (repo, emp) = await signIn('400004');
    expect(
      () => repo.sendMessage(emp, const MessageDraft(audience: MessageAudience.managers, body: 'Hi')),
      throwsA(isA<AppFailure>()),
    );
  });

  test('a lead can alert the managers and message their own storefront, nothing else', () async {
    final (repo, lead) = await signIn('300003');
    final own = lead.grants.firstWhere((g) => g.scopeType == 'storefront').scopeId!;
    final venue = await repo.loadVenue(lead);
    final other = venue.storefronts.firstWhere((s) => s.id != own);

    final help = await repo.sendMessage(lead, const MessageDraft(audience: MessageAudience.managers, body: 'Stand needs a runner.', urgent: true));
    expect(help.recipientCount, greaterThan(0));
    final team = await repo.sendMessage(lead, MessageDraft(audience: MessageAudience.storefront, audienceId: own, body: 'Huddle at the register.'));
    expect(team.audienceLabel, contains(repo.liveEvent!.name), reason: 'storefront messages go to the current event');

    expect(() => repo.sendMessage(lead, MessageDraft(audience: MessageAudience.storefront, audienceId: other.id, body: 'x')), throwsA(isA<AppFailure>()));
    expect(() => repo.sendMessage(lead, const MessageDraft(audience: MessageAudience.everyone, body: 'x')), throwsA(isA<AppFailure>()));

    // The manager gets the alert, marked urgent.
    final (_, manager) = await signIn('200002', repo: repo);
    final inbox = await repo.myMessages(manager);
    expect(inbox.firstWhere((m) => m.id == help.id).urgent, isTrue);
    expect(inbox.any((m) => m.id == team.id), isTrue, reason: 'venue managers see storefront messages');
  });

  test('a storefront message reaches its crew; reading it updates the sender\'s count and clears the notification', () async {
    final (repo, emp) = await signIn('400004');
    final shift = (await repo.loadMyDay(emp)).current!.shift;
    final (_, manager) = await signIn('200002', repo: repo);
    final sent = await repo.sendMessage(
      manager,
      MessageDraft(audience: MessageAudience.storefront, audienceId: shift.storefrontId, eventId: shift.eventId, body: 'Restock lids.'),
    );
    expect(sent.recipientCount, greaterThan(1));

    await signIn('400004', repo: repo);
    final mine = await repo.myMessages(emp);
    expect(mine.any((m) => m.id == sent.id), isTrue);
    final notes = await repo.myNotifications(emp);
    final note = notes.firstWhere((n) => n.data['message_id'] == sent.id);
    expect(note.isRead, isFalse);
    expect(note.title, 'Message from ${manager.displayName}');

    await repo.markMessagesRead(emp, [sent.id]);
    expect((await repo.myMessages(emp)).firstWhere((m) => m.id == sent.id).isRead, isTrue);
    expect((await repo.myNotifications(emp)).firstWhere((n) => n.id == note.id).isRead, isTrue);

    await signIn('200002', repo: repo);
    final view = (await repo.sentMessages(manager)).firstWhere((m) => m.id == sent.id);
    expect(view.readCount, 1);
    expect(view.recipientCount, sent.recipientCount);
  });

  test('Spanish speakers get notifications in Spanish', () async {
    final (repo, es) = await signIn('400005');
    final notes = await repo.myNotifications(es);
    expect(notes.where((n) => n.isMessage).every((n) => n.title.startsWith('Mensaje de') || n.title.startsWith('Urgente de')), isTrue);
    expect(notes.where((n) => n.isMessage), isNotEmpty);
  });

  test('policies need a typed name; acknowledgments show in the manager report', () async {
    final (repo, lead) = await signIn('300003');
    final mine = await repo.myAnnouncements(lead);
    final policy = mine.first;
    expect(policy.title, 'Alcohol service policy', reason: 'what needs acknowledgment comes first');
    expect(policy.isPolicy && policy.needsMyAck, isTrue);
    expect(policy.documentPath, isNotNull);
    final doc = await repo.openDocument(lead, policy.documentPath!);
    expect(String.fromCharCodes(doc.bytes!.take(5)), '%PDF-');

    expect(() => repo.acknowledgeAnnouncement(lead, policy.id), throwsA(isA<AppFailure>()));
    await repo.acknowledgeAnnouncement(lead, policy.id, typedName: lead.displayName);
    final after = (await repo.myAnnouncements(lead)).firstWhere((a) => a.id == policy.id);
    expect(after.ackedAt, isNotNull);
    expect(after.typedName, lead.displayName);

    final (_, manager) = await signIn('200002', repo: repo);
    final report = await repo.ackReport(manager, policy.id);
    final leadRow = report.people.firstWhere((p) => p.workerId == lead.workerId);
    expect(leadRow.acked, isTrue);
    expect(report.people.first.acked, isFalse, reason: 'people still to acknowledge are listed first');
    final summary = (await repo.announcementSummaries(manager)).firstWhere((a) => a.id == policy.id);
    expect(summary.ackCount, report.acked);
    expect(summary.audienceCount, report.people.length);

    final reminded = await repo.remindUnacknowledged(manager, policy.id);
    expect(reminded, report.people.length - report.acked);
    expect(await repo.remindUnacknowledged(manager, policy.id), 0, reason: 'once an hour');
  });

  test('employees cannot see acknowledgment reports or publish', () async {
    final (repo, emp) = await signIn('400004');
    final any = (await repo.myAnnouncements(emp)).first;
    expect(() => repo.ackReport(emp, any.id), throwsA(isA<AppFailure>()));
    expect(() => repo.publishAnnouncement(emp, const AnnouncementDraft(title: 'x')), throwsA(isA<AppFailure>()));
  });

  test('a published announcement with a document reaches its audience only', () async {
    final (repo, admin) = await signIn('100001');
    final path = await repo.uploadDocument(admin, 'Cash policy.pdf', Uint8List.fromList('%PDF-1.4 test'.codeUnits), 'application/pdf');
    expect(path, startsWith('${admin.venue.id}/announcements/'));
    final a = await repo.publishAnnouncement(
      admin,
      AnnouncementDraft(title: 'Cash handling', body: 'Count down your drawer with your lead.', isPolicy: true, documentPath: path,
          audience: const AnnouncementAudience(jobRoles: ['cashier'])),
    );
    expect(a.requiresAck, isTrue, reason: 'a policy always asks for acknowledgment');
    expect(a.audienceCount, greaterThan(0));

    final (_, emp) = await signIn('400004', repo: repo);
    final w = (await repo.loadMyDay(emp)).worker!;
    final sees = (await repo.myAnnouncements(emp)).any((x) => x.id == a.id);
    expect(sees, w.jobRoles.contains('cashier'));
    expect(
      () => repo.publishAnnouncement(admin, AnnouncementDraft(title: 'x', documentPath: 'other-venue/announcements/x.pdf')),
      throwsA(isA<AppFailure>()),
    );
  });

  test('plain announcements are acknowledged without a name', () async {
    final (repo, emp) = await signIn('400004');
    final handbook = (await repo.myAnnouncements(emp)).firstWhere((a) => a.title.contains('handbook'));
    expect(handbook.needsMyAck && !handbook.isPolicy, isTrue);
    await repo.acknowledgeAnnouncement(emp, handbook.id);
    expect((await repo.myAnnouncements(emp)).firstWhere((a) => a.id == handbook.id).needsMyAck, isFalse);
    final parking = (await repo.myAnnouncements(emp)).firstWhere((a) => !a.requiresAck);
    expect(() => repo.acknowledgeAnnouncement(emp, parking.id), throwsA(isA<AppFailure>()));
  });

  test('temp-only announcements skip regular staff', () async {
    final (repo, admin) = await signIn('100001');
    final temps = (await repo.announcementSummaries(admin)).firstWhere((a) => a.audience.workerTypes.contains('temp'));
    final report = await repo.ackReport(admin, temps.id);
    expect(report.people.every((p) => p.workerType == 'temp'), isTrue);
  });

  test('notifications: reminders are seeded, and mark all read clears them', () async {
    final (repo, emp) = await signIn('400004');
    final notes = await repo.myNotifications(emp);
    expect(notes.any((n) => n.kind == 'call_time' && n.link == '/clock'), isTrue);
    expect(notes.any((n) => !n.isRead), isTrue);
    await repo.markNotificationsRead(emp);
    expect((await repo.myNotifications(emp)).every((n) => n.isRead), isTrue);

    final (_, manager) = await signIn('200002', repo: repo);
    final managerNotes = await repo.myNotifications(manager);
    expect(managerNotes.any((n) => n.isMessage && n.title.startsWith('Urgent from')), isTrue, reason: 'the lead\'s help alert');
  });

  test('a new message is announced on the live stream', () async {
    final (repo, manager) = await signIn('200002');
    var ticks = 0;
    final sub = repo.commsChanges(manager).listen((_) => ticks++);
    await repo.sendMessage(manager, const MessageDraft(audience: MessageAudience.everyone, body: 'Doors in 10.'));
    await Future<void>.delayed(Duration.zero);
    expect(ticks, greaterThan(0));
    await sub.cancel();
  });

  test('notification settings: push on and email off by default, no text messages', () async {
    final (repo, emp) = await signIn('400004');
    final prefs = await repo.notificationPrefs(emp);
    expect(prefs.push, isTrue);
    expect(prefs.email, isFalse);
    expect(prefs.hasStaffRecord, isTrue);
    expect(prefs.toJson().keys, isNot(contains('sms')));
    final saved = await repo.saveNotificationPrefs(emp, prefs.copyWith(email: true).withQuietHours('22:00', '07:00'));
    expect(saved.email, isTrue);
    expect(saved.quietStart, '22:00');
    expect(MessageDraft(audience: MessageAudience.everyone, body: 'x', urgent: true).toJson('v').containsKey('channels'), isFalse);
  });

  test('quick message templates', () {
    expect(templateText('needs a runner.'), 'Needs a runner.');
    expect(templateText('needs a runner.', storefrontName: 'Stand 104'), 'Stand 104: needs a runner.');
    expect(messageTemplates.map((t) => t.$1), containsAll(['Needs a runner', 'Needs a cashier', 'Break coverage', 'Restock help', 'Close early']));
  });

  test('message and announcement JSON from the database', () {
    final m = CommsMessage.fromJson({
      'id': 'm1', 'sender_id': 'u', 'sender_name': 'Marcus', 'audience': 'storefront', 'audience_id': 's',
      'audience_label': 'Stand 101 · Game 1', 'event_id': 'e', 'body': 'Restock', 'urgent': true,
      'created_at': '2026-11-04T01:00:00Z', 'read_at': null, 'recipient_count': 4, 'read_count': 2,
    });
    expect(m.audience, MessageAudience.storefront);
    expect(m.urgent && !m.isRead && m.readCount == 2, isTrue);
    final a = Announcement.fromJson({
      'id': 'a1', 'title': 'Policy', 'audience': {'job_roles': ['bartender']}, 'requires_ack': true, 'is_policy': true,
      'published_at': '2026-11-01T00:00:00Z', 'acked_at': null, 'audience_count': 10, 'ack_count': 3,
    });
    expect(a.needsMyAck, isTrue);
    expect(a.audience.jobRoles, ['bartender']);
    expect(const AnnouncementAudience().toJson(), isEmpty);
    final p = NotificationPrefs.fromJson({'push': true, 'email': true, 'quiet_start': '23:00', 'quiet_end': '07:00', 'has_staff_record': false, 'email_address': 'a@b.co'});
    expect(p.toJson(), {'push': true, 'email': true, 'quiet_start': '23:00', 'quiet_end': '07:00', 'email_address': 'a@b.co'});
  });
}
