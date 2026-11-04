/// Venue-local calendar helpers. Instants are UTC; calendar dates are
/// `DateTime.utc(y, m, d)` values with no time of day.
library;

import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

bool _tzLoaded = false;

/// The IANA zone for [timeZone], loading the zone database on first use.
tz.Location venueLocation(String timeZone) {
  if (!_tzLoaded) {
    tzdata.initializeTimeZones();
    _tzLoaded = true;
  }
  return tz.getLocation(timeZone);
}

DateTime _asUtc(tz.TZDateTime t) => DateTime.fromMicrosecondsSinceEpoch(t.microsecondsSinceEpoch, isUtc: true);

/// The venue-local calendar date of [instant].
DateTime localDateOf(DateTime instant, String timeZone) {
  final t = tz.TZDateTime.from(instant.toUtc(), venueLocation(timeZone));
  return DateTime.utc(t.year, t.month, t.day);
}

/// The UTC instant of a venue-local wall-clock time.
DateTime localToUtc(String timeZone, int year, int month, int day, [int hour = 0, int minute = 0]) {
  final n = DateTime.utc(year, month, day, hour, minute);
  return _asUtc(tz.TZDateTime(venueLocation(timeZone), n.year, n.month, n.day, n.hour, n.minute));
}

/// The UTC instant of local midnight at the start of [localDate].
DateTime startOfLocalDay(DateTime localDate, String timeZone) =>
    localToUtc(timeZone, localDate.year, localDate.month, localDate.day);

/// [date] plus [days] calendar days (date only).
DateTime addCalendarDays(DateTime date, int days) => DateTime.utc(date.year, date.month, date.day + days);

/// [t] in UTC with seconds and smaller dropped.
DateTime truncateToMinute(DateTime t) {
  final u = t.toUtc();
  return DateTime.utc(u.year, u.month, u.day, u.hour, u.minute);
}

/// Venue-local clock time of [instant] as 'HH:mm'.
String formatLocalTime(DateTime instant, String timeZone) {
  final t = tz.TZDateTime.from(instant.toUtc(), venueLocation(timeZone));
  return '${_two(t.hour)}:${_two(t.minute)}';
}

/// A calendar date as 'yyyy-MM-dd'.
String formatDate(DateTime date) => '${date.year.toString().padLeft(4, '0')}-${_two(date.month)}-${_two(date.day)}';

String _two(int v) => v.toString().padLeft(2, '0');

/// Minutes as '3h', '45m' or '3h 30m'.
String formatMinutes(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}

/// Hours from settings as whole minutes (rounded).
int hoursToMinutes(double hours) => (hours * 60).round();
