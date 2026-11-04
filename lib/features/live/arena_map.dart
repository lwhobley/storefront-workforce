import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import 'live_model.dart';

/// Arena map for one level, with a pin for each storefront at its saved position.
///
/// When the venue has a traced plan ([layout], for example CUTX), the map draws that
/// building: the outer wall, the concourse where the storefronts are, the seating
/// sections, and the floor. Otherwise it draws a generic bowl.
class ArenaMap extends StatelessWidget {
  const ArenaMap({
    super.key,
    required this.storefronts,
    required this.summaries,
    required this.onTap,
    this.selectedId,
    this.levelName = '',
    this.layout,
  });

  final List<Storefront> storefronts;
  final Map<String, StorefrontSummary> summaries;
  final ValueChanged<Storefront> onTap;
  final String? selectedId;
  final String levelName;
  final VenueMapLayout? layout;

  @override
  Widget build(BuildContext context) {
    final plan = layout;
    return AspectRatio(
      aspectRatio: plan?.aspectRatio ?? 1.45,
      child: LayoutBuilder(
        builder: (context, box) {
          final shown = [for (final s in storefronts) if (s.active) s];
          // A small lineup leaves room to print each name next to its pin.
          final named = shown.length <= 16;
          final pinSize = (box.maxWidth / (named ? 14 : (plan == null ? 15 : 18))).clamp(28.0, 48.0);
          const labelWidth = 104.0;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: CustomPaint(painter: plan == null ? _BowlPainter(levelName) : _PlanPainter(plan, levelName)),
              ),
              if (named)
                for (final s in shown)
                  Positioned(
                    // Labels sit inside the map: below pins on the top half, above on the
                    // bottom half, and pulled in from the left and right walls.
                    left: (s.mapX * box.maxWidth - labelWidth / 2).clamp(0.0, box.maxWidth - labelWidth),
                    top: s.mapY < 0.5 ? s.mapY * box.maxHeight + pinSize / 2 + 2 : null,
                    bottom: s.mapY >= 0.5 ? (1 - s.mapY) * box.maxHeight + pinSize / 2 + 2 : null,
                    width: labelWidth,
                    child: IgnorePointer(
                      child: Text(
                        mapLabel(s.name),
                        textAlign: s.mapX < 0.12 ? TextAlign.left : s.mapX > 0.88 ? TextAlign.right : TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, height: 1.15, fontWeight: FontWeight.w700, color: AppColors.text),
                      ),
                    ),
                  ),
              for (final s in shown)
                Positioned(
                  left: s.mapX * box.maxWidth - pinSize / 2,
                  top: s.mapY * box.maxHeight - pinSize / 2,
                  width: pinSize,
                  height: pinSize,
                  child: _Pin(
                    storefront: s,
                    summary: summaries[s.id],
                    size: pinSize,
                    showCode: !named,
                    selected: s.id == selectedId,
                    onTap: () => onTap(s),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The name drawn on the map: sponsor credits ("presented by ...") are dropped.
String mapLabel(String name) {
  final i = name.toLowerCase().indexOf(' presented by');
  return i > 0 ? name.substring(0, i) : name;
}

class _Pin extends StatelessWidget {
  const _Pin({
    required this.storefront,
    required this.summary,
    required this.size,
    required this.selected,
    required this.onTap,
    this.showCode = true,
  });

  final Storefront storefront;
  final StorefrontSummary? summary;
  final double size;
  final bool selected;
  final VoidCallback onTap;
  final bool showCode;

  IconData get _icon => switch (storefront.kind) {
        StorefrontKind.bar => Icons.local_bar,
        StorefrontKind.portableCart => Icons.shopping_cart,
        StorefrontKind.kiosk => Icons.storefront,
        StorefrontKind.permanentStand => Icons.restaurant,
      };

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final tone = s?.tone ?? Tone.idle;
    final color = toneColor(tone, context);
    final closed = s == null || !s.isOpen;
    final label = closed
        ? '${storefront.name}, closed'
        : '${storefront.name}: ${s.onSite} on site of ${s.needed} needed'
            '${s.missing > 0 ? ', ${s.missing} missing' : ''}'
            '${s.openPositions > 0 ? ', ${s.openPositions} open' : ''}';
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: Material(
          color: closed ? AppColors.idleSoft : color,
          shape: CircleBorder(
            side: BorderSide(color: selected ? AppColors.text : Colors.white, width: selected ? 3 : 2),
          ),
          elevation: selected ? 4 : 1,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(_icon, size: size * (showCode ? 0.34 : 0.5), color: closed ? AppColors.idle : Colors.white),
                    if (showCode)
                      Text(
                      storefront.code,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        fontSize: size * 0.24,
                        height: 1,
                        fontWeight: FontWeight.w800,
                        color: closed ? AppColors.idle : Colors.white,
                      ),
                    ),
                  ],
                ),
                // Count of problems in the corner, so a red pin says how bad.
                if (!closed && (s.missing + s.openPositions) > 0)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(color: AppColors.text, borderRadius: BorderRadius.circular(8)),
                      child: Text('${s.missing + s.openPositions}',
                          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws a traced venue plan, concourse first.
class _PlanPainter extends CustomPainter {
  _PlanPainter(this.plan, this.levelName);

  final VenueMapLayout plan;
  final String levelName;

  Path _path(List<MapPoint> pts, Size size) {
    final path = Path()..moveTo(pts.first.$1 * size.width, pts.first.$2 * size.height);
    for (final p in pts.skip(1)) {
      path.lineTo(p.$1 * size.width, p.$2 * size.height);
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final edge = Paint()
      ..color = AppColors.divider
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    // Outer wall and concourse: the walkway between the wall and the bowl, where the
    // storefronts are. Drawn brightest, since it is what the map is about.
    final wall = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10));
    canvas.drawRRect(wall, Paint()..color = AppColors.raised);
    canvas.drawRRect(wall, Paint()
      ..color = AppColors.ink(0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2);

    // Bowl: floor color first, seating sections on top; the uncovered middle is the floor.
    final bowl = _path(plan.bowl, size);
    canvas.drawPath(bowl, Paint()..color = const Color(0xFFDDE9EE));
    canvas.drawPath(bowl, edge);
    final seat = Paint()..color = AppColors.idleSoft;
    final seatEdge = Paint()
      ..color = AppColors.background
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final fontSize = (size.width * 0.018).clamp(8.0, 13.0);
    for (final section in plan.sections) {
      final path = _path(section.points, size);
      canvas.drawPath(path, seat);
      canvas.drawPath(path, seatEdge);
      final c = section.center;
      final tp = TextPainter(
        text: TextSpan(text: section.name, style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700, color: AppColors.muted)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(c.$1 * size.width - tp.width / 2, c.$2 * size.height - tp.height / 2));
    }

    final center = plan.bowlCenter;
    final label = TextPainter(
      text: TextSpan(
        text: 'FLOOR',
        style: TextStyle(fontSize: fontSize * 1.1, fontWeight: FontWeight.w800, letterSpacing: 2, color: AppColors.ink(0.4)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    label.paint(canvas, Offset(center.$1 * size.width - label.width / 2, center.$2 * size.height - label.height / 2));

  }

  @override
  bool shouldRepaint(covariant _PlanPainter old) => old.plan != plan || old.levelName != levelName;
}

class _BowlPainter extends CustomPainter {
  _BowlPainter(this.levelName);

  final String levelName;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final outer = Rect.fromCenter(center: c, width: size.width * 0.98, height: size.height * 0.96);
    final ring = Rect.fromCenter(center: c, width: size.width * 0.84, height: size.height * 0.72);
    final seats = Rect.fromCenter(center: c, width: size.width * 0.66, height: size.height * 0.5);
    final floor = Rect.fromCenter(center: c, width: size.width * 0.42, height: size.height * 0.26);

    final wall = Paint()..color = AppColors.surface;
    final edge = Paint()
      ..color = AppColors.divider
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRRect(RRect.fromRectAndRadius(outer, Radius.circular(size.height * 0.4)), wall);
    canvas.drawRRect(RRect.fromRectAndRadius(outer, Radius.circular(size.height * 0.4)), edge);

    // Concourse ring (where storefronts sit).
    final concourse = Paint()..color = AppColors.raised;
    canvas.drawRRect(RRect.fromRectAndRadius(ring, Radius.circular(size.height * 0.34)), concourse);
    canvas.drawRRect(RRect.fromRectAndRadius(ring, Radius.circular(size.height * 0.34)), edge);

    // Seating bowl, drawn as wedges so sections read as sections.
    final seatPaint = Paint()..color = AppColors.idleSoft;
    canvas.drawRRect(RRect.fromRectAndRadius(seats, Radius.circular(size.height * 0.24)), seatPaint);
    final spoke = Paint()
      ..color = AppColors.background
      ..strokeWidth = 2;
    for (var i = 0; i < 16; i++) {
      final a = i * math.pi * 2 / 16;
      final dir = Offset(math.cos(a) * seats.width / 2, math.sin(a) * seats.height / 2);
      canvas.drawLine(c + dir * 0.55, c + dir * 1.02, spoke);
    }

    // Event floor.
    final floorPaint = Paint()..color = const Color(0xFFDDE9EE);
    canvas.drawRRect(RRect.fromRectAndRadius(floor, Radius.circular(size.height * 0.1)), floorPaint);
    canvas.drawRRect(RRect.fromRectAndRadius(floor, Radius.circular(size.height * 0.1)), edge);
    final center = Paint()
      ..color = AppColors.divider
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(c.dx, floor.top), Offset(c.dx, floor.bottom), center);

    final tp = TextPainter(
      text: TextSpan(
        text: levelName.toUpperCase(),
        style: TextStyle(fontSize: size.width * 0.022, fontWeight: FontWeight.w800, letterSpacing: 1.5, color: AppColors.muted),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: floor.width);
    tp.paint(canvas, Offset(c.dx - tp.width / 2, c.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _BowlPainter old) => old.levelName != levelName;
}
