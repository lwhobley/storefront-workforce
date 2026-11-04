/// A venue's pay settings, stored in `venues.settings['pay']`.
///
/// Thresholds and the workweek come from [OvertimeRules] in [VenueRules]; the pay
/// period frequency and anchor come from [PayPeriodRules]. Everything here is money.
/// Defaults are Texas / federal. Items marked CONFIRM should be checked with HR or an
/// employment attorney before the first payroll.
library;

import 'money.dart';

/// Federal tip credit (29 U.S.C. 203(m)); Texas follows the federal numbers.
class TipCreditRules {
  const TipCreditRules({this.enabled = false, this.cashWageCents = 213});

  /// Venue-wide switch. Even when on, the credit is taken only for the workers the
  /// caller lists (see `tipCreditWorkers` in the earnings engine).
  final bool enabled;

  /// Cash wage paid per hour when the credit is taken. Federal minimum is $2.13.
  final int cashWageCents;

  factory TipCreditRules.fromJson(Map<String, dynamic>? j) {
    const d = TipCreditRules();
    if (j == null) return d;
    return TipCreditRules(
      enabled: (j['enabled'] as bool?) ?? d.enabled,
      cashWageCents: j['cash_wage'] == null ? d.cashWageCents : parseCents(j['cash_wage']),
    );
  }

  Map<String, dynamic> toJson() => {'enabled': enabled, 'cash_wage': centsToJson(cashWageCents)};
}

class TipPoolRules {
  const TipPoolRules({
    this.method = 'hours',
    this.eligibleRoles = const ['bartender', 'runner', 'cook', 'cashier'],
    this.includeWorkerTypes = const ['regular'],
  });

  /// Default method for new pools: hours, role_points, or equal.
  final String method;

  /// Job roles that share in tip pools. 'lead' is left out by default because
  /// managers and supervisors may not keep tips from a pool (29 U.S.C. 203(m)(2)(B)).
  /// CONFIRM with HR whether leads here meet the FLSA definition of supervisor.
  final List<String> eligibleRoles;

  /// Worker types that share in pools. Only regular staff are paid through payroll,
  /// so a temp's or NPO member's share would never reach them; they are left out by
  /// default. CONFIRM with HR and the agencies before adding 'temp' or 'npo'.
  final List<String> includeWorkerTypes;

  factory TipPoolRules.fromJson(Map<String, dynamic>? j) {
    const d = TipPoolRules();
    if (j == null) return d;
    List<String>? list(Object? v) => v == null ? null : [for (final e in v as List) e as String];
    return TipPoolRules(
      method: (j['method'] as String?) ?? d.method,
      eligibleRoles: list(j['eligible_roles']) ?? d.eligibleRoles,
      includeWorkerTypes: list(j['include_worker_types']) ?? d.includeWorkerTypes,
    );
  }

  Map<String, dynamic> toJson() => {
        'method': method,
        'eligible_roles': eligibleRoles,
        'include_worker_types': includeWorkerTypes,
        // Fixed: cents, largest remainder, ties by worker id.
        'rounding': 'largest_remainder_cent',
      };
}

class PayRules {
  const PayRules({
    this.minimumWageCents = 725,
    this.tipCredit = const TipCreditRules(),
    this.overtimeMultiplierThousandths = 1500,
    this.tipPool = const TipPoolRules(),
    this.paydayDaysAfterEnd = 5,
    this.laborBurdenBasisPoints = 0,
  });

  /// Starting pay rules for a Texas venue.
  static const texasDefaults = PayRules();

  /// Per hour. Texas follows the federal $7.25.
  final int minimumWageCents;
  final TipCreditRules tipCredit;

  /// Overtime multiplier in thousandths: 1500 is time and a half.
  final int overtimeMultiplierThousandths;
  final TipPoolRules tipPool;

  /// Payday is this many days after the period's last day.
  final int paydayDaysAfterEnd;

  /// Employer taxes and benefits on top of wages, for labor cost only, in basis
  /// points of a percent (765 = 7.65%).
  final int laborBurdenBasisPoints;

  /// Tip credit per hour: minimum wage minus the cash wage.
  int get tipCreditCents => minimumWageCents - tipCredit.cashWageCents;

  double get overtimeMultiplier => overtimeMultiplierThousandths / 1000;
  double get laborBurdenPercent => laborBurdenBasisPoints / 100;

  /// Reads `settings['pay']`. When `payday_days_after_end` is not there it is also
  /// looked for in `settings['pay_period']`, which is where the database function
  /// `ensure_pay_periods` reads it.
  factory PayRules.fromVenueSettings(Map<String, dynamic> settings) {
    final pay = (settings['pay'] as Map?)?.cast<String, dynamic>();
    final period = (settings['pay_period'] as Map?)?.cast<String, dynamic>();
    final lag = pay?['payday_days_after_end'] ?? period?['payday_days_after_end'];
    return PayRules.fromJson({...?pay, 'payday_days_after_end': ?lag});
  }

  factory PayRules.fromJson(Map<String, dynamic>? j) {
    const d = PayRules();
    if (j == null) return d;
    return PayRules(
      minimumWageCents: j['minimum_wage'] == null ? d.minimumWageCents : parseCents(j['minimum_wage']),
      tipCredit: TipCreditRules.fromJson((j['tip_credit'] as Map?)?.cast<String, dynamic>()),
      overtimeMultiplierThousandths: j['overtime_multiplier'] == null
          ? d.overtimeMultiplierThousandths
          : parseScaled(j['overtime_multiplier'], 3),
      tipPool: TipPoolRules.fromJson((j['tip_pool'] as Map?)?.cast<String, dynamic>()),
      paydayDaysAfterEnd: (j['payday_days_after_end'] as num?)?.toInt() ?? d.paydayDaysAfterEnd,
      laborBurdenBasisPoints:
          j['labor_burden_percent'] == null ? d.laborBurdenBasisPoints : parseScaled(j['labor_burden_percent'], 2),
    );
  }

  Map<String, dynamic> toJson() => {
        'minimum_wage': centsToJson(minimumWageCents),
        'tip_credit': tipCredit.toJson(),
        'overtime_multiplier': overtimeMultiplierThousandths / 1000,
        'tip_pool': tipPool.toJson(),
        'payday_days_after_end': paydayDaysAfterEnd,
        'labor_burden_percent': laborBurdenBasisPoints / 100,
      };

  /// Settings that are below the federal floor or otherwise suspicious.
  List<String> complianceNotes() => [
        if (minimumWageCents < 725) 'Minimum wage is below the federal \$7.25.',
        if (tipCredit.enabled && tipCredit.cashWageCents < 213)
          'Tip credit cash wage is below the federal \$2.13.',
        if (tipCredit.enabled && tipCredit.cashWageCents >= minimumWageCents)
          'Tip credit is on but the cash wage is not below minimum wage, so no credit is taken.',
        if (overtimeMultiplierThousandths < 1500) 'Overtime multiplier is below the federal 1.5.',
        if (paydayDaysAfterEnd < 0) 'Payday is before the end of the pay period.',
        if (tipPool.eligibleRoles.contains('lead'))
          'Leads are in the tip pool. Supervisors may not share in tip pools; confirm leads are not supervisors.',
      ];
}
