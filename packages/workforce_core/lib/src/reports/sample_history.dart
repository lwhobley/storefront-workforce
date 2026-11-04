/// Past seasons for the sample arena, so the demo's reports have comparisons, trends,
/// retention and overtime to show. Deterministic: the same arena always produces the
/// same history. The sample arena itself is unchanged (its events, schedule and seed
/// stay as they are); this adds, for reports only:
///
/// - two earlier seasons of completed events (the one before has a five-night
///   tournament, so some people reach weekly overtime), plus preseason games this
///   season before the arena's first event, with a four-night tournament;
/// - their staffing, schedule, punches (late arrivals, no-shows, short and missed
///   breaks), call-offs with replacements, and paid NPO payouts;
/// - former staff (inactive) who worked earlier seasons, for turnover;
/// - when each position was created and filled (assignment changes) for every event,
///   including the arena's own, and a few call-offs at the arena's past events;
/// - labor budgets for every event and open storefront;
/// - last seasons' pay rates, bill rates and NPO agreement (the sample pay setup starts
///   August 1, 2026).
///
/// All people and events are fictional.
library;

import 'dart:math';

import '../model/entities.dart';
import '../model/enums.dart';
import '../pay/npo_payouts.dart';
import '../pay/pay_models.dart';
import '../rules/local_time.dart';
import '../rules/venue_rules.dart';
import '../sample/sample_arena.dart';
import '../sample/sample_pay.dart';
import 'seasons.dart';

class SampleHistory {
  const SampleHistory._({
    required this.formerWorkers,
    required this.events,
    required this.eventStorefronts,
    required this.needs,
    required this.shifts,
    required this.punches,
    required this.changes,
    required this.shiftCreatedAt,
    required this.eventBudgetsCents,
    required this.storefrontBudgetsCents,
    required this.tipPools,
    required this.npoPayouts,
    required this.rates,
    required this.billRates,
    required this.npoAgreements,
  });

  /// Inactive people who worked earlier seasons only.
  final List<Worker> formerWorkers;

  /// Events before the arena's own (all completed), oldest first.
  final List<Event> events;
  final List<EventStorefront> eventStorefronts;
  final List<StaffingNeed> needs;
  final List<Shift> shifts;
  final List<Punch> punches;

  /// For these events and the arena's events.
  final List<AssignmentChange> changes;
  final Map<String, DateTime> shiftCreatedAt;

  /// For these events and the arena's events.
  final Map<String, int> eventBudgetsCents;
  final Map<String, Map<String, int>> storefrontBudgetsCents;
  final List<TipPool> tipPools;

  /// Paid payouts for these events (the arena's own are left to the Pay screen).
  final List<NpoPayout> npoPayouts;

  /// Pay setup in force before the sample pay setup starts.
  final List<PayRate> rates;
  final List<AgencyBillRate> billRates;
  final List<NpoAgreement> npoAgreements;

  factory SampleHistory.generate(SampleArena arena) => _History(arena).build();
}

class _Pos {
  _Pos(this.storefront, this.role, this.call, this.id);
  final Storefront storefront;
  final String role;
  final DateTime call;
  final String id;
  Worker? worker;
  ShiftStatus status = ShiftStatus.open;
  DateTime? releasedAt;
  int? releaseOrder;
  Worker? calledOff;
}

class _History {
  _History(this.arena)
      : tz = arena.venue.timeZone,
        rng = Random(arena.seed * 131 + 9);

  final SampleArena arena;
  final String tz;
  final Random rng;
  late final DateTime today = localDateOf(arena.now, tz);
  late final Season s0 = Season.of(today);
  late final String venueId = arena.venue.id;
  late final Map<String, JobRole> roles = {for (final r in arena.jobRoles) r.code: r};
  late final List<Storefront> active = [for (final s in arena.storefronts) if (s.active) s];

  final formerWorkers = <Worker>[];
  final events = <Event>[];
  final eventStorefronts = <EventStorefront>[];
  final needs = <StaffingNeed>[];
  final shifts = <Shift>[];
  final punches = <Punch>[];
  final changes = <AssignmentChange>[];
  final createdAt = <String, DateTime>{};
  final eventBudgets = <String, int>{};
  final storefrontBudgets = <String, Map<String, int>>{};
  final tipPools = <TipPool>[];
  final payouts = <NpoPayout>[];

  /// Seasons each former worker worked (start years).
  final _formerSeasons = <String, Set<int>>{};

  /// Whether a current worker was on staff in an earlier season (start year).
  final _member = <(String, int), bool>{};
  final _shiftCount = <String, int>{};
  var _changeSeq = 0;
  var _opp = 0;

  String id(String key) => _uuidFrom('${arena.seed}:history:$key');

  int between(int lo, int hi) => lo + rng.nextInt(hi - lo + 1);
  bool chance(double p) => rng.nextDouble() < p;
  T pick<T>(List<T> xs) => xs[rng.nextInt(xs.length)];
  Duration mins(int m, [int s = 0]) => Duration(minutes: m, seconds: s);

  SampleHistory build() {
    final s1 = s0.previous, s2 = s1.previous;
    _buildFormer(s1, s2);

    final plans = <(DateTime, String, String)>[
      ..._planSeason(s2, step: (6, 11)),
      ..._planSeason(s1, step: (5, 9), tournament: DateTime.utc(s1.startYear + 1, 1, 8)),
      ..._preseason(),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    for (final (date, type, name) in plans) {
      _event(date, type, name);
    }
    _arenaChanges();
    for (final e in arena.events) {
      if (e.status == EventStatus.cancelled) continue;
      _budgets(e.id, [for (final s in arena.shifts) if (s.eventId == e.id && s.status != ShiftStatus.cancelled) s]);
    }
    final pay = SamplePay.generate(arena);
    final payStart = pay.rates.map((r) => r.effectiveFrom).reduce((a, b) => a.isBefore(b) ? a : b);
    final histFrom = s2.firstDay;
    final histTo = payStart.subtract(const Duration(days: 1));
    final covered = histFrom.isBefore(payStart);
    _payouts([..._historyAgreements(covered, histFrom, histTo), ...pay.npoAgreements]);
    return SampleHistory._(
      formerWorkers: List.unmodifiable(formerWorkers),
      events: List.unmodifiable(events),
      eventStorefronts: List.unmodifiable(eventStorefronts),
      needs: List.unmodifiable(needs),
      shifts: List.unmodifiable(shifts),
      punches: List.unmodifiable(punches..sort((a, b) => a.occurredAt.compareTo(b.occurredAt))),
      changes: List.unmodifiable(changes),
      shiftCreatedAt: Map.unmodifiable(createdAt),
      eventBudgetsCents: Map.unmodifiable(eventBudgets),
      storefrontBudgetsCents: Map.unmodifiable(storefrontBudgets),
      tipPools: List.unmodifiable(tipPools),
      npoPayouts: List.unmodifiable(payouts),
      rates: !covered
          ? const []
          : [
              for (final e in SamplePay.roleRates.entries)
                PayRate(
                  id: id('rate:${e.key}'),
                  venueId: venueId,
                  jobRoleCode: e.key,
                  hourlyRateCents: e.value - 50,
                  effectiveFrom: histFrom,
                  effectiveTo: histTo,
                ),
            ],
      billRates: !covered
          ? const []
          : [
              for (final a in arena.agencies)
                for (final e in SamplePay.billRateByRole.entries)
                  AgencyBillRate(
                    id: id('bill:${a.id}:${e.key}'),
                    venueId: venueId,
                    agencyId: a.id,
                    jobRoleCode: e.key,
                    billRateCents: e.value - 75,
                    overtimeBillRateCents: ((e.value - 75) * 3) ~/ 2,
                    effectiveFrom: histFrom,
                    effectiveTo: histTo,
                  ),
            ],
      npoAgreements: _historyAgreements(covered, histFrom, histTo),
    );
  }

  List<NpoAgreement> _historyAgreements(bool covered, DateTime from, DateTime to) => !covered
      ? const []
      : [
          NpoAgreement(
            id: id('npo:default'),
            venueId: venueId,
            hourlyRateCents: 1050,
            minHeadcount: 7,
            shortfallDeductionCents: 5000,
            noShowDeductionCents: 2500,
            effectiveFrom: from,
            effectiveTo: to,
          ),
        ];

  // -------------------------------------------------------------------------------------
  // People

  static const _former = [
    ('Brianna', 'Coleman', ['cashier', 'runner']),
    ('Tyler', 'Ramsey', ['cook', 'cashier']),
    ('Lucía', 'Ibarra', ['cashier']),
    ('Wesley', 'Pruitt', ['bartender', 'cashier']),
    ('Kendra', 'Lowe', ['runner', 'cashier']),
    ('Omar', 'Saldívar', ['cook']),
    ('Gracie', 'Whitaker', ['cashier', 'runner']),
    ('Darnell', 'Hayes', ['lead', 'cook']),
    ('Paige', 'Lindqvist', ['bartender']),
    ('Hugo', 'Benavides', ['cook', 'runner']),
    ('Sierra', 'McAllister', ['cashier']),
    ('Trent', 'Okafor', ['runner']),
    ('Marisa', 'Quintero', ['cashier', 'cook']),
    ('Connor', 'Fitzgerald', ['bartender', 'runner']),
    ('Alyssa', 'Brandt', ['runner', 'cashier']),
    ('Jesús', 'Arredondo', ['cook', 'cashier']),
  ];

  void _buildFormer(Season s1, Season s2) {
    for (var i = 0; i < _former.length + 3; i++) {
      final temp = i >= _former.length;
      final (first, last, jobRoles) = temp
          ? [('Rocío', 'Lerma', ['cashier', 'runner']), ('Brent', 'Yates', ['cook']), ('Tasha', 'Greer', ['runner', 'cashier'])][i - _former.length]
          : _former[i];
      // 0-5: worked both earlier seasons; 6-10: the season before last only;
      // 11-15 and the temps: new last season, did not come back.
      final Set<int> seasons;
      final DateTime hire;
      if (temp || i >= 11) {
        seasons = {s1.startYear};
        hire = DateTime.utc(s1.startYear, 9, 1).add(Duration(days: between(0, 120)));
      } else if (i >= 6) {
        seasons = {s2.startYear};
        hire = i.isEven ? DateTime.utc(s2.startYear - 1, 3, 1).add(Duration(days: between(0, 200))) : DateTime.utc(s2.startYear, 8, 20).add(Duration(days: between(0, 60)));
      } else {
        seasons = {s2.startYear, s1.startYear};
        hire = DateTime.utc(s2.startYear - between(0, 2), 6, 1).add(Duration(days: between(0, 80)));
      }
      final age = 19 + between(2, 24);
      final w = Worker(
        id: id('former:$i'),
        venueId: venueId,
        type: temp ? WorkerType.temp : WorkerType.regular,
        employeeNumber: temp ? 'T${9001 + i - _former.length}' : 'E${9001 + i}',
        firstName: first,
        lastName: last,
        dateOfBirth: DateTime.utc(today.year - age, 1 + between(0, 11), 1 + between(0, 27)),
        hireDate: hire,
        status: 'inactive',
        agencyId: temp ? arena.agencies[i % arena.agencies.length].id : null,
        jobRoles: List.unmodifiable(jobRoles),
      );
      formerWorkers.add(w);
      _formerSeasons[w.id] = seasons;
    }
  }

  /// Who could work on [day] (before the arena's own events).
  bool _onStaff(Worker w, DateTime day) {
    final hire = w.hireDate;
    if (hire != null && day.isBefore(hire)) return false;
    final season = Season.of(day).startYear;
    final former = _formerSeasons[w.id];
    if (former != null) return former.contains(season);
    if (season >= s0.startYear) return true;
    final s = Season(season);
    // Hired during that season: on staff from the hire date. Earlier: most came back.
    if (hire != null && !hire.isBefore(s.firstDay)) return true;
    return _member.putIfAbsent((w.id, season), () => chance(season == s0.startYear - 1 ? 0.88 : 0.8));
  }

  bool _eligible(Worker w, String role, DateTime day) {
    if (!w.jobRoles.contains(role)) return false;
    final age = w.ageOn(day) ?? 30;
    if (age < 16) return false;
    final min = roles[role]?.minimumAge;
    return min == null || age >= min;
  }

  // -------------------------------------------------------------------------------------
  // Events

  static const _opponents = [
    'Panhandle Blizzard', 'Big Bend Coyotes', 'Bayou City Barracudas', 'Prairie Lake Lynx', //
    'Cimarron Wolves', 'Sabine River Bulldogs', 'Caprock Comets', 'Red River Bandits', 'Hill Country Outlaws',
  ];
  static const _concerts = [
    'The Mesquite Ramblers', 'Luna Vega', 'Copper Canyon Revival', 'Neon Prairie', 'Marisol y Los Cardenales', 'Bluebonnet Static',
  ];
  static const _family = ['Big Top Wonder Circus', 'Dino Discovery Live', 'Starlight Ice Spectacular'];

  String _hockey(String prefix) => '${prefix}Pecan Valley Stampede vs ${_opponents[_opp++ % _opponents.length]}';

  List<(DateTime, String, String)> _planSeason(Season s, {required (int, int) step, DateTime? tournament}) {
    final out = <(DateTime, String, String)>[];
    var d = DateTime.utc(s.startYear, 9, 12);
    final end = DateTime.utc(s.startYear + 1, 4, 12);
    var concert = 0, family = 0;
    while (!d.isAfter(end)) {
      if (tournament == null || d.isBefore(tournament.subtract(const Duration(days: 6))) || d.isAfter(tournament.add(const Duration(days: 10)))) {
        final r = rng.nextDouble();
        if (r < 0.18) {
          out.add((d, 'concert', '${_concerts[concert++ % _concerts.length]} in Concert'));
        } else if (r < 0.27) {
          var sat = d;
          while (sat.weekday != DateTime.saturday) {
            sat = sat.add(const Duration(days: 1));
          }
          out.add((sat, 'family_show', _family[family++ % _family.length]));
        } else {
          out.add((d, 'hockey', _hockey('')));
        }
      }
      d = d.add(Duration(days: between(step.$1, step.$2)));
    }
    if (tournament != null) {
      for (var i = 0; i < 5; i++) {
        out.add((tournament.add(Duration(days: i)), 'hockey', _hockey('Winter Classic: ')));
      }
    }
    return out;
  }

  /// Preseason games this season, before the arena's first event, ending with a
  /// four-night tournament.
  List<(DateTime, String, String)> _preseason() {
    final dates = [for (final e in arena.events) localDateOf(e.startTime, tz)]..sort();
    if (dates.isEmpty) return const [];
    final cutoff = dates.first.subtract(const Duration(days: 3));
    final earliest = s0.firstDay.add(const Duration(days: 14));
    final out = <(DateTime, String, String)>[];
    for (var i = 0; i < 4; i++) {
      final d = cutoff.subtract(Duration(days: i));
      if (!d.isBefore(earliest) && d.isBefore(today)) out.add((d, 'hockey', _hockey('Preseason Cup: ')));
    }
    var d = cutoff.subtract(const Duration(days: 8));
    while (!d.isBefore(earliest)) {
      if (d.isBefore(today)) out.add((d, 'hockey', _hockey('Preseason: ')));
      d = d.subtract(const Duration(days: 5));
    }
    return out;
  }

  int _attendance(String type, DateTime date) {
    final weekend = date.weekday >= DateTime.friday;
    final (lo, hi) = switch (type) {
      'concert' => (4000, 6500),
      'family_show' => (2000, 4500),
      _ => weekend ? (4000, 5500) : (3000, 4500),
    };
    return between(lo ~/ 50, hi ~/ 50) * 50;
  }

  void _event(DateTime date, String type, String name) {
    final weekend = date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;
    final (hour, length) = switch (type) {
      'family_show' => (14, 150),
      'concert' => (19, 195),
      _ => weekend ? (18, 165) : (19, 165),
    };
    final start = localToUtc(tz, date.year, date.month, date.day, hour);
    final doors = start.subtract(const Duration(minutes: 60));
    final call = doors.subtract(const Duration(minutes: 90));
    final expected = _attendance(type, date);
    final key = formatDate(date);
    final e = Event(
      id: id('event:$key'),
      venueId: venueId,
      name: name,
      eventTypeCode: type,
      startTime: start,
      doorsTime: doors,
      callTime: call,
      endTime: start.add(Duration(minutes: length)),
      expectedAttendance: expected,
      actualAttendance: (expected * (0.9 + rng.nextDouble() * 0.2)).round(),
      status: EventStatus.completed,
      source: 'premium_command',
      externalId: 'PC-H${key.replaceAll('-', '')}',
    );
    events.add(e);
    _schedule(e, key, date);
  }

  void _schedule(Event e, String key, DateTime day) {
    final f = (e.expectedAttendance / 5500).clamp(0.8, 1.0);
    final bar = switch (e.eventTypeCode) {
      'concert' => 1.15,
      'family_show' => 0.6,
      _ => 1.0,
    };
    final end = e.endTime!;
    final scheduledEnd = end.add(const Duration(minutes: 45));
    final positions = <_Pos>[];
    for (final sf in arena.storefronts) {
      eventStorefronts.add(EventStorefront(eventId: e.id, storefrontId: sf.id, isOpen: sf.active));
      if (!sf.active) continue;
      for (final n in arena.staffingNeeds.where((n) => n.storefrontId == sf.id)) {
        final count = switch (n.jobRoleCode) {
          'lead' || 'runner' => n.count,
          'bartender' => max(1, (n.count * f * bar).round()),
          _ => max(1, (n.count * f).round()),
        };
        needs.add(StaffingNeed(eventId: e.id, storefrontId: sf.id, jobRoleCode: n.jobRoleCode, count: count));
        for (var i = 0; i < count; i++) {
          final call = n.jobRoleCode == 'lead' ? e.callTime.subtract(const Duration(minutes: 30)) : e.callTime;
          positions.add(_Pos(sf, n.jobRoleCode, call, id('shift:$key:${positions.length + 1}')));
        }
      }
    }

    final everyone = [...arena.workers, ...formerWorkers];
    final available = {
      for (final w in everyone)
        if (_onStaff(w, day) && chance(w.type == WorkerType.regular ? 0.88 : 0.84)) w.id,
    };
    final booked = <String>{};
    void assign(_Pos p, Worker w) {
      p.worker = w;
      p.status = ShiftStatus.assigned;
      booked.add(w.id);
      _shiftCount[w.id] = (_shiftCount[w.id] ?? 0) + 1;
    }

    // NPO groups staff their home stands.
    const homes = ['EBS', 'AADOG'];
    for (var g = 0; g < arena.npoGroups.length && g < homes.length; g++) {
      if (!chance(0.9)) continue;
      final stand = arena.storefronts.where((s) => s.code == homes[g]).firstOrNull;
      if (stand == null) continue;
      final members = everyone.where((w) => w.npoGroupId == arena.npoGroups[g].id && available.contains(w.id)).toList()
        ..sort((a, b) => a.employeeNumber.compareTo(b.employeeNumber));
      for (final role in const ['lead', 'cook', 'cashier', 'runner']) {
        for (final p in positions.where((p) => p.storefront.id == stand.id && p.role == role && p.worker == null)) {
          final c = members.where((w) => !booked.contains(w.id) && _eligible(w, role, day)).firstOrNull;
          if (c != null) assign(p, c);
        }
      }
    }

    final pool = everyone.where((w) => w.type != WorkerType.npo).toList();
    Worker? best(String role) {
      Worker? out;
      var score = double.infinity;
      for (final w in pool) {
        if (booked.contains(w.id) || !available.contains(w.id) || !_eligible(w, role, day)) continue;
        final s = (_shiftCount[w.id] ?? 0) * 0.15 + (w.jobRoles.first == role ? 0 : 0.75) + (w.type == WorkerType.temp ? 0.6 : 0) + rng.nextDouble() * 2;
        if (s < score) {
          score = s;
          out = w;
        }
      }
      return out;
    }

    for (final role in const ['bartender', 'lead', 'cook', 'runner', 'cashier']) {
      final todo = positions.where((p) => p.role == role && p.worker == null).toList()..shuffle(rng);
      for (final p in todo) {
        final w = best(role);
        if (w != null) assign(p, w);
      }
    }

    // A few positions stay open.
    for (final p in positions) {
      if (p.worker != null && p.role != 'lead' && chance(0.012)) {
        booked.remove(p.worker!.id);
        p.worker = null;
        p.status = ShiftStatus.open;
      }
    }

    // Call-offs: the person is removed a day or two before; usually someone fills in.
    for (final p in positions) {
      if (p.worker == null || p.role == 'lead' || !chance(0.025)) continue;
      p.calledOff = p.worker;
      final sub = best(p.role);
      if (sub != null) {
        assign(p, sub);
      } else {
        p.worker = null;
        p.status = ShiftStatus.open;
      }
    }

    _punchesFor(e, positions);
    for (final p in positions) {
      final s = Shift(
        id: p.id,
        venueId: venueId,
        eventId: e.id,
        storefrontId: p.storefront.id,
        jobRoleCode: p.role,
        workerId: p.worker?.id,
        callTime: p.call,
        scheduledEnd: scheduledEnd,
        status: p.status,
        releasedAt: p.releasedAt,
        releaseOrder: p.releaseOrder,
        releaseReason: p.status == ShiftStatus.released ? 'Slow stand' : '',
        version: p.status == ShiftStatus.released ? 2 : 1,
      );
      shifts.add(s);
      _fillHistory(s, calledOff: p.calledOff?.id);
    }
    _budgets(e.id, [for (final p in positions) shifts.firstWhere((s) => s.id == p.id)]);

    // Tips at the open bars.
    for (final sf in active.where((s) => s.kind == StorefrontKind.bar)) {
      final attendance = e.actualAttendance ?? e.expectedAttendance;
      tipPools.add(TipPool(
        id: id('tips:${e.id}:${sf.id}'),
        venueId: venueId,
        eventId: e.id,
        storefrontId: sf.id,
        amountCents: ((attendance * between(9, 14)) ~/ 100) * 100,
        source: 'import',
        method: 'hours',
        status: 'final',
      ));
    }
  }

  // -------------------------------------------------------------------------------------
  // Punches

  void _punchesFor(Event e, List<_Pos> positions) {
    final end = e.endTime!;
    final released = <_Pos>[];
    for (final p in positions) {
      final w = p.worker;
      if (w == null) continue;
      if (chance(0.02)) continue; // no-show
      final late = chance(0.08);
      final clockIn = late ? p.call.add(mins(between(6, 40), rng.nextInt(60))) : p.call.subtract(mins(between(0, 14), rng.nextInt(60)));
      var out = end.add(mins(between(15, 59), rng.nextInt(60)));
      if (p.role != 'lead' && chance(0.015)) {
        final at = e.startTime.add(mins(80 + rng.nextInt(60)));
        p.status = ShiftStatus.released;
        p.releasedAt = at;
        released.add(p);
        out = at.add(Duration(seconds: 30 + rng.nextInt(150)));
      }
      final items = <(PunchKind, DateTime, BreakKind?)>[(PunchKind.clockIn, clockIn, null)];
      final worked = out.difference(clockIn).inMinutes;
      final latestEnd = out.subtract(const Duration(minutes: 10));
      if (worked >= 240 && !chance(0.06)) {
        final lateBreak = chance(0.05);
        final start = clockIn.add(mins(lateBreak ? between(250, 280) : between(150, 225), rng.nextInt(60)));
        final length = chance(0.06) ? between(5, 8) : between(10, 13);
        final stop = start.add(mins(length, rng.nextInt(60)));
        if (stop.isBefore(latestEnd)) {
          items
            ..add((PunchKind.breakStart, start, BreakKind.rest))
            ..add((PunchKind.breakEnd, stop, BreakKind.rest));
        }
      }
      if (worked > 360 && !chance(0.08)) {
        final start = clockIn.add(mins(between(270, 330), rng.nextInt(60)));
        final length = chance(0.06) ? between(18, 25) : between(30, 35);
        final stop = start.add(mins(length, rng.nextInt(60)));
        if (stop.isBefore(latestEnd)) {
          items
            ..add((PunchKind.breakStart, start, BreakKind.meal))
            ..add((PunchKind.breakEnd, stop, BreakKind.meal));
        }
      }
      items.add((PunchKind.clockOut, out, null));
      final kiosk = chance(0.3);
      for (var i = 0; i < items.length; i++) {
        final (kind, at, breakKind) = items[i];
        punches.add(Punch(
          id: id('punch:${p.id}:${i + 1}'),
          venueId: venueId,
          workerId: w.id,
          eventId: e.id,
          shiftId: p.id,
          kind: kind,
          breakKind: breakKind,
          occurredAt: at,
          receivedAt: at.add(Duration(seconds: rng.nextInt(90))),
          source: kiosk ? PunchSource.kiosk : PunchSource.phone,
          deviceId: kiosk ? 'kiosk-concourse-1' : 'phone-${w.employeeNumber.toLowerCase()}',
          withinGeofence: true,
        ));
      }
    }
    released.sort((a, b) => a.releasedAt!.compareTo(b.releasedAt!));
    for (var i = 0; i < released.length; i++) {
      released[i].releaseOrder = i + 1;
    }
  }

  // -------------------------------------------------------------------------------------
  // Assignment history: when positions were created and filled.

  AssignmentChange _change(Shift s, String action, String workerId, DateTime at, String reason) => AssignmentChange(
        id: 'h${++_changeSeq}',
        eventId: s.eventId,
        shiftId: s.id,
        action: action,
        changedAt: at,
        workerId: workerId,
        fromStorefrontId: s.storefrontId,
        toStorefrontId: s.storefrontId,
        fromJobRoleCode: s.jobRoleCode,
        toJobRoleCode: s.jobRoleCode,
        reason: reason,
        changedByName: 'Marcus Bell',
      );

  static const _callOffReasons = ['Called off sick', 'Family emergency', 'Car trouble', 'Called off: school conflict'];

  /// Created two to four weeks ahead, filled within a few hours to a few days; a
  /// call-off is removed 6 to 40 hours before call and replaced within half a day.
  void _fillHistory(Shift s, {String? calledOff, bool clampToNow = false}) {
    final now = arena.now;
    var created = s.callTime.subtract(Duration(days: between(14, 28), hours: between(0, 9)));
    if (clampToNow && created.isAfter(now.subtract(const Duration(days: 3)))) created = now.subtract(Duration(days: 3, hours: between(0, 30)));
    createdAt[s.id] = created;
    DateTime fillAt(DateTime from) {
      final r = rng.nextDouble();
      final hours = r < 0.6 ? between(1, 24) : r < 0.9 ? between(25, 120) : between(121, 280);
      var at = from.add(Duration(hours: hours, minutes: rng.nextInt(60)));
      final limit = s.callTime.subtract(const Duration(hours: 2));
      if (at.isAfter(limit)) at = limit;
      if (clampToNow && at.isAfter(now.subtract(const Duration(hours: 1)))) at = now.subtract(const Duration(hours: 1));
      return at.isBefore(from) ? from.add(const Duration(minutes: 20)) : at;
    }

    if (calledOff != null) {
      final first = fillAt(created);
      var off = s.callTime.subtract(Duration(hours: between(6, 40), minutes: rng.nextInt(60)));
      if (off.isBefore(first)) off = first.add(const Duration(hours: 1));
      changes.add(_change(s, 'assigned', calledOff, first, ''));
      changes.add(_change(s, 'unassigned', calledOff, off, pick(_callOffReasons)));
      if (s.workerId != null) {
        var sub = off.add(Duration(minutes: between(30, 720)));
        if (sub.isAfter(s.callTime)) sub = s.callTime.subtract(const Duration(minutes: 10));
        changes.add(_change(s, 'assigned', s.workerId!, sub, 'Covering a call-off'));
      }
      return;
    }
    if (s.workerId != null) changes.add(_change(s, 'assigned', s.workerId!, fillAt(created), ''));
  }

  /// Fill history for the arena's own events, and a few call-offs at its past events.
  void _arenaChanges() {
    final now = arena.now;
    final byEvent = <String, List<Shift>>{};
    for (final s in arena.shifts) {
      byEvent.putIfAbsent(s.eventId, () => []).add(s);
    }
    for (final e in arena.events) {
      final list = byEvent[e.id] ?? const <Shift>[];
      final working = {for (final s in list) ?s.workerId};
      final past = e.status == EventStatus.completed;
      for (final s in list) {
        if (s.status == ShiftStatus.cancelled) continue;
        String? off;
        if (past && s.workerId != null && s.jobRoleCode != 'lead' && chance(0.025)) {
          final day = localDateOf(e.callTime, tz);
          final cands = arena.workers
              .where((w) => w.type != WorkerType.npo && !working.contains(w.id) && _eligible(w, s.jobRoleCode, day))
              .toList();
          if (cands.isNotEmpty) {
            off = pick(cands).id;
            working.add(off);
          }
        }
        _fillHistory(s, calledOff: off, clampToNow: !past || e.callTime.isAfter(now.subtract(const Duration(days: 3))));
      }
    }
  }

  // -------------------------------------------------------------------------------------
  // Budgets and payouts

  void _budgets(String eventId, List<Shift> eventShifts) {
    final count = <String, int>{};
    for (final s in eventShifts) {
      if (s.status == ShiftStatus.cancelled) continue;
      count[s.storefrontId] = (count[s.storefrontId] ?? 0) + 1;
    }
    if (count.isEmpty) return;
    // About $90 a position for the night, with some events planned tight.
    final total = count.values.fold(0, (a, b) => a + b);
    eventBudgets[eventId] = ((total * 9000 * (0.9 + rng.nextDouble() * 0.24)) ~/ 5000) * 5000;
    storefrontBudgets[eventId] = {
      for (final e in count.entries) e.key: ((e.value * 9000 * (0.88 + rng.nextDouble() * 0.28)) ~/ 1000) * 1000,
    };
  }

  void _payouts(List<NpoAgreement> agreements) {
    final members = [...arena.workers.where((w) => w.type == WorkerType.npo)];
    final breaks = VenueRules.fromJson(arena.venue.settings).breaks;
    final byEvent = <String, List<Shift>>{};
    for (final s in shifts) {
      byEvent.putIfAbsent(s.eventId, () => []).add(s);
    }
    final punchesByWorker = <String, List<Punch>>{};
    for (final p in punches) {
      punchesByWorker.putIfAbsent(p.workerId, () => []).add(p);
    }
    for (final e in events) {
      final list = byEvent[e.id] ?? const <Shift>[];
      for (final g in arena.npoGroups) {
        if (!list.any((s) => s.workerId != null && members.any((m) => m.id == s.workerId && m.npoGroupId == g.id))) continue;
        final r = calculateNpoPayout(
          event: e,
          npoGroupId: g.id,
          members: members,
          shifts: list,
          punchesByWorker: punchesByWorker,
          agreements: agreements,
          timeZone: tz,
          breakRules: breaks,
        );
        final paid = e.startTime.add(const Duration(days: 21));
        payouts.add(NpoPayout.fromJson({
          ...r.payout.toJson(),
          'id': id('payout:${e.id}:${g.id}'),
          'venue_id': venueId,
          'status': 'paid',
          'approved_at': e.startTime.add(const Duration(days: 7)).toIso8601String(),
          'paid_at': paid.toIso8601String(),
          'payment_reference': 'AP ${formatDate(localDateOf(paid, tz)).replaceAll('-', '')}',
        }));
      }
    }
  }
}

/// A UUID-shaped id from a string (FNV-1a based, deterministic).
String _uuidFrom(String key) {
  var h1 = 0x811c9dc5, h2 = 0x01000193 ^ key.length, h3 = 0x9e3779b9, h4 = 0x85ebca6b;
  for (final c in key.codeUnits) {
    h1 = ((h1 ^ c) * 0x01000193) & 0xffffffff;
    h2 = ((h2 ^ (c + 31)) * 0x01000193) & 0xffffffff;
    h3 = ((h3 ^ (c * 7)) * 0x01000193) & 0xffffffff;
    h4 = ((h4 ^ (c * 13 + 5)) * 0x01000193) & 0xffffffff;
  }
  String hex(int v) => v.toRadixString(16).padLeft(8, '0');
  final s = '${hex(h1)}${hex(h2)}${hex(h3)}${hex(h4)}';
  final variant = '89ab'[int.parse(s[16], radix: 16) & 3];
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-4${s.substring(13, 16)}-$variant${s.substring(17, 20)}-${s.substring(20, 32)}';
}
