import 'dart:convert';

import 'package:test/test.dart';
import 'package:workforce_core/src/layout/cutx_layout.dart';
import 'package:workforce_core/src/model/entities.dart';
import 'package:workforce_core/src/model/enums.dart';
import 'package:workforce_core/src/sample/sample_arena.dart';

final _now = DateTime.utc(2026, 11, 4, 23, 30);
final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

/// Calendar date of an event in venue time. Events start between 14:00 and 20:00 Central,
/// so six hours back from the UTC start always lands on the local date.
DateTime _eventDay(Event e) {
  final d = e.startTime.subtract(const Duration(hours: 6));
  return DateTime.utc(d.year, d.month, d.day);
}

bool _certValid(Worker w, String type, DateTime day) => w.certifications.any(
  (c) =>
      c.typeCode == type &&
      (c.issuedOn == null || !day.isBefore(c.issuedOn!)) &&
      (c.expiresOn == null || !day.isAfter(c.expiresOn!)),
);

void main() {
  final arena = SampleArena.generate(now: _now);
  final workers = {for (final w in arena.workers) w.id: w};
  final events = {for (final e in arena.events) e.id: e};
  final storefronts = {for (final s in arena.storefronts) s.id: s};
  final staffed = arena.shifts.where((s) => s.workerId != null).toList();

  group('determinism', () {
    test('same now and seed give identical data', () {
      final again = SampleArena.generate(now: _now);
      expect(jsonEncode(again.toJson()), jsonEncode(arena.toJson()));
    });

    test('a different seed gives different data', () {
      final other = SampleArena.generate(now: _now, seed: 7);
      expect(other.venue.id, isNot(arena.venue.id));
      expect(
        other.workers.first.lastName == arena.workers.first.lastName &&
            other.workers[1].lastName == arena.workers[1].lastName &&
            other.workers[2].lastName == arena.workers[2].lastName,
        isFalse,
      );
    });

    test('the venue layout does not depend on now', () {
      final later = SampleArena.generate(now: _now.add(const Duration(days: 3)));
      expect(later.storefronts.map((s) => s.id), arena.storefronts.map((s) => s.id));
      expect(later.stations.map((s) => s.id), arena.stations.map((s) => s.id));
      expect(later.workers, hasLength(arena.workers.length));
      expect(later.liveEvent!.startTime, _now.add(const Duration(days: 3, minutes: 15)));
    });
  });

  group('counts', () {
    test('venue layout', () {
      expect(arena.organization['name'], 'Pecan Valley Sports & Entertainment');
      expect(arena.venue.name, 'Pecan Valley Arena');
      expect(arena.venue.timeZone, 'America/Chicago');
      expect(arena.levels.map((l) => l.name), ['Concourse']);
      expect(arena.storefronts, hasLength(40));
      int kind(StorefrontKind k) => arena.storefronts.where((s) => s.kind == k).length;
      expect(kind(StorefrontKind.bar), 8);
      expect(kind(StorefrontKind.portableCart), 6);
      expect(kind(StorefrontKind.kiosk), 4);
      expect(kind(StorefrontKind.permanentStand), 22);
      expect(arena.storefronts.every((s) => s.levelId == arena.levels.single.id), isTrue);
      // Every storefront sits on the CUTX concourse, outside the bowl, labeled by a real section.
      final sections = {for (final s in cutxLayout.sections) s.name};
      expect(arena.storefronts.every((s) => sections.contains(s.section)), isTrue);
      expect(arena.venue.settings['map'], {'layout': 'cutx'});
      for (final s in arena.storefronts) {
        expect(arena.stations.where((st) => st.storefrontId == s.id), isNotEmpty, reason: s.code);
      }
    });

    test('job roles and certification types', () {
      expect(arena.jobRoles.map((r) => r.code), containsAll(['cashier', 'cook', 'runner', 'bartender', 'lead']));
      final bartender = arena.jobRoles.firstWhere((r) => r.code == 'bartender');
      expect(bartender.requiredCertifications, ['tabc']);
      expect(bartender.minimumAge, 18);
      expect(bartender.tipped, isTrue);
      expect(arena.certificationTypes.map((c) => c.code), ['food_handler', 'tabc']);
    });

    test('default staffing lands between 230 and 260 positions', () {
      final total = arena.staffingNeeds.fold<int>(0, (s, n) => s + n.count);
      expect(total, inInclusiveRange(230, 260));
      expect(arena.staffingNeeds.every((n) => n.eventId == null), isTrue);
    });

    test('roster mix', () {
      int type(WorkerType t) => arena.workers.where((w) => w.type == t).length;
      expect(arena.workers, hasLength(300));
      expect(type(WorkerType.regular), 180);
      expect(type(WorkerType.temp), 40);
      expect(type(WorkerType.npo), 80);
      expect(arena.agencies, hasLength(2));
      expect(arena.npoGroups, hasLength(8));
      expect(arena.npoGroups.where((g) => !g.w9OnFile), hasLength(1));
      final today = DateTime.utc(2026, 11, 4);
      final regular = arena.workers.where((w) => w.type == WorkerType.regular);
      expect(regular.where((w) => w.ageOn(today)! >= 16 && w.ageOn(today)! < 18), hasLength(12));
      expect(regular.where((w) => w.ageOn(today)! < 16), hasLength(4));
      expect(arena.workers.every((w) => w.ageOn(today)! >= 14 && w.ageOn(today)! <= 65), isTrue);
      expect(arena.workers.every((w) => w.jobRoles.isNotEmpty && w.jobRoles.length <= 3), isTrue);
      final spanish = arena.workers.where((w) => w.preferredLanguage == 'es').length;
      expect(spanish, inInclusiveRange(50, 100));
    });

    test('events', () {
      int status(EventStatus s) => arena.events.where((e) => e.status == s).length;
      expect(status(EventStatus.completed), 14);
      expect(status(EventStatus.live), 1);
      expect(status(EventStatus.scheduled), 10);
      expect(arena.events.map((e) => e.eventTypeCode).toSet(), {'hockey', 'concert', 'family_show'});
      for (final e in arena.events) {
        expect(e.expectedAttendance, inInclusiveRange(4000, 12500));
        expect(e.actualAttendance != null, e.status == EventStatus.completed);
        expect(e.source == 'manual' || e.externalId != null, isTrue);
      }
      expect(arena.events.last.startTime.isBefore(DateTime.utc(2027, 1, 1)), isTrue);
      expect(arena.events.first.startTime.isAfter(DateTime.utc(2026, 9, 15)), isTrue);
      expect(arena.punches.length, lessThan(25000));
    });

    test('open positions: about 1% for past events, 3-6% for live and upcoming', () {
      for (final e in arena.events) {
        final shifts = arena.shifts.where((s) => s.eventId == e.id).toList();
        final open = shifts.where((s) => s.workerId == null).length / shifts.length;
        if (e.status == EventStatus.completed) {
          expect(open, lessThan(0.06), reason: e.name);
        } else {
          expect(open, inInclusiveRange(0.02, 0.08), reason: e.name);
        }
      }
    });
  });

  group('uniqueness', () {
    test('ids are unique UUIDs', () {
      final ids = <String>[
        arena.organization['id']!,
        arena.venue.id,
        ...arena.levels.map((x) => x.id),
        ...arena.storefronts.map((x) => x.id),
        ...arena.stations.map((x) => x.id),
        ...arena.agencies.map((x) => x.id),
        ...arena.npoGroups.map((x) => x.id),
        ...arena.workers.map((x) => x.id),
        for (final w in arena.workers) ...w.certifications.map((c) => c.id),
        ...arena.events.map((x) => x.id),
        ...arena.shifts.map((x) => x.id),
        ...arena.punches.map((x) => x.id),
      ];
      expect(ids.toSet(), hasLength(ids.length));
      for (final id in ids) {
        expect(_uuid.hasMatch(id), isTrue, reason: id);
      }
    });

    test('employee numbers, storefront codes and payroll codes', () {
      final numbers = arena.workers.map((w) => w.employeeNumber).toList();
      expect(numbers.toSet(), hasLength(numbers.length));
      for (final w in arena.workers) {
        final prefix = switch (w.type) {
          WorkerType.regular => 'E',
          WorkerType.temp => 'T',
          WorkerType.npo => 'N',
        };
        expect(w.employeeNumber, startsWith(prefix));
        if (w.type == WorkerType.regular) {
          expect(w.paycomEmployeeCode, matches(RegExp(r'^[A-Z0-9]{4}$')));
        } else {
          expect(w.paycomEmployeeCode, isEmpty);
        }
      }
      final paycom = arena.workers.where((w) => w.type == WorkerType.regular).map((w) => w.paycomEmployeeCode);
      expect(paycom.toSet(), hasLength(180));
      final codes = arena.storefronts.map((s) => s.code).toList();
      expect(codes.toSet(), hasLength(40));
      expect(codes.every((c) => c.length <= 20), isTrue);
      final emails = arena.workers.map((w) => w.email).toList();
      expect(emails.toSet(), hasLength(300));
      expect(emails.every((e) => e.endsWith('@example.com')), isTrue);
      expect(arena.workers.every((w) => w.phone.contains('555-')), isTrue);
    });

    test('map positions are within 0..1 with at most 4 decimals', () {
      for (final s in arena.storefronts) {
        for (final v in [s.mapX, s.mapY]) {
          expect(v, inInclusiveRange(0, 1));
          expect((v * 10000).roundToDouble(), closeTo(v * 10000, 1e-6));
        }
      }
    });
  });

  group('referential integrity', () {
    test('shifts point at existing storefronts, stations, events and workers', () {
      final stations = {for (final s in arena.stations) s.id: s};
      final roles = arena.jobRoles.map((r) => r.code).toSet();
      for (final s in arena.shifts) {
        expect(storefronts, contains(s.storefrontId));
        expect(events, contains(s.eventId));
        expect(roles, contains(s.jobRoleCode));
        if (s.workerId != null) expect(workers, contains(s.workerId));
        if (s.stationId != null) expect(stations[s.stationId]!.storefrontId, s.storefrontId);
        expect(s.status == ShiftStatus.open, s.workerId == null);
      }
    });

    test('shifts only at storefronts open for the event', () {
      final open = {
        for (final es in arena.eventStorefronts)
          if (es.isOpen) '${es.eventId}/${es.storefrontId}',
      };
      expect(arena.eventStorefronts, hasLength(40 * arena.events.length));
      for (final s in arena.shifts) {
        expect(open, contains('${s.eventId}/${s.storefrontId}'));
      }
      for (final n in arena.eventStaffingNeeds) {
        expect(n.eventId, isNotNull);
        expect(open, contains('${n.eventId}/${n.storefrontId}'));
      }
    });

    test('temps have an agency, nonprofit members a group, and nobody else either', () {
      final agencies = arena.agencies.map((a) => a.id).toSet();
      final groups = arena.npoGroups.map((g) => g.id).toSet();
      for (final w in arena.workers) {
        expect(w.agencyId != null, w.type == WorkerType.temp);
        expect(w.npoGroupId != null, w.type == WorkerType.npo);
        if (w.agencyId != null) expect(agencies, contains(w.agencyId));
        if (w.npoGroupId != null) expect(groups, contains(w.npoGroupId));
        for (final c in w.certifications) {
          expect(c.workerId, w.id);
        }
      }
    });

    test('punches belong to a staffed shift of the same worker and event', () {
      final shifts = {for (final s in arena.shifts) s.id: s};
      for (final p in arena.punches) {
        final s = shifts[p.shiftId]!;
        expect(p.workerId, s.workerId);
        expect(p.eventId, s.eventId);
        expect(p.venueId, arena.venue.id);
        final lag = p.receivedAt!.difference(p.occurredAt).inSeconds;
        expect(lag, inInclusiveRange(0, 90));
      }
    });
  });

  group('scheduling rules', () {
    test('nobody is booked twice in one event', () {
      final seen = <String>{};
      for (final s in staffed) {
        expect(seen.add('${s.eventId}/${s.workerId}'), isTrue, reason: '${s.workerId} at ${s.eventId}');
      }
    });

    test('workers only work roles they are trained for', () {
      for (final s in staffed) {
        expect(workers[s.workerId]!.jobRoles, contains(s.jobRoleCode));
      }
    });

    test('bartenders are 18+ with a valid TABC on the event date', () {
      for (final s in staffed.where((s) => s.jobRoleCode == 'bartender')) {
        final w = workers[s.workerId]!;
        final day = _eventDay(events[s.eventId]!);
        expect(w.ageOn(day), greaterThanOrEqualTo(18));
        expect(_certValid(w, 'tabc', day), isTrue, reason: w.employeeNumber);
      }
    });

    test('cooks and leads have a valid food handler card on the event date', () {
      for (final s in staffed.where((s) => s.jobRoleCode == 'cook' || s.jobRoleCode == 'lead')) {
        final w = workers[s.workerId]!;
        expect(_certValid(w, 'food_handler', _eventDay(events[s.eventId]!)), isTrue, reason: w.employeeNumber);
      }
    });

    test('minors are never bartenders and never trained as one', () {
      for (final s in staffed) {
        final age = workers[s.workerId]!.ageOn(_eventDay(events[s.eventId]!))!;
        if (age < 18) expect(s.jobRoleCode, isNot('bartender'));
        if (age < 16) expect(s.jobRoleCode, anyOf('cashier', 'runner'));
      }
      final today = DateTime.utc(2026, 11, 4);
      for (final w in arena.workers.where((w) => w.ageOn(today)! < 18)) {
        expect(w.jobRoles, isNot(contains('bartender')));
        if (w.ageOn(today)! < 16) expect(w.jobRoles.every((r) => r == 'cashier' || r == 'runner'), isTrue);
      }
    });

    test('14 and 15 year olds work evenings only in the deliberate live-event cases', () {
      final evening = staffed.where((s) {
        final e = events[s.eventId]!;
        return e.eventTypeCode != 'family_show' && workers[s.workerId]!.ageOn(_eventDay(e))! < 16;
      }).toList();
      expect(evening.length, inInclusiveRange(1, 2));
      expect(evening.every((s) => events[s.eventId]!.status == EventStatus.live), isTrue);
    });

    test('some certifications are expired, expiring soon or missing', () {
      final today = DateTime.utc(2026, 11, 4);
      final certs = [for (final w in arena.workers) ...w.certifications];
      expect(certs.where((c) => c.expiresOn!.isBefore(today)), isNotEmpty);
      expect(
        certs.where((c) => !c.expiresOn!.isBefore(today) && c.expiresOn!.isBefore(today.add(const Duration(days: 30)))),
        isNotEmpty,
      );
      final missing = arena.workers.where(
        (w) =>
            (w.jobRoles.contains('bartender') && !w.certifications.any((c) => c.typeCode == 'tabc')) ||
            (w.jobRoles.contains('cook') && !w.certifications.any((c) => c.typeCode == 'food_handler')),
      );
      expect(missing, isNotEmpty);
    });
  });

  group('live event', () {
    test('exactly one event is live at now', () {
      final live = arena.liveEvent!;
      expect(arena.events.where((e) => e.status == EventStatus.live), hasLength(1));
      expect(live.callTime.isBefore(_now), isTrue);
      expect(live.endTime!.isAfter(_now), isTrue);
      expect(live.startTime, _now.add(const Duration(minutes: 15)));
      expect(live.doorsTime, live.startTime.subtract(const Duration(minutes: 60)));
      expect(live.callTime, live.doorsTime.subtract(const Duration(minutes: 90)));
    });

    test('punches stop at now; most staff are in, a few are missing or on break', () {
      final live = arena.liveEvent!;
      final punches = arena.punches.where((p) => p.eventId == live.id).toList();
      expect(punches.every((p) => !p.occurredAt.isAfter(_now)), isTrue);
      final assigned = staffed.where((s) => s.eventId == live.id).toList();
      final clockedIn = punches.where((p) => p.kind == PunchKind.clockIn).map((p) => p.shiftId).toSet();
      final missing = assigned.where((s) => !clockedIn.contains(s.id)).length;
      expect(missing, inInclusiveRange(4, 8));
      final released = assigned.where((s) => s.status == ShiftStatus.released).toList();
      expect(released.length, inInclusiveRange(1, 2));
      final clockedOut = punches.where((p) => p.kind == PunchKind.clockOut).map((p) => p.shiftId).toSet();
      expect(clockedOut, released.map((s) => s.id).toSet());
      final starts = punches.where((p) => p.kind == PunchKind.breakStart).length;
      final ends = punches.where((p) => p.kind == PunchKind.breakEnd).length;
      expect(starts - ends, greaterThanOrEqualTo(2));
    });

    test('upcoming events have shifts but no punches', () {
      for (final e in arena.events.where((e) => e.status == EventStatus.scheduled)) {
        expect(arena.shifts.where((s) => s.eventId == e.id), isNotEmpty);
        expect(arena.punches.where((p) => p.eventId == e.id), isEmpty);
      }
    });
  });

  group('completed events', () {
    test('releases are numbered in order and clocked out at release', () {
      for (final e in arena.events.where((e) => e.status != EventStatus.scheduled)) {
        final released = arena.shifts.where((s) => s.eventId == e.id && s.status == ShiftStatus.released).toList()
          ..sort((a, b) => a.releaseOrder!.compareTo(b.releaseOrder!));
        expect(released.map((s) => s.releaseOrder), [for (var i = 1; i <= released.length; i++) i]);
        for (final s in released) {
          expect(s.releaseReason, 'Slow stand');
          final out = arena.punches.firstWhere((p) => p.shiftId == s.id && p.kind == PunchKind.clockOut);
          expect(out.occurredAt.difference(s.releasedAt!).inMinutes, inInclusiveRange(0, 5));
        }
      }
    });

    test('punch sequences are well formed', () {
      final byShift = <String, List<Punch>>{};
      for (final p in arena.punches) {
        (byShift[p.shiftId!] ??= []).add(p);
      }
      for (final e in arena.events.where((e) => e.status == EventStatus.completed)) {
        for (final s in staffed.where((s) => s.eventId == e.id)) {
          final ps = byShift[s.id];
          if (ps == null) continue; // called off
          ps.sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
          expect(ps.first.kind, PunchKind.clockIn);
          expect(ps.last.kind, PunchKind.clockOut);
          expect(ps.length.isEven, isTrue);
          for (var i = 1; i < ps.length - 1; i += 2) {
            expect(ps[i].kind, PunchKind.breakStart);
            expect(ps[i + 1].kind, PunchKind.breakEnd);
            expect(ps[i + 1].breakKind, ps[i].breakKind);
          }
        }
      }
    });

    test('most staff punched, a few called off', () {
      final past = staffed.where((s) => events[s.eventId]!.status == EventStatus.completed).toList();
      final punched = arena.punches.map((p) => p.shiftId).toSet();
      final noShows = past.where((s) => !punched.contains(s.id)).length / past.length;
      expect(noShows, inInclusiveRange(0.005, 0.05));
    });
  });
}
