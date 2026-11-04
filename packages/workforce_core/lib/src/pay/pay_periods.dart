/// Pay period calendar.
///
/// weekly / biweekly: 7- or 14-day periods repeating forward and backward from
/// PayPeriodRules.anchorDate (the first day of any one period).
/// semimonthly: the 1st to the 15th, and the 16th to the last day of the month (the
/// anchor is not used).
/// monthly: the whole calendar month (allowed for calculation, but see
/// [payPeriodComplianceNotes]: not for non-exempt staff in Texas).
/// Payday = last day + PayRules.paydayDaysAfterEnd.
///
/// Dates are calendar dates (`DateTime.utc(y, m, d)`), matching local_time.dart.
library;

import '../rules/local_time.dart';
import '../rules/venue_rules.dart';
import 'pay_models.dart';
import 'pay_rules.dart';

const payPeriodFrequencies = {'weekly', 'biweekly', 'semimonthly', 'monthly'};

DateTime _d(DateTime v) => DateTime.utc(v.year, v.month, v.day);

int _daysBetween(DateTime a, DateTime b) => _d(b).difference(_d(a)).inDays;

DateTime _lastOfMonth(int y, int m) => DateTime.utc(y, m + 1, 0);

/// The pay period containing [date].
PayPeriod periodContaining(
  DateTime date, {
  required PayPeriodRules rules,
  required int paydayDaysAfterEnd,
  String? venueId,
}) {
  final day = _d(date);
  DateTime start;
  DateTime end;
  switch (rules.frequency) {
    case 'weekly':
    case 'biweekly':
      final len = rules.frequency == 'weekly' ? 7 : 14;
      final anchor = _d(DateTime.parse(rules.anchorDate));
      final offset = _daysBetween(anchor, day);
      final k = (offset / len).floor();
      start = addCalendarDays(anchor, k * len);
      end = addCalendarDays(start, len - 1);
    case 'semimonthly':
      if (day.day <= 15) {
        start = DateTime.utc(day.year, day.month, 1);
        end = DateTime.utc(day.year, day.month, 15);
      } else {
        start = DateTime.utc(day.year, day.month, 16);
        end = _lastOfMonth(day.year, day.month);
      }
    case 'monthly':
      start = DateTime.utc(day.year, day.month, 1);
      end = _lastOfMonth(day.year, day.month);
    default:
      throw ArgumentError.value(rules.frequency, 'frequency', 'must be one of $payPeriodFrequencies');
  }
  return PayPeriod(
    venueId: venueId,
    startsOn: start,
    endsOn: end,
    payDate: addCalendarDays(end, paydayDaysAfterEnd),
  );
}

/// Every pay period that overlaps [from]..[to] (inclusive), in order.
List<PayPeriod> generatePayPeriods({
  required PayPeriodRules rules,
  required int paydayDaysAfterEnd,
  required DateTime from,
  required DateTime to,
  String? venueId,
}) {
  if (_d(to).isBefore(_d(from))) throw ArgumentError('to is before from');
  final out = <PayPeriod>[];
  var cursor = _d(from);
  while (!cursor.isAfter(_d(to))) {
    final p = periodContaining(cursor, rules: rules, paydayDaysAfterEnd: paydayDaysAfterEnd, venueId: venueId);
    out.add(p);
    cursor = addCalendarDays(p.endsOn, 1);
  }
  return out;
}

/// Convenience: periods from venue settings.
List<PayPeriod> generatePayPeriodsFor({
  required VenueRules venueRules,
  required PayRules payRules,
  required DateTime from,
  required DateTime to,
  String? venueId,
}) =>
    generatePayPeriods(
      rules: venueRules.payPeriod,
      paydayDaysAfterEnd: payRules.paydayDaysAfterEnd,
      from: from,
      to: to,
      venueId: venueId,
    );

enum ComplianceSeverity { error, warning, info }

class ComplianceNote {
  const ComplianceNote(this.severity, this.code, this.message);

  final ComplianceSeverity severity;
  final String code;
  final String message;

  @override
  String toString() => 'ComplianceNote(${severity.name}, $code)';
}

/// Checks a pay schedule against the Texas Payday Law and the workweek.
/// CONFIRM the result with HR or an employment attorney; this is a checklist, not advice.
List<ComplianceNote> payPeriodComplianceNotes({
  required PayPeriodRules rules,
  required PayRules payRules,
  required OvertimeRules overtime,
}) {
  final notes = <ComplianceNote>[];
  if (!payPeriodFrequencies.contains(rules.frequency)) {
    notes.add(ComplianceNote(ComplianceSeverity.error, 'unknown_frequency',
        'Unknown pay frequency "${rules.frequency}". Use weekly, biweekly, or semimonthly.'));
    return notes;
  }
  if (rules.frequency == 'monthly') {
    notes.add(const ComplianceNote(
        ComplianceSeverity.warning,
        'texas_payday_law_monthly',
        'Texas Payday Law (Tex. Lab. Code 61.011) requires paying non-exempt employees at least twice a month. '
            'Monthly pay is allowed only for exempt employees; hourly concessions staff need weekly, biweekly, '
            'or semimonthly pay.'));
  }
  if (payRules.paydayDaysAfterEnd < 0) {
    notes.add(const ComplianceNote(
        ComplianceSeverity.error, 'payday_before_period_end', 'Payday cannot be before the end of the pay period.'));
  }
  if (rules.frequency == 'weekly' || rules.frequency == 'biweekly') {
    final anchor = DateTime.parse(rules.anchorDate);
    if (DateTime.utc(anchor.year, anchor.month, anchor.day).weekday != overtime.workweekStartDay) {
      notes.add(const ComplianceNote(
          ComplianceSeverity.warning,
          'period_not_aligned_to_workweek',
          'The pay period anchor is not on the first day of the workweek, so workweeks straddle pay periods. '
              'Overtime is still figured per workweek, but each week is split across two payrolls.'));
    }
  } else {
    notes.add(ComplianceNote(
        ComplianceSeverity.info,
        'workweeks_straddle_periods',
        '${rules.frequency == 'semimonthly' ? 'Semimonthly' : 'Monthly'} periods do not line up with workweeks. '
            'Overtime is figured per workweek, so a week that crosses the period end is paid across two payrolls. '
            'The database function ensure_pay_periods supports only weekly and biweekly so far.'));
  }
  return notes;
}
