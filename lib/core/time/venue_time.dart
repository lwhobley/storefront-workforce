import 'package:timezone/data/latest.dart' as time_zone_data;
import 'package:timezone/timezone.dart' as tz;

bool _initialized = false;

tz.Location _location(String name) {
  if (!_initialized) {
    time_zone_data.initializeTimeZones();
    _initialized = true;
  }
  return tz.getLocation(name);
}

/// Shows an instant in the venue's IANA time zone, regardless of device zone.
DateTime atVenue(DateTime instant, String timeZone) =>
    tz.TZDateTime.from(instant, _location(timeZone));

/// Interprets date-picker fields as a wall time at the venue and stores UTC.
/// Rejects a clock time skipped by a daylight-saving transition.
DateTime venueWallTimeUtc(DateTime wall, String timeZone) {
  final zoned = tz.TZDateTime(
    _location(timeZone), wall.year, wall.month, wall.day, wall.hour, wall.minute,
  );
  final roundTrip = tz.TZDateTime.from(zoned.toUtc(), _location(timeZone));
  if (roundTrip.year != wall.year || roundTrip.month != wall.month ||
      roundTrip.day != wall.day || roundTrip.hour != wall.hour ||
      roundTrip.minute != wall.minute) {
    throw ArgumentError('This local time does not exist in the venue time zone.');
  }
  return zoned.toUtc();
}

/// Venue-local calendar date of an instant, as a UTC midnight DateTime.
DateTime venueDate(DateTime instant, String timeZone) {
  final local = atVenue(instant, timeZone);
  return DateTime.utc(local.year, local.month, local.day);
}
