part of '../demo_repository.dart';

/// Someone in the demo arena who can get messages: every active staff member, plus the
/// sign-in personas without a staff record (admin, manager). Mirrors the people the
/// database's message_visible_to() and announcement_audience() consider.
class _CommsPerson {
  const _CommsPerson(this.key, {this.worker, this.session});

  /// `w:` plus the worker id, or `u:` plus the user id.
  final String key;
  final Worker? worker;

  /// The demo sign-in for this person, when there is one.
  final AppSession? session;

  List<RoleGrant> get grants => session?.grants ?? const [];
  String get name => worker?.displayName ?? session?.displayName ?? '';
  String get language => worker?.preferredLanguage ?? session?.language ?? 'en';
  Set<String> get roleCodes => session == null ? {if (worker != null) 'employee'} : {for (final g in session!.grants) g.roleCode};
  bool get runsEvents => grants.any((g) => g.permissions.contains(Perm.viewLive) || g.permissions.contains(Perm.manageSchedule));
}

/// Demo (in-memory) implementation of [CommsRepository].
mixin _DemoComms on _DemoCore implements CommsRepository {
  final List<CommsMessage> _commsMessages = [];
  final Map<String, String> _commsSenderKey = {};

  /// message id -> person key -> read time.
  final Map<String, Map<String, DateTime>> _commsReads = {};
  final List<Announcement> _commsAnnouncements = [];

  /// announcement id -> person key -> (time, typed name).
  final Map<String, Map<String, (DateTime, String)>> _commsAcks = {};
  final Set<String> _commsReminderKeys = {};
  final Map<String, NotificationPrefs> _commsPrefs = {};
  final Map<String, (String, String, Uint8List)> _commsDocs = {};
  final StreamController<void> _commsBus = StreamController<void>.broadcast();
  final Stopwatch _commsClock = Stopwatch();
  bool _commsSeeded = false;

  /// The demo's clock: the sample arena's "now", moving forward in real time.
  DateTime _commsNow() => _arena.now.add(_commsClock.elapsed);

  static String _commsKeyOf(AppSession s) => s.workerId != null ? 'w:${s.workerId}' : 'u:${s.userId}';

  _CommsPerson _commsMe(AppSession s) {
    _commsSeed();
    final w = s.workerId == null ? null : _workers[s.workerId];
    return _CommsPerson(_commsKeyOf(s), worker: w, session: s);
  }

  List<_CommsPerson> get _commsPeople {
    final sessions = {for (final s in _sessionsByPin.values) if (!s.isKiosk) _commsKeyOf(s): s};
    return [
      for (final w in _workers.values)
        if (w.status == 'active') _CommsPerson('w:${w.id}', worker: w, session: sessions['w:${w.id}']),
      for (final s in _sessionsByPin.values)
        if (!s.isKiosk && s.workerId == null) _CommsPerson('u:${s.userId}', session: s),
    ];
  }

  Iterable<AppSession> get _commsPersonas => _sessionsByPin.values.where((s) => !s.isKiosk);

  // ---- Visibility ----

  Set<String> _commsTargetStorefronts(CommsMessage m) => m.audience == MessageAudience.storefront
      ? {?m.audienceId}
      : {for (final f in _arena.storefronts) if (f.levelId == m.audienceId) f.id};

  /// Workers with a position at the message's storefronts at its event.
  Set<String> _commsWorkingThere(CommsMessage m) {
    if (m.eventId == null) return const {};
    final targets = _commsTargetStorefronts(m);
    return {
      for (final s in _shifts.values)
        if (s.eventId == m.eventId &&
            s.workerId != null &&
            (s.status == ShiftStatus.assigned || s.status == ShiftStatus.released) &&
            targets.contains(s.storefrontId))
          s.workerId!,
    };
  }

  bool _commsCanSee(CommsMessage m, _CommsPerson p, {Set<String>? workingThere}) {
    if (_commsSenderKey[m.id] == p.key) return true;
    switch (m.audience) {
      case MessageAudience.everyone:
        return true;
      case MessageAudience.managers:
        return p.runsEvents;
      case MessageAudience.worker:
        return p.worker != null && p.worker!.id == m.audienceId;
      case MessageAudience.storefront:
      case MessageAudience.level:
        if (p.worker != null && (workingThere ?? _commsWorkingThere(m)).contains(p.worker!.id)) return true;
        final s = p.session;
        if (s == null) return false;
        final scope = _scope(s, {Perm.viewLive, Perm.manageSchedule});
        return _commsTargetStorefronts(m).any(scope.contains);
    }
  }

  List<_CommsPerson> _commsRecipients(CommsMessage m) {
    final working = _commsWorkingThere(m);
    final sender = _commsSenderKey[m.id];
    return [for (final p in _commsPeople) if (p.key != sender && _commsCanSee(m, p, workingThere: working)) p];
  }

  int _commsReadCount(CommsMessage m) => (_commsReads[m.id] ?? const {}).keys.where((k) => k != _commsSenderKey[m.id]).length;

  bool _commsInAudience(AnnouncementAudience a, _CommsPerson p) {
    final w = p.worker;
    if (a.workerTypes.isNotEmpty && (w == null || !a.workerTypes.contains(w.type.code))) return false;
    if (a.jobRoles.isNotEmpty && (w == null || !w.jobRoles.any(a.jobRoles.contains))) return false;
    if (a.roles.isNotEmpty && !p.roleCodes.any(a.roles.contains)) return false;
    return true;
  }

  bool _commsCanManageAnnouncements(AppSession s) => s.canVenueWide(Perm.manageWorkers) || s.canVenueWide(Perm.manageSettings);

  // ---- Notifications ----

  void _commsNotify(String userId, {required String kind, required String title, String body = '', String link = '/inbox', Map<String, dynamic> data = const {}, DateTime? at, bool read = false}) {
    final when = at ?? _commsNow();
    _notifications.putIfAbsent(userId, () => []).add(AppNotification(
          id: _id(),
          kind: kind,
          title: title,
          body: body,
          link: link,
          createdAt: when,
          readAt: read ? when.add(const Duration(minutes: 1)) : null,
          data: data,
        ));
  }

  void _commsNotifyMessage(CommsMessage m) {
    final sender = _commsSenderKey[m.id];
    for (final s in _commsPersonas) {
      final p = _commsMe(s);
      if (p.key == sender || !_commsCanSee(m, p)) continue;
      final es = p.language == 'es';
      _commsNotify(
        s.userId,
        kind: 'message',
        title: '${m.urgent ? (es ? 'Urgente de ' : 'Urgent from ') : (es ? 'Mensaje de ' : 'Message from ')}${m.senderName}',
        body: m.body,
        data: {'message_id': m.id, 'urgent': m.urgent},
        at: m.createdAt,
      );
    }
  }

  void _commsNotifyAnnouncement(Announcement a, {String? exceptKey}) {
    for (final s in _commsPersonas) {
      final p = _commsMe(s);
      if (p.key == exceptKey || !_commsInAudience(a.audience, p)) continue;
      final es = p.language == 'es';
      final prefix = a.requiresAck ? (es ? 'Lea y confirme: ' : 'Please read and acknowledge: ') : (es ? 'Nuevo aviso: ' : 'New announcement: ');
      _commsNotify(s.userId,
          kind: 'announcement', title: '$prefix${a.title}', body: a.body.length > 300 ? a.body.substring(0, 300) : a.body, data: {'announcement_id': a.id}, at: a.publishedAt);
    }
  }

  void _commsChanged() => _commsBus.add(null);

  // ---- Seed ----

  Event? _commsCurrentEvent() {
    final now = _commsNow();
    for (final e in _events.values) {
      if (e.status == EventStatus.cancelled || e.status == EventStatus.completed) continue;
      final end = e.endTime ?? e.startTime.add(const Duration(hours: 3));
      if (!now.isBefore(e.callTime.subtract(const Duration(hours: 4))) && !now.isAfter(end.add(const Duration(hours: 2)))) return e;
    }
    return _arena.liveEvent;
  }

  CommsMessage _commsStore(CommsMessage m, String senderKey, {double readShare = 0}) {
    _commsSenderKey[m.id] = senderKey;
    final recipients = _commsRecipients(m);
    final stored = m.copyWith(recipientCount: recipients.length);
    _commsMessages.add(stored);
    if (readShare > 0) {
      final reads = _commsReads.putIfAbsent(m.id, () => {});
      final every = (1 / readShare).round().clamp(1, 1000);
      for (var i = 0; i < recipients.length; i++) {
        // Demo personas start unread, so the inbox has something new.
        if (i % every == 0 && recipients[i].session == null) reads[recipients[i].key] = m.createdAt.add(Duration(minutes: 1 + i % 9));
      }
    }
    return stored;
  }

  void _commsSeed() {
    if (_commsSeeded) return;
    _commsSeeded = true;
    _commsClock.start();
    final now = _arena.now;
    final venue = _arena.venue;
    final manager = _sessionsByPin['200002'];
    final lead = _sessionsByPin['300003'];
    final employee = _sessionsByPin['400004'] ?? _sessionsByPin['400005'];
    final live = _arena.liveEvent;

    // Announcements.
    final policyPath = '${venue.id}/announcements/alcohol-service-policy.pdf';
    _commsDocs[policyPath] = (
      'Alcohol service policy.pdf',
      'application/pdf',
      _commsPdf('Alcohol Service Policy', const [
        'Pecan Valley Arena - Concessions',
        '',
        '1. Check a photo ID for every guest who looks under 30.',
        '2. Two drinks per guest per transaction.',
        '3. Last call is announced by the concessions manager.',
        '4. Refuse service to anyone who appears intoxicated, and tell your lead.',
        '5. Keep your TABC seller-server certificate current.',
        '',
        'Questions: ask your lead or the concessions office.',
      ]),
    );
    final policy = Announcement(
      id: _id(),
      title: 'Alcohol service policy',
      body: 'Every bartender and lead must read the updated alcohol service policy before their next shift. '
          'ID checks for anyone who looks under 30, two drinks per guest per transaction, and last call is announced by the manager.',
      audience: const AnnouncementAudience(jobRoles: ['bartender', 'lead']),
      requiresAck: true,
      isPolicy: true,
      documentPath: policyPath,
      publishedAt: now.subtract(const Duration(days: 3, hours: 2)),
      createdByName: 'Dana Whitfield',
    );
    final handbook = Announcement(
      id: _id(),
      title: 'Winter season staff handbook',
      body: 'The handbook for the winter season is posted at every stand: uniforms, breaks, cash handling, and who to call. '
          'Tap "I have read this" once you have gone through it.',
      requiresAck: true,
      publishedAt: now.subtract(const Duration(days: 2, hours: 5)),
      createdByName: 'Marcus Bell',
    );
    final parking = Announcement(
      id: _id(),
      title: 'Staff parking moves to Lot C this weekend',
      body: 'The holiday market takes over Lot B on Saturday and Sunday. Park in Lot C and use the north staff entrance.',
      publishedAt: now.subtract(const Duration(hours: 20)),
      expiresAt: now.add(const Duration(days: 5)),
      createdByName: 'Marcus Bell',
    );
    final temps = Announcement(
      id: _id(),
      title: 'Temp staff: check in at Gate B',
      body: 'Agency staff check in with the concessions office at Gate B, 15 minutes before call.',
      audience: const AnnouncementAudience(workerTypes: ['temp']),
      publishedAt: now.subtract(const Duration(days: 1, hours: 3)),
      createdByName: 'Marcus Bell',
    );
    _commsAnnouncements.addAll([policy, handbook, parking, temps]);
    final people = _commsPeople;
    for (final (a, share) in [(policy, 0.6), (handbook, 0.45)]) {
      final acks = _commsAcks.putIfAbsent(a.id, () => {});
      final audience = [for (final p in people) if (_commsInAudience(a.audience, p) && p.session == null) p];
      final every = (1 / share).round();
      for (var i = 0; i < audience.length; i++) {
        if (i % every == 0 || (share > 0.5 && i % every == 1)) {
          acks[audience[i].key] = (a.publishedAt.add(Duration(hours: 1 + i % 30)), a.isPolicy ? audience[i].name : '');
        }
      }
    }
    for (final a in _commsAnnouncements) {
      _commsNotifyAnnouncement(a);
    }

    // Messages at the live event.
    if (manager != null) {
      final managerKey = _commsKeyOf(manager);
      CommsMessage msg(MessageAudience audience, String body, Duration ago, {String? audienceId, String label = '', bool urgent = false, String? eventId}) =>
          CommsMessage(
            id: _id(),
            senderId: manager.userId,
            senderName: manager.displayName,
            audience: audience,
            audienceId: audienceId,
            audienceLabel: label,
            eventId: eventId,
            body: body,
            urgent: urgent,
            createdAt: now.subtract(ago),
          );
      final seeded = <CommsMessage>[
        _commsStore(msg(MessageAudience.everyone, 'Doors at 6:00 and we expect a sellout. Every register open by 5:45, please.', const Duration(minutes: 95),
            label: 'Everyone'), managerKey, readShare: 0.7),
      ];
      Shift? empShift;
      if (live != null && employee?.workerId != null) {
        for (final s in _shifts.values) {
          if (s.eventId == live.id && s.workerId == employee!.workerId) empShift = s;
        }
      }
      if (live != null && empShift != null) {
        final sf = _arena.storefronts.firstWhere((f) => f.id == empShift!.storefrontId);
        final level = _arena.levels.firstWhere((l) => l.id == sf.levelId);
        seeded.add(_commsStore(
            msg(MessageAudience.storefront, 'Restock cups and lids before first intermission. Extra cases are in the back hall.', const Duration(minutes: 22),
                audienceId: sf.id, eventId: live.id, label: '${sf.name} · ${live.name}'),
            managerKey,
            readShare: 0.5));
        seeded.add(_commsStore(
            msg(MessageAudience.level, 'Lines on the ${level.name} are backing up. Leads: open your second register now.', const Duration(minutes: 6),
                audienceId: level.id, eventId: live.id, label: 'Level: ${level.name} · ${live.name}', urgent: true),
            managerKey,
            readShare: 0.3));
      }
      if (employee?.workerId != null) {
        final w = _workers[employee!.workerId]!;
        seeded.add(_commsStore(
            msg(MessageAudience.worker, 'Can you stay through close tonight? Tell your lead before the third period.', const Duration(minutes: 41),
                audienceId: w.id, label: w.displayName),
            managerKey));
      }
      if (lead != null && lead.workerId != null && live != null) {
        final grant = lead.grants.firstWhere((g) => g.scopeType == 'storefront', orElse: () => lead.grants.first);
        final sf = _arena.storefronts.where((f) => f.id == grant.scopeId).firstOrNull;
        final help = CommsMessage(
          id: _id(),
          senderId: lead.userId,
          senderName: lead.displayName,
          audience: MessageAudience.managers,
          audienceLabel: 'Managers and leads',
          body: '${sf?.name ?? 'My stand'} needs a runner: we are out of ice and cups.',
          urgent: true,
          createdAt: now.subtract(const Duration(minutes: 12)),
        );
        seeded.add(_commsStore(help, _commsKeyOf(lead), readShare: 0.5));
      }
      for (final m in seeded) {
        _commsNotifyMessage(m);
      }
    }

    // Reminders the scheduler would have queued.
    if (live != null) {
      for (final s in _commsPersonas) {
        if (s.workerId == null) continue;
        final shift = _shifts.values.where((x) => x.eventId == live.id && x.workerId == s.workerId).firstOrNull;
        if (shift == null) continue;
        final sf = _arena.storefronts.firstWhere((f) => f.id == shift.storefrontId);
        final time = _commsClockTime(shift.callTime);
        final es = s.language == 'es';
        _commsNotify(s.userId,
            kind: 'call_time',
            title: es ? 'Llegada $time en ${sf.name}' : 'Call time $time at ${sf.name}',
            body: es ? '${live.name}. Marque su entrada al llegar.' : '${live.name}. Clock in when you arrive.',
            link: '/clock',
            at: shift.callTime.subtract(const Duration(hours: 2)),
            read: true);
      }
      if (manager != null) {
        final clockedIn = {for (final p in _punches) if (p.eventId == live.id && p.kind == PunchKind.clockIn) p.workerId};
        final missing = [
          for (final s in _shifts.values)
            if (s.eventId == live.id &&
                s.status == ShiftStatus.assigned &&
                !clockedIn.contains(s.workerId) &&
                s.callTime.add(const Duration(minutes: 20)).isBefore(now))
              s,
        ]..sort((a, b) => a.callTime.compareTo(b.callTime));
        for (final s in missing.take(2)) {
          final w = _workers[s.workerId]!;
          final sf = _arena.storefronts.firstWhere((f) => f.id == s.storefrontId);
          for (final userId in [manager.userId, ?_sessionsByPin['100001']?.userId]) {
            _commsNotify(userId,
                kind: 'missed_clock_in',
                title: 'Not clocked in: ${w.displayName}',
                body: '${sf.name} · ${s.jobRoleCode} · ${_commsClockTime(s.callTime)}',
                link: '/live',
                at: s.callTime.add(const Duration(minutes: 20)));
          }
        }
        final soon = <String>[];
        for (final w in _workers.values) {
          for (final c in w.certifications) {
            final exp = c.expiresOn;
            if (exp != null && !exp.isBefore(now) && exp.isBefore(now.add(const Duration(days: 30)))) {
              soon.add('${w.displayName} (${c.typeCode}, ${exp.month}/${exp.day})');
            }
          }
        }
        if (soon.isNotEmpty) {
          _commsNotify(manager.userId,
              kind: 'cert_expiring',
              title: '${soon.length} ${soon.length == 1 ? 'certification expires' : 'certifications expire'} within 30 days',
              body: soon.take(8).join('; '),
              link: '/staff',
              at: now.subtract(const Duration(days: 1, hours: 4)));
        }
      }
    }
  }

  String _commsClockTime(DateTime utc) {
    final local = atVenue(utc, _arena.venue.timeZone);
    final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
    return '$h:${local.minute.toString().padLeft(2, '0')} ${local.hour < 12 ? 'AM' : 'PM'}';
  }

  /// A one-page PDF with plain text, so the demo policy has a document to open.
  static Uint8List _commsPdf(String title, List<String> lines) {
    String esc(String s) => s.replaceAll(r'\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');
    final content = StringBuffer('BT /F1 20 Tf 72 712 Td (${esc(title)}) Tj /F1 12 Tf 0 -32 Td 18 TL\n');
    for (final l in lines) {
      content.write('(${esc(l)}) Tj T*\n');
    }
    content.write('ET');
    final stream = content.toString();
    final objects = [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
      '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
    ];
    final out = StringBuffer('%PDF-1.4\n');
    final offsets = <int>[];
    for (var i = 0; i < objects.length; i++) {
      offsets.add(out.length);
      out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
    }
    final xref = out.length;
    out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
    for (final o in offsets) {
      out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
    }
    out.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
    return Uint8List.fromList(out.toString().codeUnits);
  }

  // ---- Messages ----

  @override
  Future<List<CommsMessage>> myMessages(AppSession session) => _delay(() {
        final me = _commsMe(session);
        return [
          for (final m in _commsMessages.reversed)
            if (_commsSenderKey[m.id] != me.key && _commsCanSee(m, me)) m.copyWith(readAt: _commsReads[m.id]?[me.key]),
        ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      });

  @override
  Future<List<CommsMessage>> sentMessages(AppSession session) => _delay(() {
        final me = _commsMe(session);
        final all = session.canVenueWide(Perm.manageSchedule);
        return [
          for (final m in _commsMessages)
            if (all || _commsSenderKey[m.id] == me.key)
              CommsMessage(
                id: m.id,
                senderId: m.senderId,
                senderName: m.senderName,
                audience: m.audience,
                audienceId: m.audienceId,
                audienceLabel: m.audienceLabel,
                eventId: m.eventId,
                body: m.body,
                urgent: m.urgent,
                createdAt: m.createdAt,
                recipientCount: m.recipientCount,
                readCount: _commsReadCount(m),
                mine: _commsSenderKey[m.id] == me.key,
              ),
        ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      });

  @override
  Future<CommsMessage> sendMessage(AppSession session, MessageDraft draft) => _delay(() {
        final me = _commsMe(session);
        if (!session.can(Perm.viewLive) && !session.can(Perm.manageSchedule)) {
          throw const AppFailure('Only managers and leads can send messages');
        }
        final body = draft.body.trim();
        if (body.isEmpty) throw const AppFailure('Write a message');
        if (body.length > 1000) throw const AppFailure('Messages are limited to 1,000 characters');
        final venueWide = session.canVenueWide(Perm.viewLive) || session.canVenueWide(Perm.manageSchedule);
        final scope = _scope(session, {Perm.viewLive, Perm.manageSchedule});
        String label;
        String? eventId = draft.eventId;
        switch (draft.audience) {
          case MessageAudience.everyone:
            if (!venueWide) throw const AppFailure('Only venue managers can message everyone');
            label = 'Everyone';
            eventId = null;
          case MessageAudience.managers:
            label = 'Managers and leads';
            eventId = null;
          case MessageAudience.level:
            final level = _arena.levels.where((l) => l.id == draft.audienceId).firstOrNull;
            if (level == null) throw const AppFailure('Unknown level');
            if (!venueWide && !session.grants.any((g) => g.scopeType == 'level' && g.scopeId == level.id && (g.permissions.contains(Perm.viewLive) || g.permissions.contains(Perm.manageSchedule)))) {
              throw const AppFailure('You can only message storefronts in your area');
            }
            label = 'Level: ${level.name}';
          case MessageAudience.storefront:
            final sf = _arena.storefronts.where((f) => f.id == draft.audienceId).firstOrNull;
            if (sf == null) throw const AppFailure('Unknown storefront');
            if (!scope.contains(sf.id)) throw const AppFailure('You can only message storefronts in your area');
            label = sf.name;
          case MessageAudience.worker:
            final w = _workers[draft.audienceId];
            if (w == null) throw const AppFailure('Unknown person');
            final cutoff = _commsNow().subtract(const Duration(days: 1));
            final inArea = _shifts.values.any((s) => s.workerId == w.id && s.status == ShiftStatus.assigned && s.callTime.isAfter(cutoff) && scope.contains(s.storefrontId));
            if (!venueWide && !session.canVenueWide(Perm.viewWorkers) && !inArea) {
              throw const AppFailure('You can only message people working in your area');
            }
            label = w.displayName;
        }
        if (draft.audience == MessageAudience.level || draft.audience == MessageAudience.storefront) {
          eventId ??= _commsCurrentEvent()?.id;
          final event = eventId == null ? null : _events[eventId];
          if (event != null) label = '$label · ${event.name}';
        }
        final m = CommsMessage(
          id: _id(),
          senderId: session.userId,
          senderName: session.displayName,
          audience: draft.audience,
          audienceId: draft.audience == MessageAudience.everyone || draft.audience == MessageAudience.managers ? null : draft.audienceId,
          audienceLabel: label,
          eventId: eventId,
          body: body,
          urgent: draft.urgent,
          createdAt: _commsNow(),
        );
        final stored = _commsStore(m, me.key);
        _commsNotifyMessage(stored);
        _commsChanged();
        return stored.copyWith();
      });

  @override
  Future<void> markMessagesRead(AppSession session, List<String> ids) => _delay(() {
        final me = _commsMe(session);
        final now = _commsNow();
        var changed = false;
        for (final m in _commsMessages) {
          if (!ids.contains(m.id) || !_commsCanSee(m, me)) continue;
          final reads = _commsReads.putIfAbsent(m.id, () => {});
          if (reads.containsKey(me.key)) continue;
          reads[me.key] = now;
          changed = true;
        }
        final list = _notifications[session.userId] ?? [];
        for (var i = 0; i < list.length; i++) {
          final n = list[i];
          if (n.isMessage && !n.isRead && ids.contains(n.data['message_id'])) {
            list[i] = n.copyWith(readAt: now);
            changed = true;
          }
        }
        if (changed) _commsChanged();
      });

  // ---- Announcements ----

  Announcement _commsWithAck(Announcement a, String key) {
    final ack = _commsAcks[a.id]?[key];
    return Announcement(
      id: a.id,
      title: a.title,
      body: a.body,
      audience: a.audience,
      requiresAck: a.requiresAck,
      isPolicy: a.isPolicy,
      documentPath: a.documentPath,
      publishedAt: a.publishedAt,
      expiresAt: a.expiresAt,
      createdByName: a.createdByName,
      ackedAt: ack?.$1,
      typedName: ack?.$2 ?? '',
    );
  }

  bool _commsCurrent(Announcement a) {
    final now = _commsNow();
    return !a.publishedAt.isAfter(now) && (a.expiresAt == null || a.expiresAt!.isAfter(now));
  }

  @override
  Future<List<Announcement>> myAnnouncements(AppSession session) => _delay(() {
        final me = _commsMe(session);
        final list = [
          for (final a in _commsAnnouncements)
            if (_commsCurrent(a) && _commsInAudience(a.audience, me)) _commsWithAck(a, me.key),
        ];
        list.sort((a, b) {
          if (a.needsMyAck != b.needsMyAck) return a.needsMyAck ? -1 : 1;
          if (a.needsMyAck && a.isPolicy != b.isPolicy) return a.isPolicy ? -1 : 1;
          return b.publishedAt.compareTo(a.publishedAt);
        });
        return list;
      });

  @override
  Future<List<Announcement>> announcementSummaries(AppSession session) => _delay(() {
        _commsSeed();
        if (!_commsCanManageAnnouncements(session)) throw const AppFailure('Not authorized');
        final people = _commsPeople;
        return [
          for (final a in _commsAnnouncements.reversed)
            () {
              final audience = [for (final p in people) if (_commsInAudience(a.audience, p)) p.key];
              final acks = _commsAcks[a.id] ?? const {};
              return Announcement(
                id: a.id,
                title: a.title,
                body: a.body,
                audience: a.audience,
                requiresAck: a.requiresAck,
                isPolicy: a.isPolicy,
                documentPath: a.documentPath,
                publishedAt: a.publishedAt,
                expiresAt: a.expiresAt,
                createdByName: a.createdByName,
                audienceCount: audience.length,
                ackCount: audience.where(acks.containsKey).length,
              );
            }(),
        ]..sort((a, b) => b.publishedAt.compareTo(a.publishedAt));
      });

  @override
  Future<Announcement> publishAnnouncement(AppSession session, AnnouncementDraft draft) => _delay(() {
        final me = _commsMe(session);
        if (!_commsCanManageAnnouncements(session)) throw const AppFailure('Not authorized');
        if (draft.title.trim().isEmpty) throw const AppFailure('Give the announcement a title');
        final doc = draft.documentPath;
        if (doc != null && !doc.startsWith('${session.venue.id}/announcements/')) {
          throw const AppFailure('The document must be uploaded for this venue');
        }
        final a = Announcement(
          id: _id(),
          title: draft.title.trim(),
          body: draft.body,
          audience: draft.audience,
          requiresAck: draft.requiresAck || draft.isPolicy,
          isPolicy: draft.isPolicy,
          documentPath: doc,
          publishedAt: _commsNow(),
          expiresAt: draft.expiresAt,
          createdByName: session.displayName,
        );
        _commsAnnouncements.add(a);
        _commsNotifyAnnouncement(a, exceptKey: me.key);
        _commsChanged();
        final audience = _commsPeople.where((p) => p.key != me.key && _commsInAudience(a.audience, p)).length;
        return Announcement(
          id: a.id,
          title: a.title,
          body: a.body,
          audience: a.audience,
          requiresAck: a.requiresAck,
          isPolicy: a.isPolicy,
          documentPath: a.documentPath,
          publishedAt: a.publishedAt,
          expiresAt: a.expiresAt,
          createdByName: a.createdByName,
          audienceCount: audience,
        );
      });

  @override
  Future<void> acknowledgeAnnouncement(AppSession session, String id, {String typedName = ''}) => _delay(() {
        final me = _commsMe(session);
        final a = _commsAnnouncements.where((x) => x.id == id).firstOrNull;
        if (a == null || !_commsCurrent(a) || !_commsInAudience(a.audience, me)) throw const AppFailure('Announcement not found');
        if (!a.requiresAck) throw const AppFailure('This announcement does not need an acknowledgment');
        final name = typedName.trim();
        if (a.isPolicy && name.length < 2) throw const AppFailure('Type your full name to acknowledge this policy');
        _commsAcks.putIfAbsent(id, () => {}).putIfAbsent(me.key, () => (_commsNow(), name));
        final list = _notifications[session.userId] ?? [];
        for (var i = 0; i < list.length; i++) {
          if (list[i].isAnnouncement && !list[i].isRead && list[i].data['announcement_id'] == id) list[i] = list[i].copyWith(readAt: _commsNow());
        }
        _commsChanged();
      });

  @override
  Future<AckReport> ackReport(AppSession session, String id) => _delay(() {
        _commsSeed();
        if (!_commsCanManageAnnouncements(session)) throw const AppFailure('Not authorized');
        final a = _commsAnnouncements.firstWhere((x) => x.id == id, orElse: () => throw const AppFailure('Announcement not found'));
        final acks = _commsAcks[id] ?? const {};
        final people = [
          for (final p in _commsPeople)
            if (_commsInAudience(a.audience, p))
              AckPerson(
                userId: p.session?.userId,
                workerId: p.worker?.id,
                name: p.name,
                employeeNumber: p.worker?.employeeNumber ?? '',
                workerType: p.worker?.type.code,
                ackedAt: acks[p.key]?.$1,
                typedName: acks[p.key]?.$2 ?? '',
              ),
        ];
        String last(AckPerson p) => p.name.split(' ').last;
        people.sort((x, y) {
          if (x.acked != y.acked) return x.acked ? 1 : -1;
          return last(x).compareTo(last(y));
        });
        return AckReport(announcement: a, people: people);
      });

  @override
  Future<int> remindUnacknowledged(AppSession session, String id) => _delay(() {
        _commsSeed();
        if (!_commsCanManageAnnouncements(session)) throw const AppFailure('Not authorized');
        final a = _commsAnnouncements.firstWhere((x) => x.id == id, orElse: () => throw const AppFailure('Announcement not found'));
        if (!a.requiresAck) throw const AppFailure('This announcement does not need an acknowledgment');
        final now = _commsNow();
        final hour = '${now.year}-${now.month}-${now.day}-${now.hour}';
        final acks = _commsAcks[id] ?? const {};
        var count = 0;
        for (final p in _commsPeople) {
          if (!_commsInAudience(a.audience, p) || acks.containsKey(p.key)) continue;
          if (!_commsReminderKeys.add('$id:${p.key}:$hour')) continue;
          count++;
          final s = p.session;
          if (s != null) {
            _commsNotify(s.userId,
                kind: 'announcement',
                title: '${p.language == 'es' ? 'Recordatorio: lea y confirme ' : 'Reminder: please read and acknowledge '}${a.title}',
                body: a.body,
                data: {'announcement_id': a.id, 'reminder': true});
          }
        }
        if (count > 0) _commsChanged();
        return count;
      });

  @override
  Future<String> uploadDocument(AppSession session, String fileName, Uint8List bytes, String mimeType) => _delay(() {
        if (!_commsCanManageAnnouncements(session)) throw const AppFailure('Not authorized');
        if (bytes.length > 10 * 1024 * 1024) throw const AppFailure('Documents are limited to 10 MB');
        final safe = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
        final path = '${session.venue.id}/announcements/${_id()}-$safe';
        _commsDocs[path] = (fileName, mimeType, bytes);
        return path;
      });

  @override
  Future<DocumentFile> openDocument(AppSession session, String path) => _delay(() {
        _commsSeed();
        final doc = _commsDocs[path];
        if (doc == null) throw const AppFailure('That document is not available');
        return DocumentFile(name: doc.$1, mimeType: doc.$2, bytes: doc.$3);
      });

  // ---- Notifications ----

  @override
  Future<List<AppNotification>> myNotifications(AppSession session, {int limit = 100}) => _delay(() {
        _commsSeed();
        final list = [...(_notifications[session.userId] ?? const <AppNotification>[])]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return list.take(limit).toList();
      });

  @override
  Future<void> markNotificationsRead(AppSession session, {List<String>? ids}) => _delay(() {
        final list = _notifications[session.userId] ?? [];
        final now = _commsNow();
        for (var i = 0; i < list.length; i++) {
          if (!list[i].isRead && (ids == null || ids.contains(list[i].id))) list[i] = list[i].copyWith(readAt: now);
        }
        _commsChanged();
      });

  /// The demo has no server push: changes made here are announced at once, and the
  /// notification list is checked every two seconds for ones other areas added.
  @override
  Stream<void> commsChanges(AppSession session) {
    late final StreamController<void> controller;
    StreamSubscription<void>? sub;
    Timer? timer;
    String signature() {
      final list = _notifications[session.userId] ?? const <AppNotification>[];
      return '${list.length}:${list.where((n) => !n.isRead).length}';
    }

    controller = StreamController<void>(
      onListen: () {
        sub = _commsBus.stream.listen((_) => controller.add(null));
        var last = signature();
        timer = Timer.periodic(const Duration(seconds: 2), (_) {
          final now = signature();
          if (now != last) {
            last = now;
            controller.add(null);
          }
        });
      },
      onCancel: () {
        timer?.cancel();
        return sub?.cancel();
      },
    );
    return controller.stream;
  }

  // ---- Preferences ----

  @override
  Future<NotificationPrefs> notificationPrefs(AppSession session) => _delay(() {
        final w = session.workerId == null ? null : _workers[session.workerId];
        final saved = _commsPrefs[session.userId] ?? const NotificationPrefs();
        return NotificationPrefs(
          push: saved.push,
          email: saved.email,
          quietStart: saved.quietStart,
          quietEnd: saved.quietEnd,
          hasStaffRecord: w != null,
          emailAddress: w?.email ?? saved.emailAddress,
        );
      });

  @override
  Future<NotificationPrefs> saveNotificationPrefs(AppSession session, NotificationPrefs prefs) async {
    if ((prefs.quietStart == null) != (prefs.quietEnd == null)) throw const AppFailure('Give both a start and an end for quiet hours');
    if (prefs.emailAddress.isNotEmpty && !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(prefs.emailAddress) && session.workerId == null) {
      throw const AppFailure('Enter a valid email address');
    }
    _commsPrefs[session.userId] = prefs;
    return notificationPrefs(session);
  }

  @override
  Future<void> registerPushToken(AppSession session, String token, String platform) async {}

  @override
  Future<void> removePushToken(AppSession session, String token) async {}
}
