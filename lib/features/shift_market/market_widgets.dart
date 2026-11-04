import 'package:flutter/material.dart';

import '../../core/i18n/strings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import 'shift_strings.dart';

/// A scrolling list kept to a readable width on tablets and desktops.
class MarketList extends StatelessWidget {
  const MarketList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 48),
        children: [
          for (final c in children)
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: SizedBox(width: double.infinity, child: c)),
            ),
        ],
      );
}

/// Date kicker and title above a group of cards.
class GroupHeading extends StatelessWidget {
  const GroupHeading({super.key, required this.title, this.kicker, this.trailing});

  final String title;
  final String? kicker;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.xl, AppSpace.screen, AppSpace.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (kicker != null) Text(kicker!.toUpperCase(), style: AppText.kicker),
                Semantics(header: true, child: Text(title, style: AppText.sectionHeading)),
              ]),
            ),
            ?trailing,
          ],
        ),
      );
}

/// One position: when, where, what role. Actions go in [children].
class ShiftCard extends StatelessWidget {
  const ShiftCard({
    super.key,
    required this.t,
    required this.zone,
    required this.callTime,
    required this.storefront,
    required this.role,
    this.eventName = '',
    this.detail = '',
    this.tags = const [],
    this.children = const [],
    this.showDay = true,
  });

  final T t;
  final String zone;
  final DateTime callTime;
  final String storefront;
  final String role;
  final String eventName;
  final String detail;
  final List<Widget> tags;
  final List<Widget> children;

  /// Off when a heading above already gives the date.
  final bool showDay;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.s, AppSpace.screen, 0),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showDay || tags.isNotEmpty) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(showDay ? t.day(callTime, zone).toUpperCase() : '', style: AppText.kicker)),
                    if (tags.isNotEmpty)
                      Expanded(
                        child: Align(
                          alignment: Alignment.topRight,
                          child: Wrap(alignment: WrapAlignment.end, spacing: 4, runSpacing: 4, children: tags),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
              Text(storefront, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, height: 1.2)),
              const SizedBox(height: 2),
              Text('$role · ${t.callTime} ${t.clock(callTime, zone)}', style: AppText.body.copyWith(fontSize: 16)),
              if (eventName.isNotEmpty || detail.isNotEmpty)
                Text([if (eventName.isNotEmpty) eventName, if (detail.isNotEmpty) detail].join(' · '), style: AppText.meta),
              if (children.isNotEmpty) ...[const SizedBox(height: AppSpace.m), ...children],
            ],
          ),
        ),
      );
}

/// An icon and a sentence, colored by tone (never color alone).
class StatusLine extends StatelessWidget {
  const StatusLine({super.key, required this.icon, required this.tone, required this.text});

  final IconData icon;
  final Tone tone;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 20, color: toneColor(tone, context))),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: AppText.body.copyWith(color: tone == Tone.idle ? AppColors.muted : toneColor(tone, context), fontWeight: FontWeight.w600)),
          ),
        ],
      );
}

class InfoBanner extends StatelessWidget {
  const InfoBanner({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, 0),
        padding: const EdgeInsets.all(AppSpace.m),
        decoration: BoxDecoration(color: toneSoft(Tone.info, context), borderRadius: BorderRadius.circular(6)),
        child: Row(children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: AppText.body)),
        ]),
      );
}

/// A full-width button tall enough for a thumb in a hurry.
class BigButton extends StatelessWidget {
  const BigButton.filled({super.key, required this.label, required this.icon, required this.onPressed}) : outlined = false;
  const BigButton.outlined({super.key, required this.label, required this.icon, required this.onPressed}) : outlined = true;

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 16, fontWeight: FontWeight.w700);
    final text = Text(label, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis);
    return SizedBox(
      width: double.infinity,
      child: outlined
          ? OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52), textStyle: style, padding: const EdgeInsets.symmetric(horizontal: 12)),
              onPressed: onPressed,
              icon: Icon(icon),
              label: text,
            )
          : FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 52), textStyle: style, padding: const EdgeInsets.symmetric(horizontal: 12)),
              onPressed: onPressed,
              icon: Icon(icon),
              label: text,
            ),
    );
  }
}

/// Two buttons side by side; one alone fills the row.
class ButtonPair extends StatelessWidget {
  const ButtonPair({super.key, this.left, this.right});

  final Widget? left;
  final Widget? right;

  @override
  Widget build(BuildContext context) {
    final items = [?left, ?right];
    if (items.length == 1) return items.single;
    return Row(children: [
      Expanded(child: items[0]),
      const SizedBox(width: AppSpace.s),
      Expanded(child: items[1]),
    ]);
  }
}

/// Asks for a short text in the person's language. Returns null if cancelled; an empty
/// string when the field is optional and left blank. With [showField] false it is a plain
/// confirmation.
Future<String?> askText(
  BuildContext context, {
  required T t,
  required String title,
  required String action,
  String? message,
  String hint = '',
  List<String> suggestions = const [],
  bool required = false,
  bool showField = true,
}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message != null) Text(message, style: AppText.body),
              if (showField) ...[
                if (message != null) const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLength: 300,
                  decoration: InputDecoration(hintText: hint, counterText: ''),
                  onChanged: (_) => setState(() {}),
                ),
              ],
              if (suggestions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final s in suggestions) ActionChip(label: Text(s), onPressed: () => setState(() => controller.text = s)),
                ]),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(t.cancel)),
          FilledButton(
            onPressed: required && controller.text.trim().isEmpty ? null : () => Navigator.pop(context, controller.text.trim()),
            child: Text(action),
          ),
        ],
      ),
    ),
  );
}
