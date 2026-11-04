import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/demo_repository.dart';
import '../../data/models.dart';
import '../clock/punch_queue.dart';

/// Shared clock-in tablet near the staff entrance. Type a PIN, see your post, tap the
/// action, smile for the photo. Works offline: punches wait on the tablet with the PIN
/// until the server can match it.
class KioskScreen extends ConsumerStatefulWidget {
  const KioskScreen({super.key});

  @override
  ConsumerState<KioskScreen> createState() => _KioskScreenState();
}

class _KioskScreenState extends ConsumerState<KioskScreen> {
  String? _pin;
  KioskIdentity? _who;
  bool _offline = false;
  bool _busy = false;
  String? _error;
  String? _done;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  void _clear({Duration after = Duration.zero}) {
    _reset?.cancel();
    _reset = Timer(after, () {
      if (mounted) {
        setState(() {
          _pin = null;
          _who = null;
          _offline = false;
          _done = null;
          _error = null;
        });
      }
    });
  }

  Future<void> _identify(String pin) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final who = await ref.read(repositoryProvider).kioskIdentify(pin);
      setState(() {
        _pin = pin;
        _who = who;
      });
      _clear(after: const Duration(seconds: 45));
    } on AppFailure catch (e) {
      if (e.offline) {
        setState(() {
          _pin = pin;
          _offline = true;
        });
        _clear(after: const Duration(seconds: 45));
      } else {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _punch(PunchKind kind, [BreakKind? breakKind]) async {
    final t = ref.read(stringsProvider);
    final session = ref.read(sessionProvider)!;
    setState(() => _busy = true);
    try {
      Uint8List? photo;
      if (session.rules.clock.requirePhoto && (kind == PunchKind.clockIn || kind == PunchKind.clockOut)) {
        try {
          final f = await ImagePicker().pickImage(source: ImageSource.camera, preferredCameraDevice: CameraDevice.front, maxWidth: 480, imageQuality: 60);
          photo = f == null ? null : await f.readAsBytes();
        } catch (_) {}
        if (photo == null) {
          setState(() => _error = t.photoNeeded);
          return;
        }
      }
      final draft = PunchDraft(
        id: const Uuid().v4(),
        kind: kind,
        breakKind: breakKind,
        occurredAt: DateTime.now().toUtc(),
        eventId: _who?.eventId,
        shiftId: _who?.shiftId,
      );
      final sent = await ref.read(punchQueueProvider.notifier).record(draft, photo: photo, kioskPin: _pin);
      setState(() => _done = sent ? t.confirmed : t.savedOffline);
      _clear(after: const Duration(seconds: 4));
    } on AppFailure catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final session = ref.watch(sessionProvider)!;
    final queue = ref.watch(punchQueueProvider);
    final repo = ref.watch(repositoryProvider);

    Widget body;
    if (_done != null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, size: 96, color: AppColors.good),
          const SizedBox(height: 12),
          Text(_done!, style: AppText.screenTitle, textAlign: TextAlign.center),
          if (_who != null) Text(_who!.name, style: AppText.sectionHeading),
        ],
      );
    } else if (_who != null || _offline) {
      body = _Actions(
        who: _who,
        t: t,
        zone: session.venue.timeZone,
        busy: _busy,
        error: _error,
        onPunch: _punch,
        onCancel: () => _clear(),
      );
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(t.kioskTitle.toUpperCase(), style: AppText.kicker),
          const SizedBox(height: 6),
          Text(t.kioskPrompt, style: AppText.screenTitle, textAlign: TextAlign.center),
          const SizedBox(height: AppSpace.xl),
          PinPad(onComplete: _identify, busy: _busy, error: _error, clearLabel: t.clear),
          if (repo is DemoWorkforceRepository) ...[
            const SizedBox(height: AppSpace.xl),
            Text('Demo PINs: ${repo.kioskSamples().map((s) => '${s.$1} ${s.$2}').join(' · ')}',
                style: AppText.meta, textAlign: TextAlign.center),
          ],
        ],
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.l, vertical: AppSpace.s),
              child: Row(
                children: [
                  Text(session.displayName, style: AppText.meta),
                  const Spacer(),
                  if (queue.pending > 0) StatusTag(t.waitingToSend(queue.pending), Tone.warn, icon: Icons.cloud_off),
                  TextButton(onPressed: () => ref.read(languageProvider.notifier).toggle(), child: Text(t.language)),
                  PopupMenuButton<String>(
                    tooltip: 'Kiosk menu',
                    onSelected: (v) {
                      if (v == 'out') ref.read(sessionProvider.notifier).signOut();
                    },
                    itemBuilder: (_) => [PopupMenuItem(value: 'out', child: Text(t.signOut))],
                  ),
                ],
              ),
            ),
            Expanded(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(AppSpace.xl), child: body))),
          ],
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.who, required this.t, required this.zone, required this.busy, required this.error, required this.onPunch, required this.onCancel});

  final KioskIdentity? who;
  final T t;
  final String zone;
  final bool busy;
  final String? error;
  final void Function(PunchKind kind, [BreakKind? breakKind]) onPunch;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final w = who;
    // Offline we cannot know the person's state, so every action is offered.
    final state = w == null ? null : WorkTimeline.fromPunches(w.punches, now: DateTime.now().toUtc()).state;
    Widget button(String label, IconData icon, Color color, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: SizedBox(
            width: 380,
            height: 76,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: color, textStyle: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
              onPressed: busy ? null : onTap,
              icon: Icon(icon, size: 30),
              label: Text(label),
            ),
          ),
        );
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(w == null ? t.kioskOffline : t.hello(w.name), style: AppText.screenTitle, textAlign: TextAlign.center),
        if (w != null && w.storefrontLabel.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(w.storefrontLabel, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
          if (w.callTime != null) Text('${t.callTime} ${DateFormat('h:mm a').format(atVenue(w.callTime!, zone))}', style: AppText.body.copyWith(fontSize: 18)),
        ] else if (w != null)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(t.noShiftToday, style: AppText.body)),
        const SizedBox(height: AppSpace.xl),
        if (state == null || state == TimelineState.notStarted) button(t.clockIn, Icons.login, AppColors.good, () => onPunch(PunchKind.clockIn)),
        if (state == null || state == TimelineState.working) ...[
          button(t.startBreak, Icons.free_breakfast_outlined, primary, () => onPunch(PunchKind.breakStart, BreakKind.rest)),
          button(t.startMeal, Icons.restaurant_outlined, primary, () => onPunch(PunchKind.breakStart, BreakKind.meal)),
        ],
        if (state == null || state == TimelineState.onBreak) button(t.endBreak, Icons.play_arrow, AppColors.warn, () => onPunch(PunchKind.breakEnd)),
        if (state == null || state == TimelineState.working) button(t.clockOut, Icons.logout, AppColors.text, () => onPunch(PunchKind.clockOut)),
        if (state == TimelineState.clockedOut) Text(t.clockedOut, style: AppText.sectionHeading),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: AppColors.bad, fontWeight: FontWeight.w600))),
        const SizedBox(height: AppSpace.l),
        TextButton(onPressed: busy ? null : onCancel, child: Text(t.cancel, style: const TextStyle(fontSize: 18))),
      ],
    );
  }
}
