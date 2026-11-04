import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

enum Tone { good, warn, bad, idle, info }

Color toneColor(Tone tone, BuildContext context) => switch (tone) {
      Tone.good => AppColors.good,
      Tone.warn => AppColors.warn,
      Tone.bad => AppColors.bad,
      Tone.idle => AppColors.idle,
      Tone.info => Theme.of(context).colorScheme.primary,
    };

Color toneSoft(Tone tone, BuildContext context) => switch (tone) {
      Tone.good => AppColors.goodSoft,
      Tone.warn => AppColors.warnSoft,
      Tone.bad => AppColors.badSoft,
      Tone.idle => AppColors.idleSoft,
      Tone.info => Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
    };

/// Kicker, large title, optional subtitle, and actions: the top of every screen.
class ScreenHeader extends StatelessWidget {
  const ScreenHeader({super.key, required this.title, this.kicker, this.subtitle, this.actions = const []});

  final String title;
  final String? kicker;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (kicker != null) Text(kicker!.toUpperCase(), style: AppText.kicker),
        if (kicker != null) const SizedBox(height: 4),
        Semantics(header: true, child: Text(title, style: AppText.screenTitle)),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!, style: AppText.meta),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.l, AppSpace.screen, AppSpace.m),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // On phones, actions go under the title so neither gets squeezed.
          if (actions.isNotEmpty && constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading,
                const SizedBox(height: AppSpace.m),
                Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [Expanded(child: heading), ...actions],
          );
        },
      ),
    );
  }
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.xl, AppSpace.screen, AppSpace.s),
      child: Row(
        children: [
          Expanded(child: Semantics(header: true, child: Text(text, style: AppText.sectionHeading))),
          ?trailing,
        ],
      ),
    );
  }
}

/// Small colored label with text. Color is never the only signal.
class StatusTag extends StatelessWidget {
  const StatusTag(this.label, this.tone, {super.key, this.icon});

  final String label;
  final Tone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final color = toneColor(tone, context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: toneSoft(tone, context), borderRadius: BorderRadius.circular(4)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 4)],
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }
}

/// A number with a label, for headcount and attendance summaries.
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.label, required this.value, this.detail, this.tone, this.onTap});

  final String label;
  final String value;
  final String? detail;
  final Tone? tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = tone == null ? AppColors.text : toneColor(tone!, context);
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: AppText.meta.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(value, style: AppText.numeral.copyWith(color: color, fontSize: 28)),
              if (detail != null) ...[
                const SizedBox(height: 2),
                Text(detail!, style: AppText.meta, maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class EmptyNote extends StatelessWidget {
  const EmptyNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen, vertical: AppSpace.l),
        child: Text(text, style: AppText.meta),
      );
}

class ErrorNote extends StatelessWidget {
  const ErrorNote(this.error, {super.key, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(AppSpace.screen),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Could not load. $error', style: AppText.body.copyWith(color: AppColors.bad)),
            if (onRetry != null) TextButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      );
}

/// Large number pad for PIN entry. Big keys so it works with gloves or in a hurry, and
/// hardware keyboard input on web and tablets.
class PinPad extends StatefulWidget {
  const PinPad({super.key, required this.onComplete, this.length = 6, this.busy = false, this.error, this.clearLabel = 'Clear'});

  final ValueChanged<String> onComplete;
  final int length;
  final bool busy;
  final String? error;
  final String clearLabel;

  @override
  State<PinPad> createState() => PinPadState();
}

class PinPadState extends State<PinPad> {
  String _pin = '';
  final _focus = FocusNode();

  void clear() => setState(() => _pin = '');

  void _press(String digit) {
    if (widget.busy || _pin.length >= widget.length) return;
    HapticFeedback.selectionClick();
    setState(() => _pin += digit);
    if (_pin.length == widget.length) {
      final pin = _pin;
      Future.microtask(() {
        widget.onComplete(pin);
        if (mounted) setState(() => _pin = '');
      });
    }
  }

  void _back() {
    if (_pin.isEmpty || widget.busy) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return KeyboardListener(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (event) {
        if (event is! KeyDownEvent) return;
        final ch = event.character;
        if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch)) _press(ch);
        if (event.logicalKey == LogicalKeyboardKey.backspace) _back();
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              label: 'PIN, ${_pin.length} of ${widget.length} digits entered',
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < widget.length; i++)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 7),
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < _pin.length ? AppColors.text : Colors.transparent,
                        border: Border.all(color: AppColors.text, width: 2),
                      ),
                    ),
                ],
              ),
            ),
            SizedBox(
              height: 40,
              child: Center(
                child: widget.busy
                    ? SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3, color: primary))
                    : widget.error == null
                        ? null
                        : Text(widget.error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.bad, fontWeight: FontWeight.w600)),
              ),
            ),
            for (final row in const [
              ['1', '2', '3'],
              ['4', '5', '6'],
              ['7', '8', '9'],
              ['', '0', '<'],
            ])
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final key in row)
                    Padding(
                      padding: const EdgeInsets.all(6),
                      child: SizedBox(
                        width: 88,
                        height: 68,
                        child: key.isEmpty
                            ? TextButton(onPressed: widget.busy ? null : clear, child: Text(widget.clearLabel))
                            : key == '<'
                                ? IconButton(
                                    tooltip: 'Delete',
                                    onPressed: widget.busy ? null : _back,
                                    icon: const Icon(Icons.backspace_outlined, size: 26),
                                  )
                                : FilledButton.tonal(
                                    onPressed: widget.busy ? null : () => _press(key),
                                    style: FilledButton.styleFrom(
                                      textStyle: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
                                    ),
                                    child: Text(key),
                                  ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Asks for a short reason. Returns null if cancelled.
Future<String?> askReason(BuildContext context, {required String title, String hint = 'Reason', String action = 'Save', List<String> suggestions = const [], String? message}) {
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
              if (message != null) ...[Text(message, style: AppText.body), const SizedBox(height: 12)],
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(hintText: hint),
                onChanged: (_) => setState(() {}),
              ),
              if (suggestions.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in suggestions)
                      ActionChip(label: Text(s), onPressed: () => setState(() => controller.text = s)),
                  ],
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: controller.text.trim().isEmpty ? null : () => Navigator.pop(context, controller.text.trim()),
            child: Text(action),
          ),
        ],
      ),
    ),
  );
}

void showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}
