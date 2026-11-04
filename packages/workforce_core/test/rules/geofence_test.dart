import 'package:test/test.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  const lat = 32.7473;
  const lng = -97.0945;
  const fence = GeofenceRules(enabled: true, latitude: lat, longitude: lng, radiusMeters: 300);
  const metersPerDegreeLat = 111194.93; // earthRadiusMeters * pi / 180

  /// A point [meters] due north of the center.
  double north(double meters) => lat + meters / metersPerDegreeLat;

  group('distance', () {
    test('one degree of latitude', () {
      expect(distanceMeters(0, 0, 1, 0), closeTo(111195, 1));
    });

    test('same point is zero', () {
      expect(distanceMeters(lat, lng, lat, lng), 0);
    });

    test('north offsets', () {
      expect(distanceMeters(lat, lng, north(250), lng), closeTo(250, 0.5));
    });

    test('longitude shrinks with latitude', () {
      // At about 32.75 N, one degree of longitude is about cos(lat) * 111 km.
      expect(distanceMeters(lat, 0, lat, 1), closeTo(93540, 200));
    });
  });

  group('isWithinGeofence', () {
    test('inside and outside', () {
      expect(isWithinGeofence(fence, north(250), lng), isTrue);
      expect(isWithinGeofence(fence, north(299), lng), isTrue);
      expect(isWithinGeofence(fence, north(301), lng), isFalse);
      expect(isWithinGeofence(fence, north(450), lng), isFalse);
    });

    test('accuracy slack counts in the person\'s favor', () {
      expect(isWithinGeofence(fence, north(350), lng, accuracyMeters: 60), isTrue);
      expect(isWithinGeofence(fence, north(350), lng, accuracyMeters: 40), isFalse);
    });

    test('slack is capped at 100 m', () {
      expect(isWithinGeofence(fence, north(390), lng, accuracyMeters: 500), isTrue);
      expect(isWithinGeofence(fence, north(420), lng, accuracyMeters: 500), isFalse);
    });

    test('bad accuracy values give no slack', () {
      expect(isWithinGeofence(fence, north(350), lng, accuracyMeters: -50), isFalse);
      expect(isWithinGeofence(fence, north(350), lng, accuracyMeters: double.nan), isFalse);
    });

    test('disabled always passes, even with no location', () {
      const off = GeofenceRules();
      expect(isWithinGeofence(off, null, null), isTrue);
      expect(isWithinGeofence(off, 0, 0), isTrue);
    });

    test('enabled with no location fails', () {
      expect(isWithinGeofence(fence, null, null), isFalse);
      expect(isWithinGeofence(fence, lat, null), isFalse);
    });

    test('enabled with no center set fails', () {
      const noCenter = GeofenceRules(enabled: true);
      expect(isWithinGeofence(noCenter, lat, lng), isFalse);
    });
  });
}
