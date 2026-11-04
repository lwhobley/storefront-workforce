import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  final base = DateTime.utc(2026, 10, 1, 0);

  PastEventStaffing past(
    String id,
    int attendance, {
    String type = 'hockey',
    int? actual,
    int daysAgo = 10,
    Map<String, Map<String, int>>? staffed,
    Map<String, Map<String, int>>? needed,
  }) {
    final s = staffed ?? {'sf1': {'cashier': 10, 'lead': 1}};
    return PastEventStaffing(
      eventId: id,
      eventTypeCode: type,
      startTime: base.subtract(Duration(days: daysAgo)),
      expectedAttendance: attendance,
      actualAttendance: actual,
      needed: needed ?? s,
      staffed: s,
    );
  }

  const defaults = [
    StaffingNeed(storefrontId: 'sf1', jobRoleCode: 'cashier', count: 6),
    StaffingNeed(storefrontId: 'sf1', jobRoleCode: 'lead', count: 1),
    StaffingNeed(storefrontId: 'sf2', jobRoleCode: 'bartender', count: 3),
  ];

  test('scales past headcount by the crowd and explains in one line', () {
    final s = suggestStaffing(
      eventTypeCode: 'hockey',
      typeName: 'Hockey game',
      expectedAttendance: 10000,
      storefrontIds: ['sf1'],
      history: [past('a', 9000), past('b', 11000), past('c', 10000), past('d', 9500)],
      defaults: defaults,
    )['sf1']!;
    // 10 * (10000/9000 + 10000/11000 + 1 + 10000/9500) / 4 = 10.18 -> 10.
    expect(s.counts, {'cashier': 10, 'lead': 1});
    expect(s.basedOn.toSet(), {'a', 'b', 'c', 'd'});
    expect(s.fallback, isFalse);
    expect(s.explanation, 'Based on 4 past hockey games with 9,000–11,000 fans.');
    expect(s.total, 11);
  });

  test('a bigger crowd than before gets more people', () {
    final s = suggestStaffing(
      eventTypeCode: 'hockey',
      expectedAttendance: 6000,
      typeName: 'Hockey game',
      storefrontIds: ['sf1'],
      history: [past('a', 5000)],
      defaults: defaults,
    )['sf1']!;
    expect(s.counts['cashier'], 12);
    expect(s.counts['lead'], 1, reason: 'one lead stays one lead');
    expect(s.explanation, 'Based on 1 past hockey game with 5,000 fans.');
  });

  test('uses the recorded crowd over the forecast', () {
    final s = suggestStaffing(
      eventTypeCode: 'hockey',
      expectedAttendance: 8000,
      storefrontIds: ['sf1'],
      history: [past('a', 6000, actual: 8000)],
      defaults: defaults,
    )['sf1']!;
    expect(s.counts['cashier'], 10);
    expect(s.explanation, contains('8,000 fans'));
  });

  test('only the same event type and a similar crowd (within 25%)', () {
    final similar = similarEvents(
      eventTypeCode: 'hockey',
      expectedAttendance: 10000,
      history: [
        past('concert', 10000, type: 'concert'),
        past('small', 7400),
        past('edge-low', 7500),
        past('edge-high', 12500),
        past('big', 12600),
      ],
    );
    expect(similar.map((e) => e.eventId).toSet(), {'edge-low', 'edge-high'});
  });

  test('prefers well-filled events; uses poorly filled ones only when nothing else', () {
    final good = past('good', 10000);
    final poor = past('poor', 10000, staffed: {'sf1': {'cashier': 5}}, needed: {'sf1': {'cashier': 10}});
    expect(poor.fillRate, 0.5);
    expect(similarEvents(eventTypeCode: 'hockey', expectedAttendance: 10000, history: [good, poor]).map((e) => e.eventId), ['good']);
    expect(similarEvents(eventTypeCode: 'hockey', expectedAttendance: 10000, history: [poor]).map((e) => e.eventId), ['poor']);
  });

  test('closest crowds first, at most six, newest breaks ties', () {
    final history = [
      for (var i = 0; i < 9; i++) past('e$i', 10000 + i * 100, daysAgo: 30 - i),
      past('twin', 10000, daysAgo: 1),
    ];
    final similar = similarEvents(eventTypeCode: 'hockey', expectedAttendance: 10000, history: history);
    expect(similar.length, 6);
    expect(similar.map((e) => e.eventId).take(3), ['twin', 'e0', 'e1']);
  });

  test('skips the event itself and past events with nobody staffed', () {
    final similar = similarEvents(
      eventTypeCode: 'hockey',
      expectedAttendance: 10000,
      excludeEventId: 'self',
      history: [past('self', 10000), past('empty', 10000, staffed: const {}, needed: {'sf1': {'cashier': 4}})],
    );
    expect(similar, isEmpty);
  });

  test('falls back to the storefront\'s usual staffing, and says why', () {
    final none = suggestStaffing(
      eventTypeCode: 'concert',
      typeName: 'Concert',
      expectedAttendance: 5000,
      storefrontIds: ['sf1', 'sf2'],
      history: [past('a', 5000)],
      defaults: defaults,
    );
    expect(none['sf1']!.fallback, isTrue);
    expect(none['sf1']!.counts, {'cashier': 6, 'lead': 1});
    expect(none['sf1']!.explanation, 'No past concerts with a similar crowd; using the usual staffing.');

    final closed = suggestStaffing(
      eventTypeCode: 'hockey',
      typeName: 'Hockey game',
      expectedAttendance: 5000,
      storefrontIds: ['sf2'],
      history: [past('a', 5000)],
      defaults: defaults,
    )['sf2']!;
    expect(closed.fallback, isTrue);
    expect(closed.counts, {'bartender': 3});
    expect(closed.explanation, 'Not open at similar past hockey games; using the usual staffing.');
  });

  test('averages over the events where the storefront was open; keeps a worked role at one or more', () {
    final s = suggestStaffing(
      eventTypeCode: 'hockey',
      typeName: 'Hockey game',
      expectedAttendance: 5000,
      storefrontIds: ['sf1'],
      history: [
        past('a', 5000, staffed: {'sf1': {'cashier': 4, 'runner': 1}}),
        past('b', 5000, staffed: {'sf1': {'cashier': 6}}),
        past('c', 5000, staffed: {'sf9': {'cashier': 6}}), // sf1 closed that night
      ],
      defaults: defaults,
    )['sf1']!;
    expect(s.basedOn.toSet(), {'a', 'b'});
    expect(s.counts['cashier'], 5);
    expect(s.counts['runner'], 1, reason: '0.5 rounds to 1 since someone worked it');
    expect(s.explanation, 'Based on 2 past hockey games with 5,000 fans.');
  });

  test('a role asked for but never staffed is not suggested', () {
    final s = suggestStaffing(
      eventTypeCode: 'hockey',
      expectedAttendance: 5000,
      storefrontIds: ['sf1'],
      history: [past('a', 5000, staffed: {'sf1': {'cashier': 4}}, needed: {'sf1': {'cashier': 4, 'cook': 1}})],
      defaults: defaults,
    )['sf1']!;
    expect(s.counts, {'cashier': 4});
  });

  test('no expected crowd: every past event of the type, unscaled', () {
    final s = suggestStaffing(
      eventTypeCode: 'hockey',
      typeName: 'Hockey game',
      expectedAttendance: 0,
      storefrontIds: ['sf1'],
      history: [past('a', 3000), past('b', 9000, staffed: {'sf1': {'cashier': 20, 'lead': 1}})],
      defaults: defaults,
    )['sf1']!;
    expect(s.counts['cashier'], 15);
    expect(s.explanation, 'Based on 2 past hockey games with 3,000–9,000 fans.');
  });

  test('built from an event\'s needs and shifts', () {
    final e = Event(
      id: 'e1',
      venueId: 'v',
      name: 'Game',
      eventTypeCode: 'hockey',
      startTime: base,
      doorsTime: base.subtract(const Duration(hours: 1)),
      callTime: base.subtract(const Duration(hours: 2)),
      expectedAttendance: 4000,
      actualAttendance: 4200,
    );
    Shift shift(String id, String? worker, String role, {ShiftStatus status = ShiftStatus.assigned, String event = 'e1'}) => Shift(
          id: id,
          venueId: 'v',
          eventId: event,
          storefrontId: 'sf1',
          jobRoleCode: role,
          callTime: e.callTime,
          workerId: worker,
          status: status,
        );
    final p = PastEventStaffing.fromSchedule(
      e,
      const [
        StaffingNeed(eventId: 'e1', storefrontId: 'sf1', jobRoleCode: 'cashier', count: 3),
        StaffingNeed(eventId: 'e1', storefrontId: 'sf1', jobRoleCode: 'lead', count: 1),
        StaffingNeed(eventId: 'e2', storefrontId: 'sf1', jobRoleCode: 'cashier', count: 9),
      ],
      [
        shift('1', 'a', 'cashier'),
        shift('2', 'b', 'cashier', status: ShiftStatus.released),
        shift('3', null, 'cashier', status: ShiftStatus.open),
        shift('4', 'c', 'lead'),
        shift('5', 'd', 'cashier', status: ShiftStatus.cancelled),
        shift('6', 'e', 'cashier', event: 'e2'),
      ],
    );
    expect(p.needed, {'sf1': {'cashier': 3, 'lead': 1}});
    expect(p.staffed, {'sf1': {'cashier': 2, 'lead': 1}});
    expect(p.fillRate, 0.75);
    expect(p.attendance, 4200);
  });

  test('number format', () {
    expect(formatCount(0), '0');
    expect(formatCount(950), '950');
    expect(formatCount(9500), '9,500');
    expect(formatCount(1234567), '1,234,567');
  });

  test('with the sample arena: suggestions exist for the next hockey game and are explained', () {
    final arena = SampleArena.generate(now: DateTime.utc(2026, 11, 4, 1, 42));
    final pastEvents = arena.events.where((e) => e.status == EventStatus.completed).toList();
    final history = [
      for (final e in pastEvents) PastEventStaffing.fromSchedule(e, arena.eventStaffingNeeds.where((n) => n.eventId == e.id), arena.shifts),
    ];
    final next = arena.events.firstWhere((e) => e.status == EventStatus.scheduled && e.eventTypeCode == 'hockey');
    final open = {for (final es in arena.eventStorefronts) if (es.eventId == next.id && es.isOpen) es.storefrontId};
    final s = suggestStaffing(
      eventTypeCode: 'hockey',
      typeName: 'Hockey game',
      expectedAttendance: next.expectedAttendance,
      storefrontIds: open,
      history: history,
      defaults: arena.staffingNeeds,
    );
    expect(s.length, open.length);
    expect(s.values.where((x) => !x.fallback), isNotEmpty);
    for (final x in s.values.where((x) => !x.fallback)) {
      expect(x.explanation, matches(RegExp(r'^Based on \d+ past hockey games? with [\d,–]+ fans\.$')));
      expect(x.total, greaterThan(0));
    }
  });
}
