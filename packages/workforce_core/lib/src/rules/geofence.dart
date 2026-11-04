/// Distance and geofence checks for punches.
library;

import 'dart:math' as math;

import 'venue_rules.dart';

/// Mean Earth radius in meters.
const double earthRadiusMeters = 6371008.8;

/// Most GPS accuracy slack allowed, in meters.
const double maxAccuracySlackMeters = 100;

/// Great-circle (haversine) distance in meters.
double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * earthRadiusMeters * math.asin(math.min(1, math.sqrt(a)));
}

/// Whether a location is inside the geofence.
///
/// Disabled: always true. Enabled with no device location, or with no center set in
/// the rules: false. Reported accuracy counts in the person's favor, capped at
/// [maxAccuracySlackMeters]: inside when distance minus accuracy is within the radius.
bool isWithinGeofence(GeofenceRules rules, double? latitude, double? longitude, {double? accuracyMeters}) {
  if (!rules.enabled) return true;
  final cLat = rules.latitude;
  final cLng = rules.longitude;
  if (latitude == null || longitude == null || cLat == null || cLng == null) return false;
  final acc = accuracyMeters;
  final slack = (acc == null || acc.isNaN || acc <= 0) ? 0.0 : math.min(acc, maxAccuracySlackMeters);
  return distanceMeters(cLat, cLng, latitude, longitude) - slack <= rules.radiusMeters;
}
