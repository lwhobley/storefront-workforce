/// Child labor checks for one planned or worked shift.
///
/// Definitions (all on venue-local calendar dates):
/// - School day: Monday to Friday inside the school year (`schoolYearStart` through
///   `schoolYearEnd`, inclusive, wrapping across New Year). Holidays are not known.
/// - School week: a workweek with at least one school day.
/// - Summer (for `summerLatestEnd`): June 1 through Labor Day (first Monday of
///   September), inclusive.
/// - Daily hours are counted per local calendar day the shift touches; weekly hours
///   per workweek it touches. Other intervals are merged with the shift, so time
///   listed twice is counted once.
/// - Start and end limits are measured against the local date the shift starts on,
///   so a shift ending 00:30 the next day is past a 19:00 or 21:00 limit.
library;

import '../model/entities.dart';
import 'local_time.dart';
import 'overtime.dart';
import 'venue_rules.dart';
import 'work_interval.dart';

enum MinorViolationCode {
  underMinimumAge('under_minimum_age'),
  prohibitedRole('prohibited_role'),
  dailyHours('daily_hours'),
  weeklyHours('weekly_hours'),
  tooEarly('too_early'),
  tooLate('too_late');

  const MinorViolationCode(this.code);
  final String code;
}

class MinorViolation {
  const MinorViolation({required this.code, required this.message, this.date});

  final MinorViolationCode code;

  /// Plain-English explanation for managers.
  final String message;

  /// The local date (day or first day of the workweek) the violation is about.
  final DateTime? date;

  @override
  String toString() => 'MinorViolation(${code.code}: $message)';
}

class MinorCheckResult {
  const MinorCheckResult({
    required this.age,
    required this.isMinor,
    this.band,
    this.violations = const [],
  });

  final int? age;

  /// Age known and under the adult age.
  final bool isMinor;

  /// The age band whose limits were applied, if any.
  final MinorBand? band;
  final List<MinorViolation> violations;

  /// No birth date on file, so no minor checks could run. Informational only.
  bool get ageUnknown => age == null;

  bool get ok => violations.isEmpty;
}

/// Age on the venue-local date of [instant].
int? workerAgeAt(Worker worker, DateTime instant, String timeZone) => worker.ageOn(localDateOf(instant, timeZone));

/// Checks one shift from [start] to [end] for a worker of [age] (age on the shift's
/// local start date; see [workerAgeAt]). [otherIntervals] are the person's other
/// worked or planned time, used for daily and weekly totals; any outside the days
/// and workweeks this shift touches are ignored.
MinorCheckResult checkMinorShift({
  required int? age,
  required MinorRules rules,
  required String jobRoleCode,
  required DateTime start,
  required DateTime end,
  required String timeZone,
  List<WorkInterval> otherIntervals = const [],
  int workweekStartDay = DateTime.monday,
}) {
  if (age == null) return const MinorCheckResult(age: null, isMinor: false);
  if (age >= rules.adultAge) return MinorCheckResult(age: age, isMinor: false);
  if (age < rules.minimumWorkingAge) {
    return MinorCheckResult(age: age, isMinor: true, violations: [
      MinorViolation(
        code: MinorViolationCode.underMinimumAge,
        message: 'Age $age is under the minimum working age of ${rules.minimumWorkingAge}.',
      ),
    ]);
  }
  final band = rules.bandFor(age);
  if (band == null) return MinorCheckResult(age: age, isMinor: true);

  final who = band.minAge == band.maxAge ? 'Age ${band.minAge}' : 'Ages ${band.minAge}-${band.maxAge}';
  final violations = <MinorViolation>[];

  if (band.prohibitedJobRoles.contains(jobRoleCode)) {
    violations.add(MinorViolation(
      code: MinorViolationCode.prohibitedRole,
      message: '$who may not work as $jobRoleCode.',
    ));
  }

  final all = mergeIntervals([WorkInterval(start, end), ...otherIntervals]);
  final s = truncateToMinute(start);
  final e = truncateToMinute(end);
  final startDate = localDateOf(s, timeZone);

  if (e.isAfter(s)) {
    // Daily hours, for each local day the shift touches.
    final lastDate = localDateOf(e.subtract(const Duration(minutes: 1)), timeZone);
    for (var d = startDate; !d.isAfter(lastDate); d = addCalendarDays(d, 1)) {
      final school = isSchoolDay(d, rules);
      final max = school ? band.schoolDayMaxHours : band.nonSchoolDayMaxHours;
      if (max == null) continue;
      final worked = minutesWithin(all, startOfLocalDay(d, timeZone), startOfLocalDay(addCalendarDays(d, 1), timeZone));
      if (worked > hoursToMinutes(max)) {
        violations.add(MinorViolation(
          code: MinorViolationCode.dailyHours,
          date: d,
          message: '$who may work at most ${formatMinutes(hoursToMinutes(max))} on a '
              '${school ? 'school day' : 'non-school day'}; ${_day(d)} totals ${formatMinutes(worked)}.',
        ));
      }
    }

    // Weekly hours, for each workweek the shift touches.
    var ws = workweekStart(s, timeZone, workweekStartDay);
    while (ws.isBefore(e)) {
      final first = localDateOf(ws, timeZone);
      final next = startOfLocalDay(addCalendarDays(first, 7), timeZone);
      final school = isSchoolWeek(first, rules);
      final max = school ? band.schoolWeekMaxHours : band.nonSchoolWeekMaxHours;
      if (max != null) {
        final worked = minutesWithin(all, ws, next);
        if (worked > hoursToMinutes(max)) {
          violations.add(MinorViolation(
            code: MinorViolationCode.weeklyHours,
            date: first,
            message: '$who may work at most ${formatMinutes(hoursToMinutes(max))} in a '
                '${school ? 'school week' : 'non-school week'}; the week of ${_day(first)} '
                'totals ${formatMinutes(worked)}.',
          ));
        }
      }
      ws = next;
    }
  }

  // Time of day, against the shift's local start date.
  final earliest = band.earliestStart;
  if (earliest != null) {
    final limit = _clockOn(startDate, earliest, timeZone);
    if (s.isBefore(limit)) {
      violations.add(MinorViolation(
        code: MinorViolationCode.tooEarly,
        date: startDate,
        message: '$who may not start before $earliest; this shift starts at ${formatLocalTime(s, timeZone)} '
            'on ${_day(startDate)}.',
      ));
    }
  }
  final summer = isSummer(startDate);
  final latest = (summer ? band.summerLatestEnd : null) ?? band.latestEnd;
  if (latest != null && e.isAfter(s)) {
    final limit = _clockOn(startDate, latest, timeZone);
    if (e.isAfter(limit)) {
      final endDate = localDateOf(e, timeZone);
      final nextDay = endDate.isAfter(startDate) ? ' the next day' : '';
      violations.add(MinorViolation(
        code: MinorViolationCode.tooLate,
        date: startDate,
        message: '$who must finish by $latest${summer && band.summerLatestEnd != null ? ' (summer)' : ''} '
            'on ${_day(startDate)}; this shift ends at ${formatLocalTime(e, timeZone)}$nextDay.',
      ));
    }
  }

  return MinorCheckResult(age: age, isMinor: true, band: band, violations: List.unmodifiable(violations));
}

/// Monday to Friday inside the school year.
bool isSchoolDay(DateTime localDate, MinorRules rules) {
  if (localDate.weekday > DateTime.friday) return false;
  final d = localDate.month * 100 + localDate.day;
  final from = _monthDay(rules.schoolYearStart);
  final to = _monthDay(rules.schoolYearEnd);
  return from <= to ? (d >= from && d <= to) : (d >= from || d <= to);
}

/// Whether any of the seven days starting at [firstDate] is a school day.
bool isSchoolWeek(DateTime firstDate, MinorRules rules) {
  for (var i = 0; i < 7; i++) {
    if (isSchoolDay(addCalendarDays(firstDate, i), rules)) return true;
  }
  return false;
}

/// June 1 through Labor Day (first Monday of September), inclusive.
bool isSummer(DateTime localDate) {
  final y = localDate.year;
  final d = DateTime.utc(y, localDate.month, localDate.day);
  return !d.isBefore(DateTime.utc(y, 6, 1)) && !d.isAfter(laborDay(y));
}

/// First Monday of September.
DateTime laborDay(int year) {
  final sept1 = DateTime.utc(year, 9, 1);
  return addCalendarDays(sept1, (DateTime.monday - sept1.weekday) % 7);
}

int _monthDay(String mmdd) {
  final parts = mmdd.split('-');
  if (parts.length != 2) throw FormatException('Expected MM-dd', mmdd);
  return int.parse(parts[0]) * 100 + int.parse(parts[1]);
}

DateTime _clockOn(DateTime date, String hhmm, String timeZone) {
  final parts = hhmm.split(':');
  if (parts.length != 2) throw FormatException('Expected HH:mm', hhmm);
  return localToUtc(timeZone, date.year, date.month, date.day, int.parse(parts[0]), int.parse(parts[1]));
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _day(DateTime date) => '${_weekdays[date.weekday - 1]} ${formatDate(date)}';
