/// Records for the Phase 2 pay tables (migration 0009_pay.sql). JSON keys are the
/// database column names. Money is held as integer cents, hours as hundredths, the
/// line rate as E4 (ten-thousandths of a dollar), points as thousandths; see money.dart.
///
/// `toJson` leaves out server-managed columns (ids from identity columns, created_at,
/// created_by, ...) when they are null, so the map can be inserted as is.
library;

import '../rules/local_time.dart';
import 'money.dart';

DateTime _date(Object? v) {
  final d = DateTime.parse(v as String);
  return DateTime.utc(d.year, d.month, d.day);
}

DateTime? _dateOrNull(Object? v) => v == null ? null : _date(v);
DateTime? _instant(Object? v) => v == null ? null : DateTime.parse(v as String).toUtc();
String? _iso(DateTime? d) => d?.toUtc().toIso8601String();
String? _dateStr(DateTime? d) => d == null ? null : formatDate(d);

/// True when [date] (a calendar date) is within [from, to], with [to] null meaning open.
bool isEffectiveOn(DateTime date, DateTime from, DateTime? to) =>
    !date.isBefore(from) && (to == null || !date.isAfter(to));

/// The kind column of `pay_codes`.
enum PayCodeKind {
  regular('regular'),
  overtime('overtime'),
  tips('tips'),
  differential('differential'),
  bonus('bonus'),
  tipCreditMakeup('tip_credit_makeup'),
  other('other');

  const PayCodeKind(this.code);
  final String code;

  static PayCodeKind fromCode(String? code) =>
      values.firstWhere((v) => v.code == code, orElse: () => PayCodeKind.other);
}

/// Built-in earnings codes, seeded for every venue.
abstract final class PayCodes {
  static const regular = 'REG';
  static const overtime = 'OT';
  static const tips = 'TIPS';
  static const lead = 'LEAD';
  static const bonus = 'BONUS';
  static const tipCreditMakeup = 'TIPMU';

  /// Kind of a code when the venue's pay_codes list does not say.
  static PayCodeKind defaultKind(String code) => switch (code) {
        regular => PayCodeKind.regular,
        overtime => PayCodeKind.overtime,
        tips => PayCodeKind.tips,
        lead => PayCodeKind.differential,
        bonus => PayCodeKind.bonus,
        tipCreditMakeup => PayCodeKind.tipCreditMakeup,
        _ => PayCodeKind.other,
      };
}

class PayCode {
  const PayCode({
    required this.venueId,
    required this.code,
    required this.name,
    required this.kind,
    this.paycomCode = '',
    this.sort = 0,
  });

  final String venueId;
  final String code;
  final String name;
  final PayCodeKind kind;

  /// Code to use in Paycom; empty until the venue enters it.
  final String paycomCode;
  final int sort;

  factory PayCode.fromJson(Map<String, dynamic> j) => PayCode(
        venueId: j['venue_id'] as String,
        code: j['code'] as String,
        name: j['name'] as String,
        kind: PayCodeKind.fromCode(j['kind'] as String?),
        paycomCode: (j['paycom_code'] as String?) ?? '',
        sort: (j['sort'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'venue_id': venueId,
        'code': code,
        'name': name,
        'kind': kind.code,
        'paycom_code': paycomCode,
        'sort': sort,
      };
}

class PayRate {
  const PayRate({
    required this.id,
    required this.venueId,
    required this.hourlyRateCents,
    required this.effectiveFrom,
    this.workerId,
    this.jobRoleCode,
    this.eventTypeCode,
    this.effectiveTo,
    this.note = '',
    this.createdBy,
    this.createdAt,
  });

  final String id;
  final String venueId;
  final String? workerId;
  final String? jobRoleCode;
  final String? eventTypeCode;
  final int hourlyRateCents;

  /// Calendar dates; [effectiveTo] is inclusive, null means open-ended.
  final DateTime effectiveFrom;
  final DateTime? effectiveTo;
  final String note;
  final String? createdBy;
  final DateTime? createdAt;

  bool isActiveOn(DateTime date) => isEffectiveOn(date, effectiveFrom, effectiveTo);

  factory PayRate.fromJson(Map<String, dynamic> j) => PayRate(
        id: j['id'] as String,
        venueId: j['venue_id'] as String,
        workerId: j['worker_id'] as String?,
        jobRoleCode: j['job_role_code'] as String?,
        eventTypeCode: j['event_type_code'] as String?,
        hourlyRateCents: parseCents(j['hourly_rate']),
        effectiveFrom: _date(j['effective_from']),
        effectiveTo: _dateOrNull(j['effective_to']),
        note: (j['note'] as String?) ?? '',
        createdBy: j['created_by'] as String?,
        createdAt: _instant(j['created_at']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'venue_id': venueId,
        'worker_id': workerId,
        'job_role_code': jobRoleCode,
        'event_type_code': eventTypeCode,
        'hourly_rate': centsToJson(hourlyRateCents),
        'effective_from': _dateStr(effectiveFrom),
        'effective_to': _dateStr(effectiveTo),
        'note': note,
        if (createdBy != null) 'created_by': createdBy,
        if (createdAt != null) 'created_at': _iso(createdAt),
      };
}

/// Extra pay on top of the rate: per hour (lead pay) and/or per shift.
class PayDifferential {
  const PayDifferential({
    required this.id,
    required this.venueId,
    required this.name,
    required this.payCode,
    required this.effectiveFrom,
    this.jobRoleCode,
    this.workerId,
    this.eventTypeCode,
    this.perHourCents = 0,
    this.perShiftCents = 0,
    this.effectiveTo,
    this.createdAt,
  });

  final String id;
  final String venueId;
  final String name;
  final String payCode;
  final String? jobRoleCode;
  final String? workerId;
  final String? eventTypeCode;
  final int perHourCents;
  final int perShiftCents;
  final DateTime effectiveFrom;
  final DateTime? effectiveTo;
  final DateTime? createdAt;

  bool isActiveOn(DateTime date) => isEffectiveOn(date, effectiveFrom, effectiveTo);

  factory PayDifferential.fromJson(Map<String, dynamic> j) => PayDifferential(
        id: j['id'] as String,
        venueId: j['venue_id'] as String,
        name: j['name'] as String,
        payCode: j['pay_code'] as String,
        jobRoleCode: j['job_role_code'] as String?,
        workerId: j['worker_id'] as String?,
        eventTypeCode: j['event_type_code'] as String?,
        perHourCents: j['per_hour'] == null ? 0 : parseCents(j['per_hour']),
        perShiftCents: j['per_shift'] == null ? 0 : parseCents(j['per_shift']),
        effectiveFrom: _date(j['effective_from']),
        effectiveTo: _dateOrNull(j['effective_to']),
        createdAt: _instant(j['created_at']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'venue_id': venueId,
        'name': name,
        'pay_code': payCode,
        'job_role_code': jobRoleCode,
        'worker_id': workerId,
        'event_type_code': eventTypeCode,
        'per_hour': centsToJson(perHourCents),
        'per_shift': centsToJson(perShiftCents),
        'effective_from': _dateStr(effectiveFrom),
        'effective_to': _dateStr(effectiveTo),
        if (createdAt != null) 'created_at': _iso(createdAt),
      };
}

/// A manager's proposed punch change (add, void, or replace).
class TimeCorrection {
  const TimeCorrection({
    required this.id,
    required this.venueId,
    required this.workerId,
    required this.action,
    required this.reason,
    this.eventId,
    this.punchId,
    this.newKind,
    this.newBreakKind,
    this.newOccurredAt,
    this.status = 'pending',
    this.requestedBy,
    this.requestedAt,
    this.decidedBy,
    this.decidedAt,
    this.decisionNote = '',
    this.resultPunchId,
  });

  final String id;
  final String venueId;
  final String workerId;
  final String? eventId;

  /// add, void, or replace.
  final String action;
  final String? punchId;

  /// clock_in, clock_out, break_start, break_end.
  final String? newKind;

  /// meal or rest.
  final String? newBreakKind;
  final DateTime? newOccurredAt;
  final String reason;

  /// pending, approved, rejected.
  final String status;
  final String? requestedBy;
  final DateTime? requestedAt;
  final String? decidedBy;
  final DateTime? decidedAt;
  final String decisionNote;
  final String? resultPunchId;

  factory TimeCorrection.fromJson(Map<String, dynamic> j) => TimeCorrection(
        id: j['id'] as String,
        venueId: j['venue_id'] as String,
        workerId: j['worker_id'] as String,
        eventId: j['event_id'] as String?,
        action: j['action'] as String,
        punchId: j['punch_id'] as String?,
        newKind: j['new_kind'] as String?,
        newBreakKind: j['new_break_kind'] as String?,
        newOccurredAt: _instant(j['new_occurred_at']),
        reason: j['reason'] as String,
        status: (j['status'] as String?) ?? 'pending',
        requestedBy: j['requested_by'] as String?,
        requestedAt: _instant(j['requested_at']),
        decidedBy: j['decided_by'] as String?,
        decidedAt: _instant(j['decided_at']),
        decisionNote: (j['decision_note'] as String?) ?? '',
        resultPunchId: j['result_punch_id'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'venue_id': venueId,
        'worker_id': workerId,
        'event_id': eventId,
        'action': action,
        'punch_id': punchId,
        'new_kind': newKind,
        'new_break_kind': newBreakKind,
        'new_occurred_at': _iso(newOccurredAt),
        'reason': reason,
        'status': status,
        if (requestedBy != null) 'requested_by': requestedBy,
        if (requestedAt != null) 'requested_at': _iso(requestedAt),
        'decided_by': decidedBy,
        'decided_at': _iso(decidedAt),
        'decision_note': decisionNote,
        'result_punch_id': resultPunchId,
      };
}

class PayPeriod {
  const PayPeriod({
    required this.startsOn,
    required this.endsOn,
    required this.payDate,
    this.id,
    this.venueId,
    this.status = 'open',
    this.approvedBy,
    this.approvedAt,
    this.rulesVersion,
    this.createdAt,
  });

  /// Null for a period generated in memory and not yet stored.
  final String? id;
  final String? venueId;

  /// Calendar dates, inclusive.
  final DateTime startsOn;
  final DateTime endsOn;
  final DateTime payDate;

  /// open, approved, exported.
  final String status;
  final String? approvedBy;
  final DateTime? approvedAt;
  final int? rulesVersion;
  final DateTime? createdAt;

  bool contains(DateTime date) => isEffectiveOn(date, startsOn, endsOn);

  /// Number of calendar days in the period.
  int get days => DateTime.utc(endsOn.year, endsOn.month, endsOn.day)
          .difference(DateTime.utc(startsOn.year, startsOn.month, startsOn.day))
          .inDays +
      1;

  factory PayPeriod.fromJson(Map<String, dynamic> j) => PayPeriod(
        id: j['id'] as String?,
        venueId: j['venue_id'] as String?,
        startsOn: _date(j['starts_on']),
        endsOn: _date(j['ends_on']),
        payDate: _date(j['pay_date']),
        status: (j['status'] as String?) ?? 'open',
        approvedBy: j['approved_by'] as String?,
        approvedAt: _instant(j['approved_at']),
        rulesVersion: (j['rules_version'] as num?)?.toInt(),
        createdAt: _instant(j['created_at']),
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        if (venueId != null) 'venue_id': venueId,
        'starts_on': _dateStr(startsOn),
        'ends_on': _dateStr(endsOn),
        'pay_date': _dateStr(payDate),
        'status': status,
        'approved_by': approvedBy,
        'approved_at': _iso(approvedAt),
        'rules_version': rulesVersion,
        if (createdAt != null) 'created_at': _iso(createdAt),
      };

  @override
  bool operator ==(Object other) =>
      other is PayPeriod && other.startsOn == startsOn && other.endsOn == endsOn && other.payDate == payDate;

  @override
  int get hashCode => Object.hash(startsOn, endsOn, payDate);

  @override
  String toString() => 'PayPeriod(${_dateStr(startsOn)}..${_dateStr(endsOn)}, pay ${_dateStr(payDate)})';
}

/// One earnings line: a person, a day, an earnings code (pay_period_lines).
class PayLine {
  const PayLine({
    required this.workerId,
    required this.workDate,
    required this.payCode,
    required this.amountCents,
    this.hoursHundredths = 0,
    this.rateE4,
    this.eventId,
    this.storefrontId,
    this.jobRoleCode,
    this.id,
    this.venueId,
    this.payPeriodId,
    this.minutes,
    this.roundingAdjustmentCents = 0,
  });

  final int? id;
  final String? venueId;
  final String? payPeriodId;
  final String workerId;

  /// Venue-local calendar date of the work.
  final DateTime workDate;
  final String? eventId;
  final String? storefrontId;
  final String? jobRoleCode;
  final String payCode;

  /// Hours to 2 decimals, as hundredths.
  final int hoursHundredths;

  /// Rate to 4 decimals, as ten-thousandths of a dollar. Null for amount-only lines.
  final int? rateE4;
  final int amountCents;

  /// Exact minutes behind [hoursHundredths], when calculated here (not stored).
  final int? minutes;

  /// Cents added to (or taken from) this line so the workweek total is exact.
  /// Part of [amountCents]; not stored.
  final int roundingAdjustmentCents;

  PayLine copyWith({int? hoursHundredths, int? amountCents, int? roundingAdjustmentCents, String? payPeriodId}) =>
      PayLine(
        id: id,
        venueId: venueId,
        payPeriodId: payPeriodId ?? this.payPeriodId,
        workerId: workerId,
        workDate: workDate,
        eventId: eventId,
        storefrontId: storefrontId,
        jobRoleCode: jobRoleCode,
        payCode: payCode,
        hoursHundredths: hoursHundredths ?? this.hoursHundredths,
        rateE4: rateE4,
        amountCents: amountCents ?? this.amountCents,
        minutes: minutes,
        roundingAdjustmentCents: roundingAdjustmentCents ?? this.roundingAdjustmentCents,
      );

  factory PayLine.fromJson(Map<String, dynamic> j) => PayLine(
        id: (j['id'] as num?)?.toInt(),
        venueId: j['venue_id'] as String?,
        payPeriodId: j['pay_period_id'] as String?,
        workerId: j['worker_id'] as String,
        workDate: _date(j['work_date']),
        eventId: j['event_id'] as String?,
        storefrontId: j['storefront_id'] as String?,
        jobRoleCode: j['job_role_code'] as String?,
        payCode: j['pay_code'] as String,
        hoursHundredths: j['hours'] == null ? 0 : parseScaled(j['hours'], 2),
        rateE4: parseScaledOrNull(j['rate'], 4),
        amountCents: j['amount'] == null ? 0 : parseCents(j['amount']),
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        if (venueId != null) 'venue_id': venueId,
        if (payPeriodId != null) 'pay_period_id': payPeriodId,
        'worker_id': workerId,
        'work_date': _dateStr(workDate),
        'event_id': eventId,
        'storefront_id': storefrontId,
        'job_role_code': jobRoleCode,
        'pay_code': payCode,
        'hours': hundredthsToJson(hoursHundredths),
        'rate': rateE4 == null ? null : e4ToJson(rateE4!),
        'amount': centsToJson(amountCents),
      };

  @override
  String toString() => 'PayLine($workerId ${_dateStr(workDate)} $payCode ${formatHundredths(hoursHundredths)}h '
      '@${rateE4 == null ? '-' : formatE4(rateE4!)} = ${formatCents(amountCents)})';
}

class TipPool {
  const TipPool({
    required this.id,
    required this.venueId,
    required this.eventId,
    required this.amountCents,
    this.storefrontId,
    this.source = 'manual',
    this.method = 'hours',
    this.rolePointsThousandths = const {},
    this.status = 'draft',
    this.note = '',
    this.enteredBy,
    this.createdAt,
  });

  final String id;
  final String venueId;
  final String eventId;

  /// Null for an event-wide pool.
  final String? storefrontId;
  final int amountCents;

  /// manual, import, declared.
  final String source;

  /// hours, role_points, equal.
  final String method;

  /// For role_points: points per role in thousandths (1.0 -> 1000). Roles not listed
  /// are not in the pool.
  final Map<String, int> rolePointsThousandths;

  /// draft, final.
  final String status;
  final String note;
  final String? enteredBy;
  final DateTime? createdAt;

  factory TipPool.fromJson(Map<String, dynamic> j) => TipPool(
        id: j['id'] as String,
        venueId: j['venue_id'] as String,
        eventId: j['event_id'] as String,
        storefrontId: j['storefront_id'] as String?,
        amountCents: parseCents(j['amount']),
        source: (j['source'] as String?) ?? 'manual',
        method: (j['method'] as String?) ?? 'hours',
        rolePointsThousandths: {
          for (final e in ((j['role_points'] as Map?) ?? const {}).entries) e.key as String: parseScaled(e.value, 3),
        },
        status: (j['status'] as String?) ?? 'draft',
        note: (j['note'] as String?) ?? '',
        enteredBy: j['entered_by'] as String?,
        createdAt: _instant(j['created_at']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'venue_id': venueId,
        'event_id': eventId,
        'storefront_id': storefrontId,
        'amount': centsToJson(amountCents),
        'source': source,
        'method': method,
        'role_points': {for (final e in rolePointsThousandths.entries) e.key: thousandthsToJson(e.value)},
        'status': status,
        'note': note,
        if (enteredBy != null) 'entered_by': enteredBy,
        if (createdAt != null) 'created_at': _iso(createdAt),
      };
}

class TipAllocation {
  const TipAllocation({
    required this.poolId,
    required this.venueId,
    required this.workerId,
    required this.amountCents,
    this.hoursHundredths = 0,
    this.pointsThousandths = 0,
  });

  final String poolId;
  final String venueId;
  final String workerId;
  final int hoursHundredths;

  /// role_points: the role's points; equal: 1.000; hours: 0.
  final int pointsThousandths;
  final int amountCents;

  factory TipAllocation.fromJson(Map<String, dynamic> j) => TipAllocation(
        poolId: j['pool_id'] as String,
        venueId: j['venue_id'] as String,
        workerId: j['worker_id'] as String,
        hoursHundredths: j['hours'] == null ? 0 : parseScaled(j['hours'], 2),
        pointsThousandths: j['points'] == null ? 0 : parseScaled(j['points'], 3),
        amountCents: parseCents(j['amount']),
      );

  Map<String, dynamic> toJson() => {
        'pool_id': poolId,
        'venue_id': venueId,
        'worker_id': workerId,
        'hours': hundredthsToJson(hoursHundredths),
        'points': thousandthsToJson(pointsThousandths),
        'amount': centsToJson(amountCents),
      };
}

class AgencyBillRate {
  const AgencyBillRate({
    required this.id,
    required this.venueId,
    required this.agencyId,
    required this.jobRoleCode,
    required this.billRateCents,
    required this.effectiveFrom,
    this.overtimeBillRateCents,
    this.effectiveTo,
  });

  final String id;
  final String venueId;
  final String agencyId;
  final String jobRoleCode;
  final int billRateCents;

  /// For a temp's hours over 40 in a workweek. Null = same as [billRateCents].
  final int? overtimeBillRateCents;
  final DateTime effectiveFrom;
  final DateTime? effectiveTo;

  bool isActiveOn(DateTime date) => isEffectiveOn(date, effectiveFrom, effectiveTo);

  factory AgencyBillRate.fromJson(Map<String, dynamic> j) => AgencyBillRate(
        id: j['id'] as String,
        venueId: j['venue_id'] as String,
        agencyId: j['agency_id'] as String,
        jobRoleCode: j['job_role_code'] as String,
        billRateCents: parseCents(j['bill_rate']),
        overtimeBillRateCents: parseScaledOrNull(j['overtime_bill_rate'], 2),
        effectiveFrom: _date(j['effective_from']),
        effectiveTo: _dateOrNull(j['effective_to']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'venue_id': venueId,
        'agency_id': agencyId,
        'job_role_code': jobRoleCode,
        'bill_rate': centsToJson(billRateCents),
        'overtime_bill_rate': overtimeBillRateCents == null ? null : centsToJson(overtimeBillRateCents!),
        'effective_from': _dateStr(effectiveFrom),
        'effective_to': _dateStr(effectiveTo),
      };
}

class NpoAgreement {
  const NpoAgreement({
    required this.id,
    required this.venueId,
    required this.hourlyRateCents,
    required this.effectiveFrom,
    this.npoGroupId,
    this.minHeadcount = 0,
    this.shortfallDeductionCents = 0,
    this.noShowDeductionCents = 0,
    this.effectiveTo,
  });

  final String id;
  final String venueId;

  /// Null = the venue's standard agreement for every group.
  final String? npoGroupId;
  final int hourlyRateCents;
  final int minHeadcount;
  final int shortfallDeductionCents;
  final int noShowDeductionCents;
  final DateTime effectiveFrom;
  final DateTime? effectiveTo;

  bool isActiveOn(DateTime date) => isEffectiveOn(date, effectiveFrom, effectiveTo);

  factory NpoAgreement.fromJson(Map<String, dynamic> j) => NpoAgreement(
        id: j['id'] as String,
        venueId: j['venue_id'] as String,
        npoGroupId: j['npo_group_id'] as String?,
        hourlyRateCents: parseCents(j['hourly_rate']),
        minHeadcount: (j['min_headcount'] as num?)?.toInt() ?? 0,
        shortfallDeductionCents: j['shortfall_deduction'] == null ? 0 : parseCents(j['shortfall_deduction']),
        noShowDeductionCents: j['no_show_deduction'] == null ? 0 : parseCents(j['no_show_deduction']),
        effectiveFrom: _date(j['effective_from']),
        effectiveTo: _dateOrNull(j['effective_to']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'venue_id': venueId,
        'npo_group_id': npoGroupId,
        'hourly_rate': centsToJson(hourlyRateCents),
        'min_headcount': minHeadcount,
        'shortfall_deduction': centsToJson(shortfallDeductionCents),
        'no_show_deduction': centsToJson(noShowDeductionCents),
        'effective_from': _dateStr(effectiveFrom),
        'effective_to': _dateStr(effectiveTo),
      };
}

/// One member's line in [NpoPayout.detail].
class NpoPayoutMember {
  const NpoPayoutMember({required this.workerId, required this.minutes, this.name = '', this.status = 'worked'});

  final String workerId;
  final String name;
  final int minutes;

  /// worked, no_show, released, open_punch, not_worked.
  final String status;

  int get hoursHundredths => minutesToHundredths(minutes);

  factory NpoPayoutMember.fromJson(Map<String, dynamic> j) => NpoPayoutMember(
        workerId: j['worker_id'] as String,
        name: (j['name'] as String?) ?? '',
        // Stored detail has 2-decimal hours only; minutes are recovered to the nearest minute.
        minutes: j['minutes'] != null
            ? (j['minutes'] as num).toInt()
            : divRoundHalfUp(parseScaled(j['hours'] ?? 0, 2) * 60, 100),
        status: (j['status'] as String?) ?? 'worked',
      );

  Map<String, dynamic> toJson() => {
        'worker_id': workerId,
        'name': name,
        'hours': hundredthsToJson(hoursHundredths),
        'minutes': minutes,
        'status': status,
      };
}

class NpoPayout {
  const NpoPayout({
    required this.eventId,
    required this.npoGroupId,
    this.id,
    this.venueId,
    this.membersScheduled = 0,
    this.membersWorked = 0,
    this.noShows = 0,
    this.hoursHundredths = 0,
    this.hourlyRateCents = 0,
    this.grossCents = 0,
    this.deductionsCents = 0,
    this.adjustmentCents = 0,
    this.adjustmentReason = '',
    this.totalCents = 0,
    this.status = 'pending',
    this.approvedBy,
    this.approvedAt,
    this.paidAt,
    this.paymentReference = '',
    this.detail = const [],
    this.minutes,
  });

  final String? id;
  final String? venueId;
  final String eventId;
  final String npoGroupId;
  final int membersScheduled;
  final int membersWorked;
  final int noShows;
  final int hoursHundredths;
  final int hourlyRateCents;
  final int grossCents;
  final int deductionsCents;

  /// Signed manual adjustment.
  final int adjustmentCents;
  final String adjustmentReason;
  final int totalCents;

  /// pending, approved, paid.
  final String status;
  final String? approvedBy;
  final DateTime? approvedAt;
  final DateTime? paidAt;
  final String paymentReference;
  final List<NpoPayoutMember> detail;

  /// Exact total minutes behind [hoursHundredths], when calculated here (not stored).
  final int? minutes;

  factory NpoPayout.fromJson(Map<String, dynamic> j) => NpoPayout(
        id: j['id'] as String?,
        venueId: j['venue_id'] as String?,
        eventId: j['event_id'] as String,
        npoGroupId: j['npo_group_id'] as String,
        membersScheduled: (j['members_scheduled'] as num?)?.toInt() ?? 0,
        membersWorked: (j['members_worked'] as num?)?.toInt() ?? 0,
        noShows: (j['no_shows'] as num?)?.toInt() ?? 0,
        hoursHundredths: j['hours'] == null ? 0 : parseScaled(j['hours'], 2),
        hourlyRateCents: j['hourly_rate'] == null ? 0 : parseCents(j['hourly_rate']),
        grossCents: j['gross'] == null ? 0 : parseCents(j['gross']),
        deductionsCents: j['deductions'] == null ? 0 : parseCents(j['deductions']),
        adjustmentCents: j['adjustment'] == null ? 0 : parseCents(j['adjustment']),
        adjustmentReason: (j['adjustment_reason'] as String?) ?? '',
        totalCents: j['total'] == null ? 0 : parseCents(j['total']),
        status: (j['status'] as String?) ?? 'pending',
        approvedBy: j['approved_by'] as String?,
        approvedAt: _instant(j['approved_at']),
        paidAt: _instant(j['paid_at']),
        paymentReference: (j['payment_reference'] as String?) ?? '',
        detail: [
          for (final m in (j['detail'] as List?) ?? const [])
            NpoPayoutMember.fromJson((m as Map).cast<String, dynamic>()),
        ],
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        if (venueId != null) 'venue_id': venueId,
        'event_id': eventId,
        'npo_group_id': npoGroupId,
        'members_scheduled': membersScheduled,
        'members_worked': membersWorked,
        'no_shows': noShows,
        'hours': hundredthsToJson(hoursHundredths),
        'hourly_rate': centsToJson(hourlyRateCents),
        'gross': centsToJson(grossCents),
        'deductions': centsToJson(deductionsCents),
        'adjustment': centsToJson(adjustmentCents),
        'adjustment_reason': adjustmentReason,
        'total': centsToJson(totalCents),
        'status': status,
        'approved_by': approvedBy,
        'approved_at': _iso(approvedAt),
        'paid_at': _iso(paidAt),
        'payment_reference': paymentReference,
        'detail': [for (final m in detail) m.toJson()],
      };
}
