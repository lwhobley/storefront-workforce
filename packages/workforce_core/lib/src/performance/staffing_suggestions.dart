/// Staffing suggestions: how many people each storefront needs by role for an event,
/// from how past similar events were staffed.
///
/// The rule: take past events of the same type whose crowd was within 25% of this
/// event's expected crowd (the closest six at most), preferring events where nearly every
/// position was filled. For each storefront, average how many people worked each role
/// there, scaled by the crowd size ("10 cashiers for 9,000 fans" becomes 11 for 10,000),
/// and round. With no similar event, use the storefront's configured staffing.
library;

import 'dart:math' as math;

import '../model/entities.dart';
import '../model/enums.dart';

/// How one past event was staffed.
class PastEventStaffing {
  const PastEventStaffing({
    required this.eventId,
    required this.eventTypeCode,
    required this.startTime,
    required this.expectedAttendance,
    this.actualAttendance,
    required this.needed,
    required this.staffed,
  });

  final String eventId;
  final String eventTypeCode;
  final DateTime startTime;
  final int expectedAttendance;
  final int? actualAttendance;

  /// storefront id -> role -> positions asked for.
  final Map<String, Map<String, int>> needed;

  /// storefront id -> role -> positions that had a person.
  final Map<String, Map<String, int>> staffed;

  /// The crowd that came, or the forecast when the count was not recorded.
  int get attendance => (actualAttendance ?? 0) > 0 ? actualAttendance! : expectedAttendance;

  int get neededTotal => _total(needed);
  int get staffedTotal => _total(staffed);

  /// Share of asked-for positions that had a person (1 when nothing was asked for).
  double get fillRate => neededTotal == 0 ? 1 : math.min(1, staffedTotal / neededTotal);

  static int _total(Map<String, Map<String, int>> m) => m.values.fold(0, (s, r) => s + r.values.fold(0, (a, b) => a + b));

  /// Builds the record from the event's needs and shifts (any status; only positions that
  /// were assigned or sent home count as staffed).
  factory PastEventStaffing.fromSchedule(Event event, Iterable<StaffingNeed> needs, Iterable<Shift> shifts) {
    final needed = <String, Map<String, int>>{};
    for (final n in needs) {
      if (n.eventId != null && n.eventId != event.id) continue;
      if (n.count <= 0) continue;
      final r = needed.putIfAbsent(n.storefrontId, () => {});
      r[n.jobRoleCode] = (r[n.jobRoleCode] ?? 0) + n.count;
    }
    final staffed = <String, Map<String, int>>{};
    for (final s in shifts) {
      if (s.eventId != event.id || s.workerId == null) continue;
      if (s.status != ShiftStatus.assigned && s.status != ShiftStatus.released) continue;
      final r = staffed.putIfAbsent(s.storefrontId, () => {});
      r[s.jobRoleCode] = (r[s.jobRoleCode] ?? 0) + 1;
    }
    return PastEventStaffing(
      eventId: event.id,
      eventTypeCode: event.eventTypeCode,
      startTime: event.startTime,
      expectedAttendance: event.expectedAttendance,
      actualAttendance: event.actualAttendance,
      needed: needed,
      staffed: staffed,
    );
  }
}

class StaffingSuggestionRules {
  const StaffingSuggestionRules({this.attendanceTolerance = 0.25, this.maxEvents = 6, this.goodFillRate = 0.9});

  /// Past crowds within this share of the expected crowd count as similar (0.25 = ±25%).
  final double attendanceTolerance;

  /// Use at most this many past events (the closest crowds).
  final int maxEvents;

  /// Events with at least this share of positions filled are preferred. Others are used
  /// only when there are no such events.
  final double goodFillRate;
}

/// The suggestion for one storefront.
class StorefrontSuggestion {
  const StorefrontSuggestion({
    required this.storefrontId,
    required this.counts,
    required this.explanation,
    this.basedOn = const [],
    this.fallback = false,
  });

  final String storefrontId;

  /// role -> suggested headcount.
  final Map<String, int> counts;

  /// One line: "Based on 4 past hockey games with 9,000–11,000 fans."
  final String explanation;

  /// The past events used (empty when [fallback]).
  final List<String> basedOn;

  /// True when no similar event was found and the storefront's usual staffing is used.
  final bool fallback;

  int get total => counts.values.fold(0, (a, b) => a + b);
}

/// Suggests headcount by role for each of [storefrontIds] at an event of
/// [eventTypeCode] expecting [expectedAttendance] people.
///
/// [typeName] is the event type's display name ("Hockey game"), used in the explanation.
/// [defaults] are the storefronts' configured needs, used when nothing similar exists.
Map<String, StorefrontSuggestion> suggestStaffing({
  required String eventTypeCode,
  required int expectedAttendance,
  required Iterable<String> storefrontIds,
  required Iterable<PastEventStaffing> history,
  required Iterable<StaffingNeed> defaults,
  String typeName = '',
  String? excludeEventId,
  StaffingSuggestionRules rules = const StaffingSuggestionRules(),
}) {
  final similar = similarEvents(
    eventTypeCode: eventTypeCode,
    expectedAttendance: expectedAttendance,
    history: history,
    excludeEventId: excludeEventId,
    rules: rules,
  );
  final noun = _plural(typeName).toLowerCase();

  final out = <String, StorefrontSuggestion>{};
  for (final sf in storefrontIds) {
    // Events where this storefront was open (asked for or had people).
    final used = [for (final e in similar) if ((e.needed[sf]?.isNotEmpty ?? false) || (e.staffed[sf]?.isNotEmpty ?? false)) e];
    if (used.isEmpty) {
      out[sf] = StorefrontSuggestion(
        storefrontId: sf,
        counts: {for (final d in defaults) if (d.storefrontId == sf && d.eventId == null) d.jobRoleCode: d.count},
        explanation: similar.isEmpty
            ? 'No past $noun with a similar crowd; using the usual staffing.'
            : 'Not open at similar past $noun; using the usual staffing.',
        fallback: true,
      );
      continue;
    }
    final roles = <String>{for (final e in used) ...?e.staffed[sf]?.keys, for (final e in used) ...?e.needed[sf]?.keys};
    final counts = <String, int>{};
    for (final role in roles) {
      var sum = 0.0;
      var anyone = false;
      for (final e in used) {
        final n = e.staffed[sf]?[role] ?? 0;
        if (n > 0) anyone = true;
        final ratio = expectedAttendance > 0 && e.attendance > 0 ? expectedAttendance / e.attendance : 1.0;
        sum += n * ratio;
      }
      final avg = sum / used.length;
      // Never round a role that people actually worked down to nobody.
      counts[role] = anyone ? math.max(1, avg.round()) : 0;
    }
    counts.removeWhere((_, v) => v == 0);
    out[sf] = StorefrontSuggestion(
      storefrontId: sf,
      counts: counts,
      explanation: _explain(used, noun),
      basedOn: [for (final e in used) e.eventId],
    );
  }
  return out;
}

/// The past events [suggestStaffing] would use: same type, crowd within the tolerance,
/// well-filled ones first, closest crowds first, at most [StaffingSuggestionRules.maxEvents].
/// With no expected attendance, every past event of the type counts (most recent first).
List<PastEventStaffing> similarEvents({
  required String eventTypeCode,
  required int expectedAttendance,
  required Iterable<PastEventStaffing> history,
  String? excludeEventId,
  StaffingSuggestionRules rules = const StaffingSuggestionRules(),
}) {
  final sameType = [
    for (final e in history)
      if (e.eventTypeCode == eventTypeCode && e.eventId != excludeEventId && e.staffedTotal > 0) e,
  ];
  double distance(PastEventStaffing e) =>
      expectedAttendance <= 0 || e.attendance <= 0 ? 0 : (math.log(e.attendance / expectedAttendance)).abs();
  final within = [
    for (final e in sameType)
      if (expectedAttendance <= 0 ||
          (e.attendance >= expectedAttendance * (1 - rules.attendanceTolerance) &&
              e.attendance <= expectedAttendance * (1 + rules.attendanceTolerance)))
        e,
  ];
  final good = [for (final e in within) if (e.fillRate >= rules.goodFillRate) e];
  final pool = good.isNotEmpty ? good : within;
  pool.sort((a, b) {
    final c = distance(a).compareTo(distance(b));
    if (c != 0) return c;
    final d = b.startTime.compareTo(a.startTime);
    return d != 0 ? d : a.eventId.compareTo(b.eventId);
  });
  return pool.take(rules.maxEvents).toList();
}

String _explain(List<PastEventStaffing> used, String noun) {
  // Rounded to the nearest hundred for reading ("4,611" shows as "4,600").
  final crowds = [for (final e in used) e.attendance >= 1000 ? (e.attendance / 100).round() * 100 : e.attendance]..sort();
  final lo = crowds.first, hi = crowds.last;
  final what = used.length == 1 ? '1 past ${_singular(noun)}' : '${used.length} past $noun';
  if (hi <= 0) return 'Based on $what.';
  final range = lo == hi ? formatCount(lo) : '${formatCount(lo)}–${formatCount(hi)}';
  return 'Based on $what with $range fans.';
}

/// 9500 -> "9,500".
String formatCount(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String _plural(String name) {
  final n = name.trim();
  if (n.isEmpty) return 'events';
  if (n.endsWith('s')) return n;
  return '${n}s';
}

String _singular(String plural) => plural.endsWith('s') ? plural.substring(0, plural.length - 1) : plural;
