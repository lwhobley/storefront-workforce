/// A venue's labor rules. Stored per venue as JSON (`venue_rule_versions.rules`) so another
/// state or policy is a settings change, not a code change.
///
/// [VenueRules.texasDefaults] is the starting point for the first venue. Items marked
/// CONFIRM in the comments should be checked with HR or an employment attorney.
library;

class AttendanceRules {
  const AttendanceRules({
    this.lateGraceMinutes = 5,
    this.noShowAfterMinutes = 60,
    this.earlyClockInMinutes = 30,
  });

  /// Minutes after call time before a clock-in counts as late.
  final int lateGraceMinutes;

  /// Minutes after call time with no clock-in before the person counts as a no-show.
  final int noShowAfterMinutes;

  /// How early before call time someone may clock in.
  final int earlyClockInMinutes;

  factory AttendanceRules.fromJson(Map<String, dynamic>? j) {
    const d = AttendanceRules();
    if (j == null) return d;
    return AttendanceRules(
      lateGraceMinutes: (j['late_grace_minutes'] as num?)?.toInt() ?? d.lateGraceMinutes,
      noShowAfterMinutes: (j['no_show_after_minutes'] as num?)?.toInt() ?? d.noShowAfterMinutes,
      earlyClockInMinutes: (j['early_clock_in_minutes'] as num?)?.toInt() ?? d.earlyClockInMinutes,
    );
  }

  Map<String, dynamic> toJson() => {
        'late_grace_minutes': lateGraceMinutes,
        'no_show_after_minutes': noShowAfterMinutes,
        'early_clock_in_minutes': earlyClockInMinutes,
      };
}

class OvertimeRules {
  const OvertimeRules({
    this.weeklyThresholdHours = 40,
    this.dailyThresholdHours,
    this.workweekStartDay = DateTime.monday,
    this.warnWithinHours = 4,
  });

  /// Federal FLSA: overtime after 40 hours in the workweek.
  final double weeklyThresholdHours;

  /// Daily overtime (some states, such as California). Null in Texas.
  final double? dailyThresholdHours;

  /// First day of the workweek, DateTime.monday (1) to DateTime.sunday (7), at midnight venue time.
  final int workweekStartDay;

  /// Flag people within this many hours of overtime on the live view.
  final double warnWithinHours;

  factory OvertimeRules.fromJson(Map<String, dynamic>? j) {
    const d = OvertimeRules();
    if (j == null) return d;
    return OvertimeRules(
      weeklyThresholdHours: (j['weekly_threshold_hours'] as num?)?.toDouble() ?? d.weeklyThresholdHours,
      dailyThresholdHours: (j['daily_threshold_hours'] as num?)?.toDouble(),
      workweekStartDay: (j['workweek_start_day'] as num?)?.toInt() ?? d.workweekStartDay,
      warnWithinHours: (j['warn_within_hours'] as num?)?.toDouble() ?? d.warnWithinHours,
    );
  }

  Map<String, dynamic> toJson() => {
        'weekly_threshold_hours': weeklyThresholdHours,
        'daily_threshold_hours': dailyThresholdHours,
        'workweek_start_day': workweekStartDay,
        'warn_within_hours': warnWithinHours,
      };
}

/// Who a break rule applies to.
enum BreakAudience {
  all('all'),
  adults('adults'),
  minors('minors');

  const BreakAudience(this.code);
  final String code;

  static BreakAudience fromCode(String? code) =>
      values.firstWhere((v) => v.code == code, orElse: () => BreakAudience.all);
}

/// "After [afterWorkedMinutes] of work, a [kind] break of at least [minimumMinutes] is due."
class BreakRule {
  const BreakRule({
    required this.id,
    required this.kind,
    required this.afterWorkedMinutes,
    required this.minimumMinutes,
    required this.paid,
    this.audience = BreakAudience.all,
  });

  final String id;

  /// 'meal' or 'rest'.
  final String kind;
  final int afterWorkedMinutes;
  final int minimumMinutes;
  final bool paid;
  final BreakAudience audience;

  factory BreakRule.fromJson(Map<String, dynamic> j) => BreakRule(
        id: j['id'] as String,
        kind: j['kind'] as String,
        afterWorkedMinutes: (j['after_worked_minutes'] as num).toInt(),
        minimumMinutes: (j['minimum_minutes'] as num).toInt(),
        paid: (j['paid'] as bool?) ?? false,
        audience: BreakAudience.fromCode(j['audience'] as String?),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'after_worked_minutes': afterWorkedMinutes,
        'minimum_minutes': minimumMinutes,
        'paid': paid,
        'audience': audience.code,
      };
}

class BreakRules {
  const BreakRules({
    this.rules = const [
      // Texas has no break requirement for adults; these are the venue's own policy.
      // CONFIRM: replace with your written break policy.
      BreakRule(id: 'rest_4h', kind: 'rest', afterWorkedMinutes: 240, minimumMinutes: 10, paid: true),
      BreakRule(id: 'meal_6h', kind: 'meal', afterWorkedMinutes: 360, minimumMinutes: 30, paid: false),
    ],
    this.reminderMinutesBefore = 15,
    this.paidBreakMaxMinutes = 20,
  });

  final List<BreakRule> rules;

  /// Remind the employee this many minutes before a break is due.
  final int reminderMinutesBefore;

  /// Federal rule: breaks of up to 20 minutes are paid time even if marked unpaid.
  final int paidBreakMaxMinutes;

  factory BreakRules.fromJson(Map<String, dynamic>? j) {
    const d = BreakRules();
    if (j == null) return d;
    return BreakRules(
      rules: j['rules'] == null
          ? d.rules
          : [for (final r in j['rules'] as List) BreakRule.fromJson((r as Map).cast<String, dynamic>())],
      reminderMinutesBefore: (j['reminder_minutes_before'] as num?)?.toInt() ?? d.reminderMinutesBefore,
      paidBreakMaxMinutes: (j['paid_break_max_minutes'] as num?)?.toInt() ?? d.paidBreakMaxMinutes,
    );
  }

  Map<String, dynamic> toJson() => {
        'rules': [for (final r in rules) r.toJson()],
        'reminder_minutes_before': reminderMinutesBefore,
        'paid_break_max_minutes': paidBreakMaxMinutes,
      };
}

/// Hour and time-of-day limits for one age band of minors.
class MinorBand {
  const MinorBand({
    required this.minAge,
    required this.maxAge,
    this.schoolDayMaxHours,
    this.nonSchoolDayMaxHours,
    this.schoolWeekMaxHours,
    this.nonSchoolWeekMaxHours,
    this.earliestStart,
    this.latestEnd,
    this.summerLatestEnd,
    this.prohibitedJobRoles = const [],
  });

  final int minAge;
  final int maxAge;
  final double? schoolDayMaxHours;
  final double? nonSchoolDayMaxHours;
  final double? schoolWeekMaxHours;
  final double? nonSchoolWeekMaxHours;

  /// Local clock times as 'HH:mm'. Null means no limit.
  final String? earliestStart;
  final String? latestEnd;

  /// Later end time allowed from June 1 through Labor Day.
  final String? summerLatestEnd;

  /// Job roles this band may not work (for example bartender).
  final List<String> prohibitedJobRoles;

  bool covers(int age) => age >= minAge && age <= maxAge;

  factory MinorBand.fromJson(Map<String, dynamic> j) => MinorBand(
        minAge: (j['min_age'] as num).toInt(),
        maxAge: (j['max_age'] as num).toInt(),
        schoolDayMaxHours: (j['school_day_max_hours'] as num?)?.toDouble(),
        nonSchoolDayMaxHours: (j['non_school_day_max_hours'] as num?)?.toDouble(),
        schoolWeekMaxHours: (j['school_week_max_hours'] as num?)?.toDouble(),
        nonSchoolWeekMaxHours: (j['non_school_week_max_hours'] as num?)?.toDouble(),
        earliestStart: j['earliest_start'] as String?,
        latestEnd: j['latest_end'] as String?,
        summerLatestEnd: j['summer_latest_end'] as String?,
        prohibitedJobRoles: [for (final r in (j['prohibited_job_roles'] as List?) ?? const []) r as String],
      );

  Map<String, dynamic> toJson() => {
        'min_age': minAge,
        'max_age': maxAge,
        'school_day_max_hours': schoolDayMaxHours,
        'non_school_day_max_hours': nonSchoolDayMaxHours,
        'school_week_max_hours': schoolWeekMaxHours,
        'non_school_week_max_hours': nonSchoolWeekMaxHours,
        'earliest_start': earliestStart,
        'latest_end': latestEnd,
        'summer_latest_end': summerLatestEnd,
        'prohibited_job_roles': prohibitedJobRoles,
      };
}

class MinorRules {
  const MinorRules({
    this.adultAge = 18,
    this.minimumWorkingAge = 14,
    this.bands = const [
      // Federal FLSA limits for 14 and 15, which are stricter than Texas Labor Code ch. 51.
      // CONFIRM with an employment attorney.
      MinorBand(
        minAge: 14,
        maxAge: 15,
        schoolDayMaxHours: 3,
        nonSchoolDayMaxHours: 8,
        schoolWeekMaxHours: 18,
        nonSchoolWeekMaxHours: 40,
        earliestStart: '07:00',
        latestEnd: '19:00',
        summerLatestEnd: '21:00',
        prohibitedJobRoles: ['bartender', 'cook'],
      ),
      // 16 and 17: no federal hour limits; hazardous-equipment limits still apply.
      MinorBand(minAge: 16, maxAge: 17, prohibitedJobRoles: ['bartender']),
    ],
    this.schoolYearStart = '08-15',
    this.schoolYearEnd = '05-31',
  });

  final int adultAge;
  final int minimumWorkingAge;
  final List<MinorBand> bands;

  /// School year as 'MM-dd'. Weekdays inside it are school days, unless the venue
  /// marks holidays separately (not yet supported).
  final String schoolYearStart;
  final String schoolYearEnd;

  MinorBand? bandFor(int age) {
    for (final b in bands) {
      if (b.covers(age)) return b;
    }
    return null;
  }

  factory MinorRules.fromJson(Map<String, dynamic>? j) {
    const d = MinorRules();
    if (j == null) return d;
    return MinorRules(
      adultAge: (j['adult_age'] as num?)?.toInt() ?? d.adultAge,
      minimumWorkingAge: (j['minimum_working_age'] as num?)?.toInt() ?? d.minimumWorkingAge,
      bands: j['bands'] == null
          ? d.bands
          : [for (final b in j['bands'] as List) MinorBand.fromJson((b as Map).cast<String, dynamic>())],
      schoolYearStart: (j['school_year_start'] as String?) ?? d.schoolYearStart,
      schoolYearEnd: (j['school_year_end'] as String?) ?? d.schoolYearEnd,
    );
  }

  Map<String, dynamic> toJson() => {
        'adult_age': adultAge,
        'minimum_working_age': minimumWorkingAge,
        'bands': [for (final b in bands) b.toJson()],
        'school_year_start': schoolYearStart,
        'school_year_end': schoolYearEnd,
      };
}

enum CertificationEnforcement {
  block('block'),
  warn('warn');

  const CertificationEnforcement(this.code);
  final String code;

  static CertificationEnforcement fromCode(String? code) =>
      values.firstWhere((v) => v.code == code, orElse: () => CertificationEnforcement.block);
}

class CertificationRules {
  const CertificationRules({this.enforcement = CertificationEnforcement.block, this.expiringSoonDays = 30});

  final CertificationEnforcement enforcement;
  final int expiringSoonDays;

  factory CertificationRules.fromJson(Map<String, dynamic>? j) {
    const d = CertificationRules();
    if (j == null) return d;
    return CertificationRules(
      enforcement: CertificationEnforcement.fromCode(j['enforcement'] as String?),
      expiringSoonDays: (j['expiring_soon_days'] as num?)?.toInt() ?? d.expiringSoonDays,
    );
  }

  Map<String, dynamic> toJson() => {'enforcement': enforcement.code, 'expiring_soon_days': expiringSoonDays};
}

class GeofenceRules {
  const GeofenceRules({this.enabled = false, this.latitude, this.longitude, this.radiusMeters = 300});

  final bool enabled;
  final double? latitude;
  final double? longitude;
  final double radiusMeters;

  factory GeofenceRules.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const GeofenceRules();
    return GeofenceRules(
      enabled: (j['enabled'] as bool?) ?? false,
      latitude: (j['latitude'] as num?)?.toDouble(),
      longitude: (j['longitude'] as num?)?.toDouble(),
      radiusMeters: (j['radius_meters'] as num?)?.toDouble() ?? 300,
    );
  }

  Map<String, dynamic> toJson() =>
      {'enabled': enabled, 'latitude': latitude, 'longitude': longitude, 'radius_meters': radiusMeters};
}

class ClockRules {
  const ClockRules({
    this.allowPhone = true,
    this.allowKiosk = true,
    this.requirePhoto = true,
    this.geofence = const GeofenceRules(),
  });

  final bool allowPhone;
  final bool allowKiosk;
  final bool requirePhoto;
  final GeofenceRules geofence;

  factory ClockRules.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const ClockRules();
    return ClockRules(
      allowPhone: (j['allow_phone'] as bool?) ?? true,
      allowKiosk: (j['allow_kiosk'] as bool?) ?? true,
      requirePhoto: (j['require_photo'] as bool?) ?? true,
      geofence: GeofenceRules.fromJson((j['geofence'] as Map?)?.cast<String, dynamic>()),
    );
  }

  Map<String, dynamic> toJson() => {
        'allow_phone': allowPhone,
        'allow_kiosk': allowKiosk,
        'require_photo': requirePhoto,
        'geofence': geofence.toJson(),
      };
}

class PayPeriodRules {
  const PayPeriodRules({this.frequency = 'biweekly', this.anchorDate = '2026-01-05'});

  /// weekly, biweekly, semimonthly. Texas Payday Law: non-exempt staff at least twice a month.
  final String frequency;

  /// First day of any one pay period, 'yyyy-MM-dd'. Periods repeat from here.
  final String anchorDate;

  factory PayPeriodRules.fromJson(Map<String, dynamic>? j) {
    const d = PayPeriodRules();
    if (j == null) return d;
    return PayPeriodRules(
      frequency: (j['frequency'] as String?) ?? d.frequency,
      anchorDate: (j['anchor_date'] as String?) ?? d.anchorDate,
    );
  }

  Map<String, dynamic> toJson() => {'frequency': frequency, 'anchor_date': anchorDate};
}

class EarlyReleaseRules {
  const EarlyReleaseRules({this.order = const ['volunteer', 'temp', 'npo', 'regular']});

  /// Suggested order for sending people home. 'volunteer' means anyone who asked to leave.
  /// Regular staff are ordered by most recent hire date first.
  final List<String> order;

  factory EarlyReleaseRules.fromJson(Map<String, dynamic>? j) {
    if (j == null || j['order'] == null) return const EarlyReleaseRules();
    return EarlyReleaseRules(order: [for (final o in j['order'] as List) o as String]);
  }

  Map<String, dynamic> toJson() => {'order': order};
}

class EventDefaults {
  const EventDefaults({this.doorsBeforeStartMinutes = 60, this.callBeforeDoorsMinutes = 90});

  final int doorsBeforeStartMinutes;
  final int callBeforeDoorsMinutes;

  factory EventDefaults.fromJson(Map<String, dynamic>? j) {
    const d = EventDefaults();
    if (j == null) return d;
    return EventDefaults(
      doorsBeforeStartMinutes: (j['doors_before_start_minutes'] as num?)?.toInt() ?? d.doorsBeforeStartMinutes,
      callBeforeDoorsMinutes: (j['call_before_doors_minutes'] as num?)?.toInt() ?? d.callBeforeDoorsMinutes,
    );
  }

  Map<String, dynamic> toJson() =>
      {'doors_before_start_minutes': doorsBeforeStartMinutes, 'call_before_doors_minutes': callBeforeDoorsMinutes};
}

class VenueRules {
  const VenueRules({
    this.attendance = const AttendanceRules(),
    this.overtime = const OvertimeRules(),
    this.breaks = const BreakRules(),
    this.minors = const MinorRules(),
    this.certifications = const CertificationRules(),
    this.clock = const ClockRules(),
    this.payPeriod = const PayPeriodRules(),
    this.earlyRelease = const EarlyReleaseRules(),
    this.eventDefaults = const EventDefaults(),
  });

  /// Starting rules for a Texas venue.
  static const texasDefaults = VenueRules();

  final AttendanceRules attendance;
  final OvertimeRules overtime;
  final BreakRules breaks;
  final MinorRules minors;
  final CertificationRules certifications;
  final ClockRules clock;
  final PayPeriodRules payPeriod;
  final EarlyReleaseRules earlyRelease;
  final EventDefaults eventDefaults;

  Map<String, dynamic>? _section(Map<String, dynamic> j, String key) => (j[key] as Map?)?.cast<String, dynamic>();

  factory VenueRules.fromJson(Map<String, dynamic>? j) {
    if (j == null) return texasDefaults;
    const r = VenueRules();
    return VenueRules(
      attendance: AttendanceRules.fromJson(r._section(j, 'attendance')),
      overtime: OvertimeRules.fromJson(r._section(j, 'overtime')),
      breaks: BreakRules.fromJson(r._section(j, 'breaks')),
      minors: MinorRules.fromJson(r._section(j, 'minors')),
      certifications: CertificationRules.fromJson(r._section(j, 'certifications')),
      clock: ClockRules.fromJson(r._section(j, 'clock')),
      payPeriod: PayPeriodRules.fromJson(r._section(j, 'pay_period')),
      earlyRelease: EarlyReleaseRules.fromJson(r._section(j, 'early_release')),
      eventDefaults: EventDefaults.fromJson(r._section(j, 'event_defaults')),
    );
  }

  Map<String, dynamic> toJson() => {
        'attendance': attendance.toJson(),
        'overtime': overtime.toJson(),
        'breaks': breaks.toJson(),
        'minors': minors.toJson(),
        'certifications': certifications.toJson(),
        'clock': clock.toJson(),
        'pay_period': payPeriod.toJson(),
        'early_release': earlyRelease.toJson(),
        'event_defaults': eventDefaults.toJson(),
      };
}
