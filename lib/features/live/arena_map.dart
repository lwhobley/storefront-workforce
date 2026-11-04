import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import 'live_model.dart';

/// Schematic arena map for one level: the event floor in the middle, the concourse
/// around it, and a pin for each storefront at its saved position. When a level has an
/// uploaded floor plan it can be drawn underneath later; the pins keep their positions.
class ArenaMap extends StatelessWidget {
  const ArenaMap({
    super.key,
    required this.storefronts,
    required this.summaries,
    required this.onTap,
    this.selectedId,
    this.levelName = '',
  });

  final List<Storefront> storefronts;
  final Map<String, StorefrontSummary> summaries;
  final ValueChanged<Storefront> onTap;
  final String? selectedId;
  final String levelName;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1.45,
      child: LayoutBuilder(
        builder: (context, box) {
          final pinSize = (box.maxWidth / 15).clamp(30.0, 46.0);
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(child: CustomPaint(painter: _BowlPainter(levelName))),
              for (final s in storefronts)
                Positioned(
                  left: s.mapX * box.maxWidth - pinSize / 2,
                  top: s.mapY * box.maxHeight - pinSize / 2,
                  width: pinSize,
                  height: pinSize,
                  child: _Pin(
                    storefront: s,
                    summary: summaries[s.id],
                    size: pinSize,
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

class _Pin extends StatelessWidget {
  const _Pin({required this.storefront, required this.summary, required this.size, required this.selected, required this.onTap});

  final Storefront storefront;
  final StorefrontSummary? summary;
  final double size;
  final bool selected;
  final VoidCallback onTap;

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
                    Icon(_icon, size: size * 0.34, color: closed ? AppColors.idle : Colors.white),
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
