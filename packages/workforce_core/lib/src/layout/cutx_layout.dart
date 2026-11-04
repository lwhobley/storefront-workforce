/// The CUTX (Credit Union of Texas Event Center) floor plan, top-down, for the concourse
/// map. Outlines come from Premium Command (`premium_level_layout.dart`), which traced them
/// from the venue's labeled plan and seating chart (October 2026). The plan has no scale
/// bar, so the map is proportional, not measured.
///
/// Coordinates are normalized to the building footprint: x and y run 0..1 from the left and
/// top edges of the outer wall. The concourse is the walkway between the bowl (seating and
/// floor) and the outer wall, where the concession storefronts are.
library;

import 'dart:math';

typedef MapPoint = (double x, double y);

class MapSection {
  const MapSection(this.name, this.points);

  final String name;
  final List<MapPoint> points;

  MapPoint get center {
    var x = 0.0, y = 0.0;
    for (final p in points) {
      x += p.$1;
      y += p.$2;
    }
    return (x / points.length, y / points.length);
  }
}

/// A venue drawn from a real plan.
class VenueMapLayout {
  const VenueMapLayout({
    required this.id,
    required this.name,
    required this.aspectRatio,
    required this.bowl,
    required this.sections,
  });

  /// Stored in venue settings as `map.layout`.
  final String id;
  final String name;

  /// Width over height of the footprint.
  final double aspectRatio;

  /// The bowl's outer edge: seating and floor inside, concourse outside.
  final List<MapPoint> bowl;
  final List<MapSection> sections;

  MapPoint get bowlCenter {
    var x = 0.0, y = 0.0;
    for (final p in bowl) {
      x += p.$1;
      y += p.$2;
    }
    return (x / bowl.length, y / bowl.length);
  }

  /// Where a ray from the bowl center at [angle] (radians, 0 = east, clockwise on screen)
  /// leaves the bowl, and where it reaches the outer wall.
  (MapPoint, MapPoint) _crossings(double angle) {
    final c = bowlCenter;
    final dx = cos(angle), dy = sin(angle);
    double? hit(List<MapPoint> poly) {
      double? best;
      for (var i = 0; i < poly.length; i++) {
        final a = poly[i], b = poly[(i + 1) % poly.length];
        final ex = b.$1 - a.$1, ey = b.$2 - a.$2;
        final den = dx * ey - dy * ex;
        if (den.abs() < 1e-12) continue;
        final t = ((a.$1 - c.$1) * ey - (a.$2 - c.$2) * ex) / den;
        final u = ((a.$1 - c.$1) * dy - (a.$2 - c.$2) * dx) / den;
        if (t > 0 && u >= 0 && u <= 1 && (best == null || t < best)) best = t;
      }
      return best;
    }

    const wall = <MapPoint>[(0, 0), (1, 0), (1, 1), (0, 1)];
    final tb = hit(bowl) ?? 0;
    final tw = hit(wall) ?? tb;
    return ((c.$1 + dx * tb, c.$2 + dy * tb), (c.$1 + dx * tw, c.$2 + dy * tw));
  }

  /// [count] points spaced evenly along the middle of the concourse, starting at the top
  /// center and going clockwise.
  List<MapPoint> concourseSpots(int count, {double depth = 0.5}) {
    const samples = 720;
    final line = <MapPoint>[];
    for (var i = 0; i < samples; i++) {
      final a = -pi / 2 + 2 * pi * i / samples;
      final (inner, outer) = _crossings(a);
      line.add((inner.$1 + (outer.$1 - inner.$1) * depth, inner.$2 + (outer.$2 - inner.$2) * depth));
    }
    // Arc length in screen proportions, so spacing looks even on the drawn map.
    final cum = <double>[0];
    for (var i = 1; i <= samples; i++) {
      final a = line[i - 1], b = line[i % samples];
      cum.add(cum.last + sqrt(pow((b.$1 - a.$1) * aspectRatio, 2) + pow(b.$2 - a.$2, 2)));
    }
    final total = cum.last;
    final out = <MapPoint>[];
    var j = 0;
    for (var k = 0; k < count; k++) {
      final target = total * k / count;
      while (cum[j + 1] < target) {
        j++;
      }
      final f = (target - cum[j]) / (cum[j + 1] - cum[j]);
      final a = line[j], b = line[(j + 1) % samples];
      out.add((_r(a.$1 + (b.$1 - a.$1) * f), _r(a.$2 + (b.$2 - a.$2) * f)));
    }
    return out;
  }

  /// The seating section nearest a point on the concourse, by direction from the bowl center.
  MapSection nearestSection(MapPoint p) {
    final c = bowlCenter;
    double angleOf(MapPoint q) => atan2((q.$2 - c.$2), (q.$1 - c.$1) * aspectRatio);
    final a = angleOf(p);
    MapSection? best;
    var bestDiff = double.infinity;
    for (final s in sections) {
      var d = (angleOf(s.center) - a).abs();
      if (d > pi) d = 2 * pi - d;
      if (d < bestDiff) {
        bestDiff = d;
        best = s;
      }
    }
    return best!;
  }

  static double _r(double v) => (v * 10000).round() / 10000;
}

/// Layouts by id, for `venue.settings['map']['layout']`.
const venueMapLayouts = <String, VenueMapLayout>{'cutx': cutxLayout};

const cutxLayout = VenueMapLayout(
  id: 'cutx',
  name: 'Credit Union of Texas Event Center',
  aspectRatio: 1.4537,
  bowl: [
    (0.1975, 0.112),
    (0.7365, 0.112),
    (0.8503, 0.2076),
    (0.9151, 0.3488),
    (0.9151, 0.6488),
    (0.8503, 0.79),
    (0.7365, 0.8855),
    (0.1975, 0.8855),
    (0.0928, 0.8),
    (0.0329, 0.6488),
    (0.0329, 0.3488),
    (0.0928, 0.1975),
  ],
  sections: [
    MapSection('100', [
      (0.06, 0.2988),
      (0.0389, 0.3528),
      (0.0387, 0.4898),
      (0.0903, 0.4894),
      (0.0924, 0.4731),
      (0.1344, 0.4727),
      (0.1363, 0.4889),
      (0.1707, 0.4884),
      (0.1708, 0.4079),
      (0.1785, 0.3917),
      (0.1479, 0.3677),
      (0.1402, 0.3813),
      (0.102, 0.3494),
      (0.1039, 0.3333),
    ]),
    MapSection('101', [
      (0.0964, 0.2097),
      (0.0695, 0.2772),
      (0.1154, 0.3144),
      (0.1211, 0.3008),
      (0.1593, 0.3299),
      (0.1555, 0.3435),
      (0.188, 0.3673),
      (0.1995, 0.3457),
      (0.1824, 0.3029),
      (0.1728, 0.3083),
      (0.1499, 0.2576),
      (0.1594, 0.2468),
      (0.1346, 0.1824),
    ]),
    MapSection('102', [
      (0.2552, 0.1301),
      (0.1959, 0.1307),
      (0.1499, 0.1688),
      (0.1747, 0.233),
      (0.1843, 0.2248),
      (0.2072, 0.2812),
      (0.1977, 0.2894),
      (0.2149, 0.3321),
      (0.2378, 0.3157),
      (0.255, 0.3156),
      (0.2551, 0.2671),
      (0.2435, 0.2647),
      (0.2436, 0.2056),
      (0.2551, 0.2026),
    ]),
    MapSection('103', [
      (0.2743, 0.1299),
      (0.2742, 0.2025),
      (0.2857, 0.2051),
      (0.2857, 0.2642),
      (0.2742, 0.267),
      (0.2741, 0.3153),
      (0.3564, 0.3145),
      (0.3564, 0.266),
      (0.3449, 0.2636),
      (0.345, 0.2045),
      (0.3565, 0.2015),
      (0.3565, 0.129),
    ]),
    MapSection('104', [
      (0.3757, 0.1289),
      (0.3756, 0.2014),
      (0.387, 0.204),
      (0.387, 0.2631),
      (0.3756, 0.2659),
      (0.3755, 0.3144),
      (0.4577, 0.3134),
      (0.4577, 0.265),
      (0.4463, 0.2625),
      (0.4464, 0.2034),
      (0.4579, 0.2005),
      (0.4579, 0.1279),
    ]),
    MapSection('105', [
      (0.4751, 0.1278),
      (0.4751, 0.2003),
      (0.4865, 0.2029),
      (0.4864, 0.262),
      (0.4749, 0.2648),
      (0.4749, 0.3133),
      (0.5572, 0.3123),
      (0.5572, 0.264),
      (0.5458, 0.2614),
      (0.5458, 0.2023),
      (0.5573, 0.1995),
      (0.5573, 0.1269),
    ]),
    MapSection('106', [
      (0.5764, 0.1267),
      (0.5764, 0.1992),
      (0.5879, 0.2019),
      (0.5878, 0.261),
      (0.5763, 0.2637),
      (0.5763, 0.3122),
      (0.6585, 0.3113),
      (0.6586, 0.263),
      (0.6471, 0.2603),
      (0.6471, 0.2012),
      (0.6586, 0.1985),
      (0.6587, 0.1258),
    ]),
    MapSection('107', [
      (0.6778, 0.1256),
      (0.6778, 0.1981),
      (0.6893, 0.2008),
      (0.6892, 0.2599),
      (0.6777, 0.2627),
      (0.6777, 0.3111),
      (0.6949, 0.311),
      (0.7178, 0.3269),
      (0.735, 0.2836),
      (0.7255, 0.2756),
      (0.7485, 0.219),
      (0.7581, 0.2269),
      (0.783, 0.1622),
      (0.7372, 0.125),
    ]),
    MapSection('108', [
      (0.8503, 0.2076),
      (0.8024, 0.1674),
      (0.7734, 0.2401),
      (0.7829, 0.2481),
      (0.7753, 0.2671),
      (0.7886, 0.2804),
      (0.8039, 0.3177),
      (0.8747, 0.261),
    ]),
    MapSection('109', [
      (0.8848, 0.2829),
      (0.8785, 0.2847),
      (0.7541, 0.3855),
      (0.7618, 0.4015),
      (0.7617, 0.4392),
      (0.9109, 0.4377),
      (0.9109, 0.3398),
    ]),
    MapSection('110', [(0.8592, 0.4651), (0.8591, 0.5215), (0.9108, 0.521), (0.9108, 0.4645)]),
    MapSection('111', [
      (0.7616, 0.5494),
      (0.7616, 0.587),
      (0.7539, 0.6032),
      (0.8781, 0.7014),
      (0.8877, 0.704),
      (0.9107, 0.6472),
      (0.9108, 0.5478),
    ]),
    MapSection('112', [
      (0.8036, 0.6699),
      (0.7882, 0.7077),
      (0.7748, 0.7213),
      (0.7825, 0.74),
      (0.7729, 0.7481),
      (0.805, 0.8279),
      (0.8503, 0.79),
      (0.8751, 0.736),
      (0.8781, 0.7282),
    ]),
    MapSection('113', [
      (0.6946, 0.6792),
      (0.6774, 0.6793),
      (0.6773, 0.7276),
      (0.6887, 0.7302),
      (0.6887, 0.7894),
      (0.6773, 0.7921),
      (0.6772, 0.8648),
      (0.7346, 0.8642),
      (0.7409, 0.8818),
      (0.7896, 0.8409),
      (0.7576, 0.7617),
      (0.7481, 0.7699),
      (0.7252, 0.7164),
      (0.7347, 0.7056),
      (0.7175, 0.6628),
    ]),
    MapSection('114', [
      (0.576, 0.6804),
      (0.5759, 0.7287),
      (0.5875, 0.7313),
      (0.5874, 0.7904),
      (0.5759, 0.7932),
      (0.5758, 0.8657),
      (0.6581, 0.865),
      (0.6582, 0.7924),
      (0.6467, 0.7898),
      (0.6467, 0.7307),
      (0.6582, 0.7279),
      (0.6583, 0.6795),
    ]),
    MapSection('115', [
      (0.4746, 0.6815),
      (0.4746, 0.7298),
      (0.4861, 0.7324),
      (0.486, 0.7915),
      (0.4745, 0.7943),
      (0.4745, 0.8668),
      (0.5567, 0.866),
      (0.5568, 0.7935),
      (0.5453, 0.7909),
      (0.5453, 0.7318),
      (0.5568, 0.729),
      (0.5569, 0.6806),
    ]),
    MapSection('116', [
      (0.3752, 0.6826),
      (0.3752, 0.7309),
      (0.3866, 0.7335),
      (0.3865, 0.7926),
      (0.3751, 0.7954),
      (0.3751, 0.8679),
      (0.4572, 0.8671),
      (0.4573, 0.7944),
      (0.4459, 0.792),
      (0.4459, 0.7329),
      (0.4573, 0.7299),
      (0.4574, 0.6816),
    ]),
    MapSection('117', [
      (0.2738, 0.6835),
      (0.2738, 0.7319),
      (0.2852, 0.7346),
      (0.2852, 0.7937),
      (0.2737, 0.7965),
      (0.2737, 0.869),
      (0.3559, 0.8682),
      (0.3559, 0.7955),
      (0.3445, 0.7931),
      (0.3445, 0.7392),
      (0.3235, 0.7395),
      (0.3215, 0.7153),
      (0.3215, 0.7315),
      (0.3158, 0.7341),
      (0.312, 0.7289),
      (0.3101, 0.71),
      (0.3159, 0.7046),
      (0.3217, 0.7099),
      (0.3217, 0.683),
    ]),
    MapSection('118', [
      (0.2145, 0.6681),
      (0.1972, 0.7113),
      (0.2069, 0.7191),
      (0.1839, 0.7759),
      (0.1743, 0.7679),
      (0.1494, 0.8327),
      (0.1952, 0.8699),
      (0.2546, 0.8691),
      (0.2546, 0.7966),
      (0.2431, 0.7941),
      (0.2432, 0.7349),
      (0.2547, 0.7321),
      (0.2547, 0.6838),
      (0.2375, 0.684),
    ]),
    MapSection('119', [
      (0.1878, 0.6333),
      (0.1553, 0.6579),
      (0.163, 0.6605),
      (0.1609, 0.6875),
      (0.1552, 0.6821),
      (0.1552, 0.6741),
      (0.1227, 0.7012),
      (0.1151, 0.688),
      (0.0691, 0.7261),
      (0.0959, 0.7929),
      (0.1341, 0.8194),
      (0.159, 0.7546),
      (0.1495, 0.744),
      (0.1724, 0.6927),
      (0.182, 0.698),
      (0.1993, 0.6548),
    ]),
    MapSection('120', [
      (0.0387, 0.514),
      (0.0386, 0.6511),
      (0.0596, 0.7046),
      (0.1036, 0.6693),
      (0.1017, 0.6531),
      (0.14, 0.6205),
      (0.1477, 0.6338),
      (0.1782, 0.6093),
      (0.1706, 0.5932),
      (0.1707, 0.5127),
      (0.1363, 0.513),
      (0.1343, 0.5292),
      (0.0923, 0.5296),
      (0.0903, 0.5134),
    ]),
  ],
);
