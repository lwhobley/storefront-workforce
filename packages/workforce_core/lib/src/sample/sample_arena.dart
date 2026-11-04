/// Deterministic sample data for a fictional arena, Pecan Valley Arena.
///
/// Used by the app's demo mode (no backend) and by `bin/generate_seed.dart`, which writes the
/// Supabase seed. The same `now` and `seed` always produce identical data: all randomness comes
/// from seeded [Random] instances and every id is a hash of the seed and a stable key.
///
/// Everything in here is invented: the organization, venue, teams, artists, nonprofits,
/// agencies and people. Phone numbers use 555 and email addresses use example.com.
library;

import 'dart:math';

import '../layout/cutx_layout.dart';
import '../model/entities.dart';
import '../model/enums.dart';
import '../rules/venue_rules.dart';

/// A complete, internally consistent data set for one venue.
class SampleArena {
  SampleArena._({
    required this.now,
    required this.seed,
    required this.organization,
    required this.venue,
    required this.levels,
    required this.storefronts,
    required this.stations,
    required this.jobRoles,
    required this.certificationTypes,
    required this.staffingNeeds,
    required this.agencies,
    required this.npoGroups,
    required this.workers,
    required this.events,
    required this.eventStorefronts,
    required this.eventStaffingNeeds,
    required this.shifts,
    required this.punches,
  });

  /// Builds the data set. Events, statuses, ages, hire dates and certification expirations are
  /// placed relative to [now]; the venue layout and its ids do not depend on it.
  static SampleArena generate({required DateTime now, int seed = 42}) => _Generator(now.toUtc(), seed).build();

  /// The instant the data was generated for (UTC).
  final DateTime now;
  final int seed;

  /// `{'id': ..., 'name': ...}`.
  final Map<String, String> organization;
  final Venue venue;
  final List<VenueLevel> levels;
  final List<Storefront> storefronts;
  final List<Station> stations;
  final List<JobRole> jobRoles;
  final List<CertificationType> certificationTypes;

  /// Default staffing per storefront ([StaffingNeed.eventId] is null).
  final List<StaffingNeed> staffingNeeds;
  final List<TempAgency> agencies;
  final List<NpoGroup> npoGroups;

  /// With [Worker.jobRoles] and [Worker.certifications] filled in.
  final List<Worker> workers;

  /// Sorted by start time.
  final List<Event> events;

  /// One row per storefront per event, open or not.
  final List<EventStorefront> eventStorefronts;

  /// Staffing for each open storefront at each event.
  final List<StaffingNeed> eventStaffingNeeds;
  final List<Shift> shifts;

  /// Sorted by occurred time.
  final List<Punch> punches;

  /// The event in progress at [now].
  Event? get liveEvent {
    for (final e in events) {
      if (e.status == EventStatus.live) return e;
    }
    return null;
  }

  /// Database rows per table, in insert order (each table only refers to tables before it).
  Map<String, List<Map<String, dynamic>>> toTables() {
    final v = venue.id;
    return {
      'organizations': [Map<String, dynamic>.of(organization)],
      'venues': [venue.toJson()],
      'venue_levels': [for (final l in levels) l.toJson()],
      'storefronts': [for (final s in storefronts) s.toJson()],
      'certification_types': [for (final c in certificationTypes) c.toJson()],
      'job_roles': [for (final r in jobRoles) r.toJson()],
      'stations': [for (final s in stations) s.toJson()],
      'storefront_staffing_needs': [
        for (final n in staffingNeeds) {...n.toJson(), 'venue_id': v},
      ],
      'temp_agencies': [for (final a in agencies) a.toJson()],
      'npo_groups': [for (final g in npoGroups) g.toJson()],
      'workers': [for (final w in workers) w.toRow()],
      'worker_job_roles': [
        for (final w in workers)
          for (final r in w.jobRoles) {'venue_id': v, 'worker_id': w.id, 'job_role_code': r},
      ],
      'worker_certifications': [
        for (final w in workers)
          for (final c in w.certifications) {...c.toJson(), 'venue_id': v},
      ],
      'events': [for (final e in events) e.toJson()],
      'event_storefronts': [
        for (final es in eventStorefronts) {...es.toJson(), 'venue_id': v},
      ],
      'event_staffing_needs': [
        for (final n in eventStaffingNeeds) {...n.toJson(), 'venue_id': v},
      ],
      'shifts': [for (final s in shifts) s.toJson()],
      'punches': [for (final p in punches) p.toJson()],
    };
  }

  Map<String, dynamic> toJson() => {'now': now.toIso8601String(), 'seed': seed, 'tables': toTables()};
}

// ---------------------------------------------------------------------------------------------
// Ids

/// A version-4-shaped UUID derived from [seed] and [key]. Uses only 32-bit arithmetic that
/// stays exact on the web, so ids match across platforms.
String _uuid(int seed, String key) {
  final buf = StringBuffer();
  for (var i = 0; i < 4; i++) {
    buf.write(_hash32('$i|$seed|$key|$i').toRadixString(16).padLeft(8, '0'));
  }
  final h = buf.toString();
  final variant = '89ab'[int.parse(h[16], radix: 16) & 3];
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-'
      '$variant${h.substring(17, 20)}-${h.substring(20, 32)}';
}

int _mul32(int a, int b) {
  final lo = (a & 0xffff) * b;
  final hi = ((a >>> 16) * b) % 0x10000;
  return (lo + hi * 0x10000) % 0x100000000;
}

int _hash32(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = _mul32((h ^ c) & 0xffffffff, 0x01000193);
  }
  h = (h ^ (h >>> 16)) & 0xffffffff;
  h = _mul32(h, 0x85ebca6b);
  h = (h ^ (h >>> 13)) & 0xffffffff;
  h = _mul32(h, 0xc2b2ae35);
  return (h ^ (h >>> 16)) & 0xffffffff;
}

// ---------------------------------------------------------------------------------------------
// America/Chicago without a time zone database (US rules since 2007). The sample venue is fixed
// in Texas, so this keeps generation free of global time zone initialization.

int _nthSunday(int year, int month, int n) {
  final first = DateTime.utc(year, month, 1);
  return 1 + (DateTime.sunday - first.weekday) % 7 + 7 * (n - 1);
}

int _centralOffsetHours(DateTime utc) {
  final y = utc.year;
  final dstStart = DateTime.utc(y, 3, _nthSunday(y, 3, 2), 8); // 02:00 CST
  final dstEnd = DateTime.utc(y, 11, _nthSunday(y, 11, 1), 7); // 02:00 CDT
  return (!utc.isBefore(dstStart) && utc.isBefore(dstEnd)) ? -5 : -6;
}

DateTime _toLocal(DateTime utc) => utc.add(Duration(hours: _centralOffsetHours(utc)));

/// Calendar date (as a UTC midnight) of [utc] in venue time.
DateTime _localDate(DateTime utc) {
  final l = _toLocal(utc);
  return DateTime.utc(l.year, l.month, l.day);
}

/// The instant of a wall-clock time on [date] in venue time.
DateTime _central(DateTime date, int hour, int minute) {
  final wall = DateTime.utc(date.year, date.month, date.day, hour, minute);
  final cdt = wall.add(const Duration(hours: 5));
  return _centralOffsetHours(cdt) == -5 ? cdt : wall.add(const Duration(hours: 6));
}

int _hhmm(String s) => int.parse(s.substring(0, 2)) * 60 + int.parse(s.substring(3, 5));

// ---------------------------------------------------------------------------------------------
// Random helpers

int _between(Random r, int lo, int hi) => lo + r.nextInt(hi - lo + 1);
T _pick<T>(Random r, List<T> xs) => xs[r.nextInt(xs.length)];
bool _chance(Random r, double p) => r.nextDouble() < p;

T _weighted<T>(Random r, List<(T, int)> options) {
  final total = options.fold<int>(0, (s, o) => s + o.$2);
  var x = r.nextInt(total);
  for (final o in options) {
    if (x < o.$2) return o.$1;
    x -= o.$2;
  }
  return options.last.$1;
}

Duration _mins(int m, [int s = 0]) => Duration(minutes: m, seconds: s);

DateTime _addMonths(DateTime d, int months) => DateTime.utc(d.year, d.month + months, d.day);

DateTime _maxDate(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

// ---------------------------------------------------------------------------------------------
// Venue layout

class _StorefrontDef {
  const _StorefrontDef(
    this.code,
    this.name,
    this.kind,
    this.description, {
    this.section = '',
    this.side,
    this.nudge = 0,
    this.active = true,
    this.smallCrowd = true,
    required this.stations,
    required this.staffing,
  });

  /// Also the key for stable ids.
  final String code;
  final String name;
  final StorefrontKind kind;
  final String description;

  /// Seating section it sits behind; empty for one placed by concourse side.
  final String section;

  /// north, south, east or west, for storefronts not tied to a section.
  final String? side;
  final double nudge;
  final bool active;

  /// Opens for crowds under [_smallCrowd].
  final bool smallCrowd;
  final List<(String, String?)> stations;

  /// Sellout-night staffing by job role.
  final Map<String, int> staffing;
}

const _stand = StorefrontKind.permanentStand;
const _bar = StorefrontKind.bar;
const _kiosk = StorefrontKind.kiosk;

/// Below this expected attendance the Westside Bar and Grab & Go stay closed and staffing
/// is cut by about a quarter.
const _smallCrowd = 3500;

const _barDescription = 'Craft and Domestic Beers and Mixed Drinks';
const _barStations = [
  ('Well 1', 'bartender'),
  ('Well 2', 'bartender'),
  ('Well 3', 'bartender'),
  ('Service Bar', 'bartender'),
];
const _barStaffing = {'lead': 1, 'bartender': 3, 'runner': 1};

/// The venue's concession lineup.
const _storefrontDefs = [
  _StorefrontDef(
    'CANTINA',
    'La Cantina Roja',
    _stand,
    'Gourmet Nachos, Quesadillas, Churros, Coffee and Hot Chocolate',
    section: '106',
    stations: [
      ('Register 1', 'cashier'),
      ('Register 2', 'cashier'),
      ('Register 3', 'cashier'),
      ('Kitchen', 'cook'),
      ('Expo', 'runner'),
    ],
    staffing: {'lead': 1, 'cashier': 3, 'cook': 3, 'runner': 1},
  ),
  _StorefrontDef(
    'GRILL',
    'Allen Station Grill',
    _stand,
    'Hot Dogs, Burgers, Chicken Strips, Chicken Sandwiches, Nachos, Kids Meals, Coffee and Hot Chocolate',
    section: '103',
    stations: [
      ('Register 1', 'cashier'),
      ('Register 2', 'cashier'),
      ('Register 3', 'cashier'),
      ('Register 4', 'cashier'),
      ('Grill', 'cook'),
      ('Fryer', 'cook'),
      ('Expo', 'runner'),
    ],
    staffing: {'lead': 1, 'cashier': 4, 'cook': 4, 'runner': 1},
  ),
  _StorefrontDef(
    'SLICE',
    'Slice',
    _stand,
    'Pizza by the slice',
    section: '101',
    stations: [('Register 1', 'cashier'), ('Register 2', 'cashier'), ('Ovens', 'cook')],
    staffing: {'lead': 1, 'cashier': 2, 'cook': 2},
  ),
  _StorefrontDef(
    'EBS',
    'Eb’s BBQ',
    _stand,
    'Beef Sandwiches, Pulled Pork Sandwiches, Jumbo Hot Dogs, Loaded BBQ Nachos and Kids Meals',
    section: '117',
    stations: [
      ('Register 1', 'cashier'),
      ('Register 2', 'cashier'),
      ('Register 3', 'cashier'),
      ('Smoker/Carving', 'cook'),
      ('Expo', 'runner'),
    ],
    staffing: {'lead': 1, 'cashier': 3, 'cook': 3, 'runner': 1},
  ),
  _StorefrontDef(
    'AADOG',
    'All American Dog',
    _stand,
    'Hot Dogs, French Fries, Footlong Corndogs, Kids Meals, Coffee and Hot Chocolate',
    section: '114',
    stations: [
      ('Register 1', 'cashier'),
      ('Register 2', 'cashier'),
      ('Register 3', 'cashier'),
      ('Grill', 'cook'),
      ('Fryer', 'cook'),
    ],
    staffing: {'lead': 1, 'cashier': 3, 'cook': 2, 'runner': 1},
  ),
  _StorefrontDef(
    'SOUTHSIDE',
    'Southside Bar presented by Lazy Dog',
    _bar,
    _barDescription,
    section: '115',
    stations: _barStations,
    staffing: _barStaffing,
  ),
  _StorefrontDef(
    'DESTINATION',
    'Destination Bar',
    _bar,
    _barDescription,
    section: '105',
    stations: _barStations,
    staffing: _barStaffing,
  ),
  _StorefrontDef(
    'WESTSIDE',
    'Westside Bar presented by Ole Smoky',
    _bar,
    _barDescription,
    side: 'west',
    smallCrowd: false,
    stations: _barStations,
    staffing: _barStaffing,
  ),
  _StorefrontDef(
    'GRABGO',
    'Grab & Go',
    _kiosk,
    'Grab-and-go snacks and drinks',
    side: 'south',
    nudge: 0.12,
    smallCrowd: false,
    stations: [('Counter', 'cashier')],
    staffing: {'cashier': 2},
  ),
  _StorefrontDef(
    'SWEET',
    'Sweet Station',
    _kiosk,
    'Coming soon',
    side: 'north',
    nudge: -0.12,
    active: false,
    stations: [('Counter', 'cashier')],
    staffing: {},
  ),
];

/// Home stands of the nonprofit groups, in group order (storefront keys).
const _npoHomeStands = ['EBS', 'AADOG'];

const _roleOrder = ['lead', 'cashier', 'cook', 'runner', 'bartender'];

// ---------------------------------------------------------------------------------------------
// Generator

class _CertPlan {
  _CertPlan(this.issued, this.expires, this.number);
  DateTime issued;
  DateTime expires;
  final String number;
}

class _Spec {
  _Spec(this.type, this.roles, this.age, this.order);

  final WorkerType type;
  final List<String> roles;
  final int age;

  /// Creation order, used to break ties so sorting stays deterministic.
  final int order;
  String first = '';
  String last = '';
  String preferred = '';
  late DateTime dob;
  late DateTime hire;
  String phone = '';
  String email = '';
  String uniform = '';
  String emergencyName = '';
  String emergencyPhone = '';
  String language = 'en';
  String? agencyId;
  String? npoGroupId;
  int npoGroup = -1;
  String paycom = '';
  String employeeNumber = '';
  final certs = <String, _CertPlan>{};
}

class _EventPlan {
  _EventPlan(this.date, this.type);
  DateTime date;
  final String type;
}

class _Ctx {
  _Ctx(this.event, this.key, this.day);
  final Event event;
  final String key;
  final DateTime day;
  bool get isLive => event.status == EventStatus.live;
  bool get isPast => event.status == EventStatus.completed;
}

class _Pos {
  _Pos(this.storefront, this.role, this.stationId, this.call);
  final Storefront storefront;
  final String role;
  final String? stationId;
  DateTime call;
  String id = '';
  Worker? worker;
  ShiftStatus status = ShiftStatus.open;
  DateTime? releasedAt;
  int? releaseOrder;
  bool deliberateMinor = false;
}

class _Generator {
  _Generator(this.now, this.seed) : rng = Random(seed), srng = Random(seed * 7919 + 17);

  final DateTime now;
  final int seed;

  /// Venue and roster randomness (does not depend on [now]'s value).
  final Random rng;

  /// Schedule, assignment and punch randomness.
  final Random srng;

  static const rules = VenueRules.texasDefaults;
  static const venueLat = 31.104120;
  static const venueLng = -97.352860;

  late final DateTime today = _localDate(now);
  late final String venueId = id('venue');

  final levels = <VenueLevel>[];
  final storefronts = <Storefront>[];
  final stations = <Station>[];
  final staffingNeeds = <StaffingNeed>[];
  final agencies = <TempAgency>[];
  final npoGroups = <NpoGroup>[];
  final workers = <Worker>[];
  final events = <Event>[];
  final eventStorefronts = <EventStorefront>[];
  final eventNeeds = <StaffingNeed>[];
  final shifts = <Shift>[];
  final punches = <Punch>[];

  final _defs = <String, _StorefrontDef>{};

  /// The storefront's key (its code), used for stable ids.
  final _keyOf = <String, String>{};
  final _stationsBy = <String, List<Station>>{};
  final _needsBy = <String, List<StaffingNeed>>{};
  final _roles = <String, JobRole>{};
  final _shiftCount = <String, int>{};
  final _npoMembers = <int, List<Worker>>{};

  String id(String key) => _uuid(seed, key);

  SampleArena build() {
    final orgId = id('organization');
    final venue = Venue(
      id: venueId,
      organizationId: orgId,
      name: 'CUTX Event Center (sample)',
      timeZone: 'America/Chicago',
      // The map is drawn from the CUTX plan; every storefront is on its concourse.
      settings: {
        ...rules.toJson(),
        'map': {'layout': 'cutx'},
      },
      branding: const {'app_name': 'Storefront Workforce', 'primary_color': '#0088B0'},
    );
    _buildLayout();
    final certTypes = [
      CertificationType(venueId: venueId, code: 'food_handler', name: 'Food Handler Card', validityMonths: 24),
      CertificationType(venueId: venueId, code: 'tabc', name: 'TABC Seller-Server', validityMonths: 24),
    ];
    final jobRoles = [
      JobRole(venueId: venueId, code: 'cashier', name: 'Cashier', sort: 1),
      JobRole(
        venueId: venueId,
        code: 'cook',
        name: 'Cook',
        requiredCertifications: const ['food_handler'],
        minimumAge: 16,
        sort: 2,
      ),
      JobRole(venueId: venueId, code: 'runner', name: 'Runner', sort: 3),
      JobRole(
        venueId: venueId,
        code: 'bartender',
        name: 'Bartender',
        requiredCertifications: const ['tabc'],
        minimumAge: 18,
        tipped: true,
        sort: 4,
      ),
      JobRole(
        venueId: venueId,
        code: 'lead',
        name: 'Stand Lead',
        requiredCertifications: const ['food_handler'],
        minimumAge: 18,
        sort: 5,
      ),
    ];
    for (final r in jobRoles) {
      _roles[r.code] = r;
    }
    _buildRoster();
    _buildEvents();
    for (final e in events) {
      _scheduleEvent(e);
    }
    punches.sort((a, b) {
      final c = a.occurredAt.compareTo(b.occurredAt);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    return SampleArena._(
      now: now,
      seed: seed,
      organization: {'id': orgId, 'name': 'CUTX Event Center'},
      venue: venue,
      levels: List.unmodifiable(levels),
      storefronts: List.unmodifiable(storefronts),
      stations: List.unmodifiable(stations),
      jobRoles: List.unmodifiable(jobRoles),
      certificationTypes: List.unmodifiable(certTypes),
      staffingNeeds: List.unmodifiable(staffingNeeds),
      agencies: List.unmodifiable(agencies),
      npoGroups: List.unmodifiable(npoGroups),
      workers: List.unmodifiable(workers),
      events: List.unmodifiable(events),
      eventStorefronts: List.unmodifiable(eventStorefronts),
      eventStaffingNeeds: List.unmodifiable(eventNeeds),
      shifts: List.unmodifiable(shifts),
      punches: List.unmodifiable(punches),
    );
  }

  // -------------------------------------------------------------------------------------------
  // Levels, storefronts, stations, default staffing

  void _buildLayout() {
    // One level: the CUTX concourse, which wraps the lower bowl.
    levels.add(VenueLevel(id: id('level:1'), venueId: venueId, name: 'Concourse', sort: 1));
    for (final d in _storefrontDefs) {
      final spot = d.side != null
          ? cutxLayout.concourseSide(d.side!, nudge: d.nudge)
          : cutxLayout.concourseSpotNearSection(d.section, nudge: d.nudge);
      final sf = Storefront(
        id: id('storefront:${d.code}'),
        venueId: venueId,
        levelId: levels.first.id,
        code: d.code,
        name: d.name,
        kind: d.kind,
        section: d.section,
        mapX: (spot.$1 * 10000).round() / 10000,
        mapY: (spot.$2 * 10000).round() / 10000,
        active: d.active,
        description: d.description,
      );
      storefronts.add(sf);
      _defs[sf.id] = d;
      _keyOf[sf.id] = d.code;

      final list = [
        for (final (name, role) in d.stations)
          Station(
            id: id('station:${d.code}:$name'),
            venueId: venueId,
            storefrontId: sf.id,
            name: name,
            jobRoleCode: role,
          ),
      ];
      stations.addAll(list);
      _stationsBy[sf.id] = list;

      final needs = [
        for (final role in _roleOrder)
          if ((d.staffing[role] ?? 0) > 0)
            StaffingNeed(storefrontId: sf.id, jobRoleCode: role, count: d.staffing[role]!),
      ];
      staffingNeeds.addAll(needs);
      _needsBy[sf.id] = needs;
    }
  }

  // -------------------------------------------------------------------------------------------
  // Roster

  void _buildRoster() {
    agencies.addAll([
      TempAgency(id: id('agency:1'), venueId: venueId, name: 'Brazos Staffing Partners', contactName: 'Dana Whitfield'),
      TempAgency(id: id('agency:2'), venueId: venueId, name: 'Gulf Coast Event Labor', contactName: 'Rogelio Saenz'),
    ]);

    var order = 0;
    _Spec spec(WorkerType t, List<String> roles, int age) => _Spec(t, roles, age, order++);

    // Regular seasonal staff: 70.
    final regular = <_Spec>[];
    void addN(int n, List<String> roles, int minAge, int maxAge) {
      for (var i = 0; i < n; i++) {
        regular.add(spec(WorkerType.regular, roles, _adultAge(minAge, maxAge)));
      }
    }

    addN(3, ['lead', 'cashier'], 22, 60);
    addN(4, ['lead', 'cook'], 22, 60);
    addN(2, ['lead', 'bartender'], 23, 55);
    addN(1, ['lead'], 25, 62);
    addN(5, ['bartender'], 21, 55);
    addN(4, ['bartender', 'cashier'], 21, 50);
    addN(3, ['bartender', 'runner'], 21, 45);
    addN(5, ['cook'], 18, 62);
    addN(7, ['cook', 'cashier'], 18, 60);
    addN(2, ['cook', 'runner'], 18, 45);
    addN(2, ['cook', 'cashier', 'runner'], 18, 50);
    addN(5, ['cashier'], 18, 65);
    addN(8, ['cashier', 'runner'], 18, 60);
    addN(3, ['cashier', 'cook'], 18, 55);
    addN(6, ['runner', 'cashier'], 18, 30);
    addN(2, ['runner'], 18, 28);
    for (var i = 0; i < 6; i++) {
      final roles = i < 3
          ? ['cashier', 'runner']
          : i < 5
          ? ['cook', 'cashier']
          : ['runner'];
      regular.add(spec(WorkerType.regular, roles, 16 + rng.nextInt(2)));
    }
    for (var i = 0; i < 2; i++) {
      regular.add(spec(WorkerType.regular, i == 0 ? ['cashier', 'runner'] : ['runner'], 14 + rng.nextInt(2)));
    }

    // Temps: 14 across two agencies.
    final temps = <_Spec>[];
    void addT(int n, List<String> roles, int minAge, int maxAge) {
      for (var i = 0; i < n; i++) {
        temps.add(spec(WorkerType.temp, roles, _adultAge(minAge, maxAge)));
      }
    }

    addT(3, ['bartender', 'cashier'], 21, 50);
    addT(3, ['cook'], 19, 55);
    addT(2, ['cook', 'cashier'], 19, 55);
    addT(4, ['cashier', 'runner'], 18, 60);
    addT(2, ['runner', 'cashier'], 18, 40);

    // Nonprofit members: 2 groups of 9.
    final npo = <_Spec>[];
    for (var g = 0; g < _npoDefs.length; g++) {
      final members = <_Spec>[
        spec(WorkerType.npo, ['lead', 'cashier'], _adultAge(32, 62)),
        spec(WorkerType.npo, ['lead', 'cook'], _adultAge(25, 60)),
        spec(WorkerType.npo, ['cook', 'cashier'], _adultAge(18, 60)),
        spec(WorkerType.npo, ['cook', 'cashier'], _adultAge(18, 60)),
        spec(WorkerType.npo, ['cook', 'cashier'], g.isEven ? 16 + rng.nextInt(2) : _adultAge(18, 60)),
        spec(WorkerType.npo, ['cashier', 'runner'], _adultAge(18, 65)),
        spec(WorkerType.npo, ['cashier'], _adultAge(18, 65)),
        spec(WorkerType.npo, ['cashier', 'runner'], g.isOdd ? 14 + rng.nextInt(2) : 16 + rng.nextInt(2)),
        spec(WorkerType.npo, ['runner', 'cashier'], _adultAge(18, 55)),
      ];
      for (final m in members) {
        m.npoGroup = g;
      }
      npo.addAll(members);
    }

    for (final s in [...regular, ...temps, ...npo]) {
      _fillPerson(s);
    }

    // Agencies: 8 and 6.
    final tempOrder = [...temps]..shuffle(rng);
    for (var i = 0; i < tempOrder.length; i++) {
      tempOrder[i].agencyId = agencies[i < 8 ? 0 : 1].id;
    }

    // Employee numbers follow hire date.
    int byHire(_Spec a, _Spec b) {
      final c = a.hire.compareTo(b.hire);
      return c != 0 ? c : a.order.compareTo(b.order);
    }

    regular.sort(byHire);
    temps.sort(byHire);
    for (var i = 0; i < regular.length; i++) {
      regular[i].employeeNumber = 'E${1001 + i}';
    }
    for (var i = 0; i < temps.length; i++) {
      temps[i].employeeNumber = 'T${2001 + i}';
    }
    for (var i = 0; i < npo.length; i++) {
      npo[i].employeeNumber = 'N${3001 + i}';
    }

    // Paycom codes for regular staff.
    const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    final usedCodes = <String>{};
    for (final s in regular) {
      String code;
      do {
        code =
            '${letters[rng.nextInt(letters.length)]}${rng.nextInt(10)}'
            '${letters[rng.nextInt(letters.length)]}${rng.nextInt(10)}';
      } while (!usedCodes.add(code));
      s.paycom = code;
    }

    _addCertificationProblems(regular);

    // Nonprofit groups, with the first member as coordinator.
    for (var g = 0; g < _npoDefs.length; g++) {
      final gid = id('npo:${g + 1}');
      final members = npo.where((s) => s.npoGroup == g).toList();
      for (final m in members) {
        m.npoGroupId = gid;
      }
      final (display, legal) = _npoDefs[g];
      npoGroups.add(
        NpoGroup(
          id: gid,
          venueId: venueId,
          legalName: legal,
          displayName: display,
          coordinatorName: '${members.first.first} ${members.first.last}',
          w9OnFile: true,
        ),
      );
    }

    for (final s in [...regular, ...temps, ...npo]) {
      final w = _toWorker(s);
      workers.add(w);
      if (s.npoGroup >= 0) (_npoMembers[s.npoGroup] ??= []).add(w);
    }
  }

  int _adultAge(int minAge, int maxAge) {
    // Skew toward younger staff, as concession crews are.
    final u = rng.nextDouble();
    final t = u * u * 0.6 + u * 0.4;
    return minAge + (t * (maxAge - minAge + 1)).floor().clamp(0, maxAge - minAge);
  }

  final _usedNames = <String>{};
  final _usedEmails = <String>{};

  void _fillPerson(_Spec s) {
    final heritage = _weighted(rng, const [('hispanic', 36), ('anglo', 42), ('black', 14), ('asian', 8)]);
    final female = rng.nextBool();
    do {
      switch (heritage) {
        case 'hispanic':
          s.first = _pick(rng, female ? _hispanicFemale : _hispanicMale);
          s.last = _pick(rng, _hispanicLast);
        case 'black':
          s.first = _pick(rng, female ? _blackFemale : _blackMale);
          s.last = _pick(rng, _commonLast);
        case 'asian':
          final (last, firsts) = _pick(rng, _asianNames);
          s.last = last;
          s.first = _pick(rng, firsts);
        default:
          s.first = _pick(rng, female ? _angloFemale : _angloMale);
          s.last = _pick(rng, _commonLast);
      }
    } while (!_usedNames.add('${s.first} ${s.last}'));
    final nick = _nicknames[s.first];
    if (nick != null && _chance(rng, 0.35)) s.preferred = nick;
    if (heritage == 'hispanic' && _chance(rng, 0.8)) s.language = 'es';

    s.dob = DateTime.utc(today.year - s.age, today.month, today.day).subtract(Duration(days: 1 + rng.nextInt(364)));

    final area = _pick(rng, const ['254', '254', '254', '512', '737', '979']);
    s.phone = '($area) 555-${_between(rng, 100, 9999).toString().padLeft(4, '0')}';
    final base = '${_ascii(s.preferred.isNotEmpty ? s.preferred : s.first)}.${_ascii(s.last)}';
    var email = '$base@example.com';
    var n = 2;
    while (!_usedEmails.add(email)) {
      email = '$base$n@example.com';
      n++;
    }
    s.email = email;
    s.uniform = _weighted(rng, const [('S', 15), ('M', 30), ('L', 28), ('XL', 17), ('2XL', 7), ('3XL', 3)]);
    final ecFirst = _pick(
      rng,
      rng.nextBool() ? [..._angloFemale, ..._hispanicFemale] : [..._angloMale, ..._hispanicMale],
    );
    final ecLast = _chance(rng, 0.65) ? s.last : _pick(rng, heritage == 'hispanic' ? _hispanicLast : _commonLast);
    s.emergencyName = '$ecFirst $ecLast';
    s.emergencyPhone = '($area) 555-${_between(rng, 100, 9999).toString().padLeft(4, '0')}';

    // Hire (or join) date.
    final latest = today.subtract(const Duration(days: 10));
    final earliestByAge = DateTime.utc(s.dob.year + (s.age < 18 ? 14 : 16), s.dob.month, s.dob.day);
    final year = switch (s.type) {
      WorkerType.regular => _weighted(rng, const [
        (2019, 10),
        (2020, 6),
        (2021, 12),
        (2022, 15),
        (2023, 17),
        (2024, 19),
        (2025, 22),
        (2026, 15),
      ]),
      WorkerType.temp => _weighted(rng, const [(2023, 15), (2024, 25), (2025, 35), (2026, 25)]),
      WorkerType.npo => _weighted(rng, const [(2021, 10), (2022, 15), (2023, 20), (2024, 20), (2025, 20), (2026, 15)]),
    };
    final yearStart = DateTime.utc(year, year == 2019 ? 3 : 1, 1);
    var hire = yearStart.add(Duration(days: rng.nextInt(year == 2026 ? 280 : (year == 2019 ? 300 : 365))));
    hire = _maxDate(hire, DateTime.utc(2019, 3, 1));
    hire = _maxDate(hire, earliestByAge);
    if (hire.isAfter(latest)) hire = _maxDate(latest, earliestByAge);
    s.hire = hire;

    // Certifications.
    final needsFoodHandler = s.roles.contains('cook') || s.roles.contains('lead');
    if (needsFoodHandler || _chance(rng, 0.3)) {
      s.certs['food_handler'] = _certPlan('food_handler', s.age < 18 ? 300 : 620);
    }
    if (s.roles.contains('bartender')) {
      s.certs['tabc'] = _certPlan('tabc', 620);
    }
  }

  _CertPlan _certPlan(String type, int maxAgeDays) {
    final issued = today.subtract(Duration(days: _between(rng, 40, maxAgeDays)));
    final number = type == 'tabc' ? 'TABC-${_between(rng, 1000000, 9999999)}' : 'FHC-${_between(rng, 100000, 999999)}';
    return _CertPlan(issued, _addMonths(issued, 24).subtract(const Duration(days: 1)), number);
  }

  /// A few expired, expiring and missing certifications so the app's warnings have data.
  void _addCertificationProblems(List<_Spec> regular) {
    final bartenders = regular.where((s) => s.roles.first == 'bartender').toList()..shuffle(rng);
    final cooks = regular.where((s) => s.roles.first == 'cook' && s.age >= 18).toList()..shuffle(rng);
    void expire(_Spec s, String type) {
      final c = s.certs[type]!;
      c.expires = today.subtract(Duration(days: _between(rng, 8, 70)));
      c.issued = _addMonths(c.expires.add(const Duration(days: 1)), -24);
    }

    void expiring(_Spec s, String type) {
      final c = s.certs[type]!;
      c.expires = today.add(Duration(days: _between(rng, 3, 28)));
      c.issued = _addMonths(c.expires.add(const Duration(days: 1)), -24);
    }

    expire(bartenders[0], 'tabc');
    expiring(bartenders[1], 'tabc');
    expiring(bartenders[2], 'tabc');
    bartenders[3].certs.remove('tabc');
    expire(cooks[0], 'food_handler');
    expiring(cooks[1], 'food_handler');
    expiring(cooks[2], 'food_handler');
    cooks[3].certs.remove('food_handler');
  }

  Worker _toWorker(_Spec s) {
    final wid = id('worker:${s.employeeNumber}');
    return Worker(
      id: wid,
      venueId: venueId,
      type: s.type,
      employeeNumber: s.employeeNumber,
      firstName: s.first,
      lastName: s.last,
      preferredName: s.preferred,
      dateOfBirth: s.dob,
      phone: s.phone,
      email: s.email,
      uniformSize: s.uniform,
      emergencyContactName: s.emergencyName,
      emergencyContactPhone: s.emergencyPhone,
      preferredLanguage: s.language,
      agencyId: s.agencyId,
      npoGroupId: s.npoGroupId,
      paycomEmployeeCode: s.paycom,
      hireDate: s.hire,
      jobRoles: List.unmodifiable(s.roles),
      certifications: List.unmodifiable([
        for (final type in const ['food_handler', 'tabc'])
          if (s.certs[type] case final c?)
            WorkerCertification(
              id: id('cert:${s.employeeNumber}:$type'),
              workerId: wid,
              typeCode: type,
              number: c.number,
              issuedOn: c.issued,
              expiresOn: c.expires,
            ),
      ]),
    );
  }

  // -------------------------------------------------------------------------------------------
  // Events

  void _buildEvents() {
    const past = [
      (-50, 'hockey'),
      (-46, 'concert'),
      (-43, 'hockey'),
      (-39, 'hockey'),
      (-36, 'family_show'),
      (-32, 'hockey'),
      (-28, 'concert'),
      (-25, 'hockey'),
      (-21, 'hockey'),
      (-18, 'hockey'),
      (-14, 'concert'),
      (-10, 'hockey'),
      (-7, 'hockey'),
      (-3, 'hockey'),
    ];
    const upcoming = [
      (3, 'hockey'),
      (6, 'concert'),
      (9, 'hockey'),
      (12, 'family_show'),
      (16, 'hockey'),
      (20, 'hockey'),
      (24, 'concert'),
      (31, 'hockey'),
      (38, 'hockey'),
      (52, 'family_show'),
    ];
    final used = <DateTime>{today};
    final plans = <_EventPlan>[];
    for (final (offset, type) in [...past, ...upcoming]) {
      var d = today.add(Duration(days: offset));
      if (type == 'family_show') {
        while (d.weekday != DateTime.saturday) {
          d = d.add(const Duration(days: 1));
        }
        if (used.contains(d)) d = d.add(const Duration(days: 1));
      }
      while (used.contains(d)) {
        d = d.add(Duration(days: offset < 0 ? -1 : 1));
      }
      used.add(d);
      plans.add(_EventPlan(d, type));
    }

    final opponents = [..._opponents]..shuffle(srng);
    var opp = 0;
    var concert = 0;
    var family = 0;
    final usedExternal = <int>{};
    String externalId() {
      int n;
      do {
        n = _between(srng, 400000, 499999);
      } while (!usedExternal.add(n));
      return 'PC-$n';
    }

    // The live event: puck drop 15 minutes from now.
    final nowMinute = DateTime.fromMillisecondsSinceEpoch(now.millisecondsSinceEpoch ~/ 60000 * 60000, isUtc: true);
    final liveStart = nowMinute.add(const Duration(minutes: 15));
    final liveDoors = liveStart.subtract(Duration(minutes: rules.eventDefaults.doorsBeforeStartMinutes));
    final liveExpected = _attendance('hockey', today);
    final drafts = <(DateTime, Event Function(String id))>[];
    drafts.add((
      today,
      (eid) => Event(
        id: eid,
        venueId: venueId,
        name: 'Pecan Valley Stampede vs ${opponents[opp++ % opponents.length]}',
        eventTypeCode: 'hockey',
        startTime: liveStart,
        doorsTime: liveDoors,
        callTime: liveDoors.subtract(Duration(minutes: rules.eventDefaults.callBeforeDoorsMinutes)),
        endTime: liveStart.add(const Duration(hours: 3)),
        expectedAttendance: liveExpected,
        status: EventStatus.live,
        source: 'premium_command',
        externalId: externalId(),
        notes: 'Hometown Heroes Night',
      ),
    ));

    for (var i = 0; i < plans.length; i++) {
      final p = plans[i];
      final weekend = p.date.weekday == DateTime.saturday || p.date.weekday == DateTime.sunday;
      final (hour, minute, length) = switch (p.type) {
        'family_show' => (14, 0, 150),
        'concert' => (19, 0, 195),
        _ => weekend ? (18, 0, 165) : (19, 0, 165),
      };
      final start = _central(p.date, hour, minute);
      final doors = start.subtract(Duration(minutes: rules.eventDefaults.doorsBeforeStartMinutes));
      final call = doors.subtract(Duration(minutes: rules.eventDefaults.callBeforeDoorsMinutes));
      final end = start.add(Duration(minutes: length));
      final isPast = end.isBefore(now);
      final expected = _attendance(p.type, p.date);
      final String name;
      var notes = '';
      switch (p.type) {
        case 'concert':
          final (artist, tour) = _concerts[concert++ % _concerts.length];
          name = '$artist: $tour';
        case 'family_show':
          name = _familyShows[family++ % _familyShows.length];
        default:
          name = 'Pecan Valley Stampede vs ${opponents[opp++ % opponents.length]}';
          if (_chance(srng, 0.3)) notes = _pick(srng, _promoNights);
      }
      final manual = (p.type == 'concert' && concert == 2) || (p.type == 'family_show' && family == 2);
      final ext = manual ? null : externalId();
      final actual = isPast ? (expected * (0.9 + srng.nextDouble() * 0.2)).round() : null;
      drafts.add((
        p.date,
        (eid) => Event(
          id: eid,
          venueId: venueId,
          name: name,
          eventTypeCode: p.type,
          startTime: start,
          doorsTime: doors,
          callTime: call,
          endTime: end,
          expectedAttendance: expected,
          actualAttendance: actual,
          status: isPast ? EventStatus.completed : EventStatus.scheduled,
          source: manual ? 'manual' : 'premium_command',
          externalId: ext,
          notes: notes,
        ),
      ));
    }
    drafts.sort((a, b) => a.$1.compareTo(b.$1));
    for (final (date, make) in drafts) {
      events.add(make(id('event:${_dateKey(date)}')));
    }
  }

  String _dateKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  int _attendance(String type, DateTime date) {
    final weekend = date.weekday >= DateTime.friday;
    final (lo, hi) = switch (type) {
      'concert' => (4000, 6500),
      'family_show' => (2000, 4500),
      _ => weekend ? (4000, 5500) : (3000, 4500),
    };
    return _between(srng, lo ~/ 50, hi ~/ 50) * 50;
  }

  // -------------------------------------------------------------------------------------------
  // Staffing and shifts

  void _scheduleEvent(Event e) {
    final ctx = _Ctx(e, _dateKey(_localDate(e.startTime)), _localDate(e.startTime));

    // Which storefronts open: every active one, except a few for small crowds.
    final small = e.expectedAttendance < _smallCrowd;
    final open = {
      for (final sf in storefronts)
        if (sf.active && (!small || _defs[sf.id]!.smallCrowd)) sf.id,
    };
    for (final sf in storefronts) {
      eventStorefronts.add(EventStorefront(eventId: e.id, storefrontId: sf.id, isOpen: open.contains(sf.id)));
    }

    // Staffing scaled from the sellout defaults (about a quarter less for small crowds).
    final f = small ? 0.75 : (e.expectedAttendance / 5500).clamp(0.8, 1.0);
    final barFactor = switch (e.eventTypeCode) {
      'concert' => 1.15,
      'family_show' => 0.6,
      _ => 1.0,
    };
    final end = e.endTime!;
    final scheduledEnd = end.add(const Duration(minutes: 45));
    final positions = <_Pos>[];
    for (final sf in storefronts) {
      if (!open.contains(sf.id)) continue;
      for (final need in _needsBy[sf.id]!) {
        final count = switch (need.jobRoleCode) {
          'lead' || 'runner' => need.count,
          'bartender' => max(1, (need.count * f * barFactor).round()),
          _ => max(1, (need.count * f).round()),
        };
        eventNeeds.add(StaffingNeed(eventId: e.id, storefrontId: sf.id, jobRoleCode: need.jobRoleCode, count: count));
        final roleStations = _stationsBy[sf.id]!.where((s) => s.jobRoleCode == need.jobRoleCode).toList();
        for (var i = 0; i < count; i++) {
          final call = need.jobRoleCode == 'lead' ? e.callTime.subtract(const Duration(minutes: 30)) : e.callTime;
          positions.add(
            _Pos(sf, need.jobRoleCode, roleStations.isEmpty ? null : roleStations[i % roleStations.length].id, call),
          );
        }
      }
    }
    for (var i = 0; i < positions.length; i++) {
      positions[i].id = id('shift:${ctx.key}:${i + 1}');
    }

    // Who is available for this event.
    final available = <String>{};
    for (final w in workers) {
      final p = switch (w.type) {
        WorkerType.regular => 0.93,
        WorkerType.temp => 0.88,
        WorkerType.npo => 0.87,
      };
      if (_chance(srng, p)) available.add(w.id);
    }
    final booked = <String>{};
    void assign(_Pos p, Worker w) {
      p.worker = w;
      p.status = ShiftStatus.assigned;
      booked.add(w.id);
      _shiftCount[w.id] = (_shiftCount[w.id] ?? 0) + 1;
    }

    // Deliberate rule cases at the live event: two 14- or 15-year-olds on a school-night shift.
    if (ctx.isLive) {
      final young = workers
          .where((w) => w.type == WorkerType.regular && (w.ageOn(ctx.day) ?? 99) < 16)
          .take(2)
          .toList();
      for (final w in young) {
        final slot = positions.firstWhere(
          (p) => p.worker == null && w.jobRoles.contains(p.role) && p.storefront.kind == _stand,
          orElse: () => positions.firstWhere((p) => p.worker == null && w.jobRoles.contains(p.role)),
        );
        assign(slot, w);
        slot.deliberateMinor = true;
      }
    }

    // Nonprofit groups staff whole stands together.
    final claimed = <String>{};
    final groupOrder = [for (var g = 0; g < npoGroups.length; g++) g]..shuffle(srng);
    for (final g in groupOrder) {
      if (!_chance(srng, 0.92)) continue;
      var standId = storefronts.firstWhere((s) => _keyOf[s.id] == _npoHomeStands[g]).id;
      if (!open.contains(standId) || claimed.contains(standId)) {
        final options = storefronts
            .where((s) => s.kind == _stand && open.contains(s.id) && !claimed.contains(s.id))
            .where((s) => !_npoHomeStands.contains(_keyOf[s.id]))
            .toList();
        if (options.isEmpty) continue;
        standId = _pick(srng, options).id;
      }
      claimed.add(standId);
      final members = _npoMembers[g]!.where((w) => available.contains(w.id) && !booked.contains(w.id)).toList();
      for (final role in const ['lead', 'cook', 'cashier', 'runner']) {
        for (final p in positions.where((p) => p.storefront.id == standId && p.role == role && p.worker == null)) {
          final cands = members
              .where((w) => !booked.contains(w.id) && _eligible(w, role, ctx, p.call, scheduledEnd))
              .toList();
          if (cands.isEmpty) continue;
          cands.sort((a, b) {
            final c = a.jobRoles.indexOf(role).compareTo(b.jobRoles.indexOf(role));
            return c != 0 ? c : a.employeeNumber.compareTo(b.employeeNumber);
          });
          assign(p, cands.first);
        }
      }
    }

    // Everyone else, scarcest roles first.
    final pool = workers.where((w) => w.type != WorkerType.npo).toList();
    for (final role in const ['bartender', 'lead', 'cook', 'runner', 'cashier']) {
      final todo = positions.where((p) => p.role == role && p.worker == null).toList()..shuffle(srng);
      for (final p in todo) {
        Worker? best;
        var bestScore = double.infinity;
        for (final w in pool) {
          if (booked.contains(w.id) || !available.contains(w.id)) continue;
          if (!_eligible(w, role, ctx, p.call, scheduledEnd)) continue;
          final score =
              (_shiftCount[w.id] ?? 0) +
              (w.jobRoles.first == role ? 0 : 0.75) +
              (w.type == WorkerType.temp ? 0.6 : 0) +
              srng.nextDouble() * 2;
          if (score < bestScore) {
            bestScore = score;
            best = w;
          }
        }
        if (best != null) assign(p, best);
      }
    }

    // Leave some positions open: a few for upcoming and live events, about 1% for past ones.
    // With about 50 positions an event, round past events' 1% at random so it averages out.
    final targetOpen = ctx.isPast
        ? (positions.length * 0.01 + srng.nextDouble()).floor()
        : max(1, (positions.length * (0.03 + srng.nextDouble() * 0.03)).round());
    var openNow = positions.where((p) => p.worker == null).length;
    while (openNow < targetOpen) {
      final cands = positions.where((p) => p.worker != null && p.role != 'lead' && !p.deliberateMinor).toList();
      if (cands.isEmpty) break;
      final p = _weighted(srng, [
        for (final c in cands)
          (
            c,
            switch (c.role) {
              'runner' || 'cashier' => 3,
              _ => 1,
            },
          ),
      ]);
      _shiftCount[p.worker!.id] = _shiftCount[p.worker!.id]! - 1;
      p.worker = null;
      p.status = ShiftStatus.open;
      openNow++;
    }

    if (ctx.isPast) {
      _completedPunches(ctx, positions);
    } else if (ctx.isLive) {
      _livePunches(ctx, positions);
    }

    for (final p in positions) {
      shifts.add(
        Shift(
          id: p.id,
          venueId: venueId,
          eventId: e.id,
          storefrontId: p.storefront.id,
          stationId: p.stationId,
          jobRoleCode: p.role,
          workerId: p.worker?.id,
          callTime: p.call,
          scheduledEnd: scheduledEnd,
          status: p.status,
          releasedAt: p.releasedAt,
          releaseOrder: p.releaseOrder,
          releaseReason: p.status == ShiftStatus.released ? 'Slow stand' : '',
          version: p.status == ShiftStatus.released ? 2 : 1,
        ),
      );
    }
  }

  bool _certValid(Worker w, String type, DateTime day) {
    for (final c in w.certifications) {
      if (c.typeCode != type) continue;
      if (c.issuedOn != null && day.isBefore(c.issuedOn!)) continue;
      if (c.expiresOn != null && day.isAfter(c.expiresOn!)) continue;
      return true;
    }
    return false;
  }

  bool _eligible(Worker w, String role, _Ctx ctx, DateTime call, DateTime end) {
    if (!w.jobRoles.contains(role)) return false;
    final age = w.ageOn(ctx.day) ?? 30;
    final jr = _roles[role]!;
    if (age < rules.minors.minimumWorkingAge) return false;
    if (jr.minimumAge != null && age < jr.minimumAge!) return false;
    if (age < rules.minors.adultAge) {
      final band = rules.minors.bandFor(age);
      if (band != null) {
        if (band.prohibitedJobRoles.contains(role)) return false;
        if (!_minorHoursOk(band, ctx.day, call, end)) return false;
      }
    }
    for (final c in jr.requiredCertifications) {
      if (!_certValid(w, c, ctx.day)) return false;
    }
    return true;
  }

  bool _minorHoursOk(MinorBand band, DateTime day, DateTime call, DateTime end) {
    final start = _toLocal(call);
    final finish = _toLocal(end);
    final startMin = start.hour * 60 + start.minute;
    var endMin = finish.hour * 60 + finish.minute;
    if (finish.day != start.day) endMin += 24 * 60;
    if (band.earliestStart != null && startMin < _hhmm(band.earliestStart!)) return false;
    final summer = day.month >= 6 && day.month <= 8;
    final latest = summer && band.summerLatestEnd != null ? band.summerLatestEnd : band.latestEnd;
    if (latest != null && endMin > _hhmm(latest)) return false;
    final md = day.month * 100 + day.day;
    final ys = int.parse(rules.minors.schoolYearStart.replaceAll('-', ''));
    final ye = int.parse(rules.minors.schoolYearEnd.replaceAll('-', ''));
    final inSchoolYear = md >= ys || md <= ye;
    final schoolDay = inSchoolYear && day.weekday <= DateTime.friday;
    final maxHours = schoolDay ? band.schoolDayMaxHours : band.nonSchoolDayMaxHours;
    if (maxHours != null && end.difference(call).inMinutes > maxHours * 60) return false;
    return true;
  }

  // -------------------------------------------------------------------------------------------
  // Punches

  void _completedPunches(_Ctx ctx, List<_Pos> positions) {
    final e = ctx.event;
    final end = e.endTime!;
    final released = <_Pos>[];
    for (final p in positions) {
      if (p.worker == null) continue;
      if (_chance(srng, 0.02)) continue; // called off or no-show
      final clockIn = _chance(srng, 0.07)
          ? p.call.add(_mins(_between(srng, 6, 40), srng.nextInt(60)))
          : p.call.subtract(_mins(_between(srng, 0, 14), srng.nextInt(60)));
      var out = end.add(_mins(_between(srng, 15, 59), srng.nextInt(60)));
      if (p.role != 'lead' && _chance(srng, 0.02)) {
        final span = max(1, end.difference(e.startTime).inMinutes - 95);
        final at = e.startTime.add(_mins(75 + srng.nextInt(span), srng.nextInt(60)));
        p.status = ShiftStatus.released;
        p.releasedAt = at;
        released.add(p);
        out = at.add(Duration(seconds: 30 + srng.nextInt(150)));
      }
      _emit(ctx, p, [(PunchKind.clockIn, clockIn, null), ..._breaks(clockIn, out), (PunchKind.clockOut, out, null)]);
    }
    _orderReleases(released);
  }

  List<(PunchKind, DateTime, BreakKind?)> _breaks(DateTime clockIn, DateTime out) {
    final res = <(PunchKind, DateTime, BreakKind?)>[];
    final worked = out.difference(clockIn).inMinutes;
    final latestEnd = out.subtract(const Duration(minutes: 10));
    if (worked >= 200 && !_chance(srng, 0.05)) {
      final start = clockIn.add(_mins(_between(srng, 150, 200), srng.nextInt(60)));
      final length = _chance(srng, 0.06) ? _between(srng, 5, 8) : _between(srng, 10, 13);
      final stop = start.add(_mins(length, srng.nextInt(60)));
      if (stop.isBefore(latestEnd)) {
        res
          ..add((PunchKind.breakStart, start, BreakKind.rest))
          ..add((PunchKind.breakEnd, stop, BreakKind.rest));
      }
    }
    if (worked > 360 && !_chance(srng, 0.06)) {
      final start = clockIn.add(_mins(_between(srng, 265, 310), srng.nextInt(60)));
      final length = _chance(srng, 0.06) ? _between(srng, 18, 25) : _between(srng, 30, 35);
      final stop = start.add(_mins(length, srng.nextInt(60)));
      if (stop.isBefore(latestEnd)) {
        res
          ..add((PunchKind.breakStart, start, BreakKind.meal))
          ..add((PunchKind.breakEnd, stop, BreakKind.meal));
      }
    }
    return res;
  }

  void _livePunches(_Ctx ctx, List<_Pos> positions) {
    final e = ctx.event;
    final assigned = positions.where((p) => p.worker != null).toList();
    final pool = assigned.where((p) => p.role != 'lead' && !p.deliberateMinor).toList()..shuffle(srng);
    final notArrived = pool.take(3).toList();
    // One is on a later call and not due yet, one was due 15 minutes ago, one is well past call.
    notArrived[0].call = e.startTime;
    notArrived[1].call = e.doorsTime.add(const Duration(minutes: 30));
    final late = pool.skip(3).take(2).toSet();
    final rest = pool.skip(5).toList();
    final released = rest.where((p) => p.storefront.kind == _kiosk || p.role == 'cashier').take(1).toList();
    final onBreak = rest.where((p) => !released.contains(p)).take(3).toList();
    final latest = now.subtract(const Duration(minutes: 1));

    for (final p in assigned) {
      if (notArrived.contains(p)) continue;
      var clockIn = late.contains(p)
          ? p.call.add(_mins(_between(srng, 6, 40), srng.nextInt(60)))
          : p.call.subtract(_mins(_between(srng, 0, 14), srng.nextInt(60)));
      if (clockIn.isAfter(latest)) clockIn = latest;
      final punches = <(PunchKind, DateTime, BreakKind?)>[(PunchKind.clockIn, clockIn, null)];
      if (released.contains(p)) {
        var at = now.subtract(_mins(_between(srng, 6, 25), srng.nextInt(60)));
        if (at.isBefore(clockIn)) at = clockIn.add(const Duration(minutes: 1));
        p.status = ShiftStatus.released;
        p.releasedAt = at;
        var out = at.add(Duration(seconds: 20 + srng.nextInt(100)));
        if (out.isAfter(now)) out = now;
        punches.add((PunchKind.clockOut, out, null));
      } else if (onBreak.contains(p)) {
        final start = now.subtract(_mins(_between(srng, 1, 8), srng.nextInt(60)));
        if (start.isAfter(clockIn)) punches.add((PunchKind.breakStart, start, BreakKind.rest));
      } else if (now.difference(clockIn).inMinutes > 130 && _chance(srng, 0.08)) {
        final start = clockIn.add(_mins(_between(srng, 95, 115), srng.nextInt(60)));
        final stop = start.add(_mins(_between(srng, 10, 12), srng.nextInt(60)));
        if (stop.isBefore(now.subtract(const Duration(minutes: 2)))) {
          punches
            ..add((PunchKind.breakStart, start, BreakKind.rest))
            ..add((PunchKind.breakEnd, stop, BreakKind.rest));
        }
      }
      _emit(ctx, p, punches);
    }
    _orderReleases(released);
  }

  void _orderReleases(List<_Pos> released) {
    released.sort((a, b) => a.releasedAt!.compareTo(b.releasedAt!));
    for (var i = 0; i < released.length; i++) {
      released[i].releaseOrder = i + 1;
    }
  }

  void _emit(_Ctx ctx, _Pos p, List<(PunchKind, DateTime, BreakKind?)> items) {
    final w = p.worker!;
    final kiosk = _chance(srng, 0.3);
    final device = kiosk ? 'kiosk-concourse-${1 + srng.nextInt(2)}' : 'phone-${w.employeeNumber.toLowerCase()}';
    final baseLat = venueLat + (0.5 - p.storefront.mapY) * 0.0018;
    final baseLng = venueLng + (p.storefront.mapX - 0.5) * 0.0022;
    for (var i = 0; i < items.length; i++) {
      final (kind, at, breakKind) = items[i];
      final pid = id('punch:${p.id}:${i + 1}');
      final double lat;
      final double lng;
      final double accuracy;
      if (kiosk) {
        lat = baseLat;
        lng = baseLng;
        accuracy = 3;
      } else {
        lat = baseLat + (srng.nextDouble() - 0.5) * 0.0003;
        lng = baseLng + (srng.nextDouble() - 0.5) * 0.0003;
        accuracy = _between(srng, 4, 25).toDouble();
      }
      var received = at.add(Duration(seconds: srng.nextInt(91)));
      if (ctx.isLive && received.isAfter(now)) received = now;
      final photo = kind == PunchKind.clockIn || kind == PunchKind.clockOut;
      punches.add(
        Punch(
          id: pid,
          venueId: venueId,
          workerId: w.id,
          eventId: ctx.event.id,
          shiftId: p.id,
          kind: kind,
          breakKind: breakKind,
          occurredAt: at,
          receivedAt: received,
          source: kiosk ? PunchSource.kiosk : PunchSource.phone,
          deviceId: device,
          latitude: (lat * 1e6).round() / 1e6,
          longitude: (lng * 1e6).round() / 1e6,
          accuracyMeters: accuracy,
          withinGeofence: true,
          photoPath: photo ? 'punch-photos/$venueId/$pid.jpg' : null,
        ),
      );
    }
  }
}

String _ascii(String s) {
  const map = {'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ñ': 'n', 'ü': 'u'};
  final buf = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    final m = map[ch] ?? ch;
    if (RegExp(r'[a-z0-9]').hasMatch(m)) buf.write(m);
  }
  return buf.toString();
}

// ---------------------------------------------------------------------------------------------
// Names (all fictional)

const _npoDefs = [
  ('Pecan Valley High School Band Boosters', 'Pecan Valley High School Band Booster Club, Inc.'),
  ('Allenridge Youth Soccer Association', 'Allenridge Youth Soccer Association, Inc.'),
];

const _opponents = [
  'Panhandle Blizzard',
  'Big Bend Coyotes',
  'Bayou City Barracudas',
  'Prairie Lake Lynx',
  'Cimarron Wolves',
  'Sabine River Bulldogs',
  'Caprock Comets',
  'Red River Bandits',
  'Hill Country Outlaws',
];

const _concerts = [
  ('Luna Vega', 'Desert Bloom Tour'),
  ('The Mesquite Ramblers', 'Live in Pecan Valley'),
  ('Copper Canyon Revival', 'Homecoming Tour'),
  ('Marisol y Los Cardenales', 'Gira Corazón'),
  ('Neon Prairie', 'Midnight Highway Tour'),
];

const _familyShows = ['Big Top Wonder Circus', 'Dino Discovery Live', 'Starlight Ice Spectacular: Holiday Edition'];

const _promoNights = [
  'Fan Appreciation Night',
  'Military Appreciation Night',
  'Teddy Bear Toss',
  'Dollar Dog Night',
  'Youth Hockey Night',
];

const _hispanicMale = [
  'José', 'Juan', 'Luis', 'Carlos', 'Miguel', 'Jorge', 'Alejandro', 'Diego', 'Ricardo', 'Fernando', //
  'Javier', 'Raúl', 'Eduardo', 'Héctor', 'Adrián', 'Mateo', 'Santiago', 'Gabriel', 'Óscar', 'Rubén',
  'Arturo', 'Emilio', 'Francisco', 'Manuel', 'Roberto',
];
const _hispanicFemale = [
  'María', 'Ana', 'Sofía', 'Lucía', 'Gabriela', 'Daniela', 'Valeria', 'Isabel', 'Camila', 'Ximena', //
  'Rosa', 'Guadalupe', 'Alejandra', 'Mariana', 'Verónica', 'Leticia', 'Yesenia', 'Itzel', 'Paola', 'Elena',
  'Claudia', 'Adriana', 'Marisol',
];
const _hispanicLast = [
  'García', 'Martínez', 'Rodríguez', 'Hernández', 'López', 'González', 'Pérez', 'Sánchez', 'Ramírez', //
  'Torres', 'Flores', 'Rivera', 'Gómez', 'Díaz', 'Reyes', 'Morales', 'Cruz', 'Ortiz', 'Gutiérrez', 'Chávez',
  'Ramos', 'Ruiz', 'Mendoza', 'Vásquez', 'Castillo', 'Jiménez', 'Moreno', 'Salazar', 'Guerrero', 'Delgado',
  'Cantú', 'Treviño', 'Garza', 'Saldaña', 'Villarreal', 'Zamora', 'Escobedo', 'Ybarra',
];
const _angloMale = [
  'James', 'Michael', 'Robert', 'David', 'William', 'John', 'Christopher', 'Daniel', 'Matthew', 'Joshua', //
  'Andrew', 'Tyler', 'Brandon', 'Justin', 'Austin', 'Kevin', 'Jason', 'Ryan', 'Cody', 'Dustin', 'Travis',
  'Kenneth', 'Brian', 'Eric', 'Wyatt', 'Colton', 'Hunter', 'Caleb', 'Ethan', 'Noah', 'Liam', 'Garrett',
];
const _angloFemale = [
  'Jennifer', 'Jessica', 'Ashley', 'Sarah', 'Emily', 'Amanda', 'Brittany', 'Megan', 'Lauren', 'Hannah', //
  'Taylor', 'Kayla', 'Madison', 'Abigail', 'Olivia', 'Emma', 'Ava', 'Chloe', 'Heather', 'Amber',
  'Kimberly', 'Rachel', 'Courtney', 'Haley', 'Savannah', 'Kelsey',
];
const _blackMale = [
  'Marcus', 'Darius', 'Andre', 'Terrence', 'Jamal', 'Malik', 'Isaiah', 'DeShawn', 'Xavier', 'Cedric', //
  'Jalen', 'Reginald', 'Damon',
];
const _blackFemale = [
  'Aaliyah', 'Keisha', 'Tamika', 'Jasmine', 'Destiny', 'Brianna', 'Imani', 'Latoya', 'Ebony', 'Nia', //
  'Shanice', 'Monique',
];
const _commonLast = [
  'Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Miller', 'Davis', 'Wilson', 'Anderson', 'Taylor', //
  'Thomas', 'Moore', 'Jackson', 'Martin', 'Thompson', 'White', 'Harris', 'Clark', 'Lewis', 'Robinson',
  'Walker', 'Young', 'Allen', 'King', 'Wright', 'Scott', 'Hill', 'Green', 'Adams', 'Baker', 'Nelson',
  'Carter', 'Mitchell', 'Roberts', 'Turner', 'Phillips', 'Campbell', 'Parker', 'Evans', 'Edwards',
  'Collins', 'Stewart', 'Morris', 'Murphy', 'Cook', 'Rogers', 'Reed', 'Bailey', 'Bell', 'Cooper',
  'Richardson', 'Cox', 'Howard', 'Ward', 'Peterson', 'Gray', 'Watson', 'Brooks', 'Sanders', 'Price',
  'Bennett', 'Barnes', 'Ross', 'Henderson', 'Coleman', 'Jenkins', 'Perry', 'Powell', 'Patterson',
  'Hughes', 'Washington', 'Butler', 'Simmons', 'Foster', 'Bryant', 'Russell', 'Griffin', 'Hayes',
  'Myers', 'Ford', 'Hamilton', 'Graham', 'Sullivan', 'Wallace', 'Woods', 'Cole', 'Owens', 'Schulz',
  'Weber', 'Hoffmann', 'Kowalski', 'Dawson', 'Holt', 'McKinney',
];
const _asianNames = [
  ('Nguyen', ['Minh', 'Linh', 'Tuan', 'Thao', 'Huy', 'Mai', 'Kevin', 'Vivian']),
  ('Tran', ['Duc', 'Lan', 'Anh', 'Peter', 'Hanh']),
  ('Pham', ['Long', 'Ngoc', 'Jenny', 'Bao']),
  ('Le', ['Khanh', 'Trinh', 'David', 'Hoa']),
  ('Patel', ['Priya', 'Raj', 'Anjali', 'Nikhil', 'Meera']),
  ('Kim', ['Grace', 'Joon', 'Esther', 'Daniel']),
  ('Chen', ['Wei', 'Lily', 'Jason', 'Mei']),
];

const _nicknames = {
  'Robert': 'Bobby',
  'William': 'Will',
  'Michael': 'Mike',
  'Christopher': 'Chris',
  'Daniel': 'Danny',
  'Matthew': 'Matt',
  'Joshua': 'Josh',
  'Alejandro': 'Alex',
  'Guadalupe': 'Lupe',
  'Jennifer': 'Jen',
  'Kimberly': 'Kim',
  'Francisco': 'Paco',
  'Jessica': 'Jess',
  'Abigail': 'Abby',
  'Andrew': 'Drew',
  'Kenneth': 'Ken',
  'Ricardo': 'Ricky',
  'Eduardo': 'Lalo',
  'Roberto': 'Beto',
  'Santiago': 'Santi',
};
