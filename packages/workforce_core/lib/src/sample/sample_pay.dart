/// Sample pay setup for the sample arena: hourly rates by role, a few personal rates,
/// agency bill rates, the NPO agreement, earnings codes, and bar tip pools for past
/// events. Fictional numbers in a realistic Texas range; replace with the venue's own.
library;

import 'dart:math';

import '../model/enums.dart';
import '../pay/pay_models.dart';
import 'sample_arena.dart';

class SamplePay {
  const SamplePay({
    required this.payCodes,
    required this.rates,
    required this.differentials,
    required this.billRates,
    required this.npoAgreements,
    required this.tipPools,
  });

  final List<PayCode> payCodes;
  final List<PayRate> rates;
  final List<PayDifferential> differentials;
  final List<AgencyBillRate> billRates;
  final List<NpoAgreement> npoAgreements;

  /// One pool per open bar at each completed event (allocations are calculated by the app).
  final List<TipPool> tipPools;

  static final _seasonStart = DateTime.utc(2026, 8, 1);

  /// Hourly base rate by role, in cents.
  static const roleRates = {'lead': 1700, 'cook': 1450, 'cashier': 1300, 'runner': 1250, 'bartender': 1350};

  /// Agency bill rate by role, in cents (about 1.45 times pay).
  static const billRateByRole = {'lead': 2500, 'cook': 2100, 'cashier': 1900, 'runner': 1800, 'bartender': 2000};

  factory SamplePay.generate(SampleArena arena) {
    final venueId = arena.venue.id;
    final rng = Random(arena.seed + 7);
    String id(String key) => _uuidFrom('${arena.seed}:pay:$key');

    final payCodes = [
      for (final (code, name, kind, sort) in const [
        ('REG', 'Regular', PayCodeKind.regular, 1),
        ('OT', 'Overtime', PayCodeKind.overtime, 2),
        ('TIPS', 'Tips (pooled)', PayCodeKind.tips, 3),
        ('LEAD', 'Lead differential', PayCodeKind.differential, 4),
        ('BONUS', 'Bonus', PayCodeKind.bonus, 5),
        ('TIPMU', 'Tip credit make-up', PayCodeKind.tipCreditMakeup, 6),
      ])
        PayCode(venueId: venueId, code: code, name: name, kind: kind, sort: sort),
    ];

    final rates = <PayRate>[
      for (final e in roleRates.entries)
        PayRate(id: id('role:${e.key}'), venueId: venueId, jobRoleCode: e.key, hourlyRateCents: e.value, effectiveFrom: _seasonStart),
    ];
    // Returning staff hired before 2024 earn 50 cents more as cooks and cashiers.
    for (final w in arena.workers.where((w) => w.type == WorkerType.regular)) {
      final hired = w.hireDate;
      if (hired == null || hired.year >= 2024) continue;
      for (final role in w.jobRoles.where((r) => r == 'cook' || r == 'cashier')) {
        rates.add(PayRate(
          id: id('worker:${w.id}:$role'),
          venueId: venueId,
          workerId: w.id,
          jobRoleCode: role,
          hourlyRateCents: roleRates[role]! + 50,
          effectiveFrom: _seasonStart,
          note: 'Returning staff',
        ));
      }
    }

    final differentials = <PayDifferential>[
      // Concert nights pay leads an extra dollar an hour.
      PayDifferential(
        id: id('diff:lead-concert'),
        venueId: venueId,
        name: 'Concert lead pay',
        payCode: 'LEAD',
        jobRoleCode: 'lead',
        eventTypeCode: 'concert',
        perHourCents: 100,
        effectiveFrom: _seasonStart,
      ),
    ];

    final billRates = [
      for (final a in arena.agencies)
        for (final e in billRateByRole.entries)
          AgencyBillRate(
            id: id('bill:${a.id}:${e.key}'),
            venueId: venueId,
            agencyId: a.id,
            jobRoleCode: e.key,
            billRateCents: e.value + (a == arena.agencies.first ? 0 : 75),
            overtimeBillRateCents: (e.value * 3) ~/ 2,
            effectiveFrom: _seasonStart,
          ),
    ];

    final npoAgreements = [
      NpoAgreement(
        id: id('npo:default'),
        venueId: venueId,
        hourlyRateCents: 1100,
        minHeadcount: 7,
        shortfallDeductionCents: 5000,
        noShowDeductionCents: 2500,
        effectiveFrom: _seasonStart,
      ),
    ];

    final bars = {for (final s in arena.storefronts) if (s.kind == StorefrontKind.bar) s.id};
    final tipPools = <TipPool>[];
    for (final e in arena.events.where((e) => e.status == EventStatus.completed)) {
      final open = arena.eventStorefronts.where((es) => es.eventId == e.id && es.isOpen && bars.contains(es.storefrontId));
      for (final es in open) {
        final attendance = e.actualAttendance ?? e.expectedAttendance;
        // About 9 to 14 cents per attendee per bar, rounded to the dollar.
        final cents = ((attendance * (9 + rng.nextInt(6))) ~/ 100) * 100;
        tipPools.add(TipPool(
          id: id('tips:${e.id}:${es.storefrontId}'),
          venueId: venueId,
          eventId: e.id,
          storefrontId: es.storefrontId,
          amountCents: cents,
          source: 'import',
          method: 'hours',
          status: 'draft',
        ));
      }
    }

    return SamplePay(
      payCodes: payCodes,
      rates: rates,
      differentials: differentials,
      billRates: billRates,
      npoAgreements: npoAgreements,
      tipPools: tipPools,
    );
  }

  /// Rows for the SQL seed, in insert order. Pay codes come from the venue trigger.
  Map<String, List<Map<String, dynamic>>> toTables() => {
        'pay_rates': [for (final r in rates) r.toJson()],
        'pay_differentials': [for (final d in differentials) d.toJson()],
        'agency_bill_rates': [for (final b in billRates) b.toJson()],
        'npo_agreements': [for (final a in npoAgreements) a.toJson()],
        'tip_pools': [for (final t in tipPools) t.toJson()],
      };
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
