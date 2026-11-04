import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import 'punch_queue.dart';

/// The employee's screen: where to be, when, and one big button for the next clock
/// action. Works offline; punches wait on the phone until there is signal.
class ClockScreen extends ConsumerStatefulWidget {
  const ClockScreen({super.key});

  @override
  ConsumerState<ClockScreen> createState() => _ClockScreenState();
}

class _ClockScreenState extends ConsumerState<ClockScreen> {
  bool _busy = false;

  /// Server punches plus punches still waiting on this phone.
  List<Punch> _allPunches(MyDay day, AppSession session) {
    final known = {for (final p in day.punches) p.id};
    final pending = ref.read(punchQueueProvider.notifier).pendingDrafts();
    return [
      ...day.punches,
      for (final d in pending)
        if (!known.contains(d.id) && d.eventId == day.current?.event.id && day.worker != null)
          Punch(
            id: d.id,
            venueId: session.venue.id,
            workerId: day.worker!.id,
            eventId: d.eventId,
            shiftId: d.shiftId,
            kind: d.kind,
            breakKind: d.breakKind,
            occurredAt: d.occurredAt,
          ),
    ]..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
  }

  Future<Uint8List?> _photo(T t) async {
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 480,
        imageQuality: 60,
      );
      return file == null ? null : await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<(Position?, bool?)> _location(GeofenceRules geo) async {
    if (!geo.enabled) return (null, null);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return (null, false);
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 12)),
      );
      return (pos, isWithinGeofence(geo, pos.latitude, pos.longitude, accuracyMeters: pos.accuracy));
    } catch (_) {
      return (null, false);
    }
  }

  Future<void> _punch(PunchKind kind, {BreakKind? breakKind, required MyDay day, required AppSession session}) async {
    final t = ref.read(stringsProvider);
    final rules = session.rules;
    final current = day.current;
    if (current == null) return;
    setState(() => _busy = true);
    try {
      final now = DateTime.now().toUtc();
      if (kind == PunchKind.clockIn && !canClockIn(current.shift.callTime, now, rules.attendance)) {
        showMessage(context, t.tooEarly);
        return;
      }
      final (pos, inside) = await _location(rules.clock.geofence);
      if (rules.clock.geofence.enabled && inside != true) {
        if (mounted) showMessage(context, t.outsideVenue);
        return;
      }
      Uint8List? photo;
      if (rules.clock.requirePhoto && (kind == PunchKind.clockIn || kind == PunchKind.clockOut)) {
        photo = await _photo(t);
        if (photo == null) {
          if (mounted) showMessage(context, t.photoNeeded);
          return;
        }
      }
      final draft = PunchDraft(
        id: const Uuid().v4(),
        kind: kind,
        breakKind: breakKind,
        occurredAt: now,
        eventId: current.event.id,
        shiftId: current.shift.id,
        latitude: pos?.latitude,
        longitude: pos?.longitude,
        accuracyMeters: pos?.accuracy,
        withinGeofence: inside,
      );
      final sent = await ref.read(punchQueueProvider.notifier).record(draft, photo: photo);
      if (!mounted) return;
      showMessage(context, sent ? t.confirmed : t.savedOffline);
      ref.invalidate(myDayProvider);
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final session = ref.watch(sessionProvider)!;
    final dayAsync = ref.watch(myDayProvider);
    final queue = ref.watch(punchQueueProvider);
    final now = ref.watch(clockProvider).value ?? DateTime.now().toUtc();
    final zone = session.venue.timeZone;
    final time = DateFormat('h:mm a');

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await ref.read(punchQueueProvider.notifier).flush();
            ref.invalidate(myDayProvider);
          },
          child: ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              ScreenHeader(
                kicker: session.venue.name,
                title: t.hello(session.displayName.split(' ').first),
                actions: [
                  TextButton(onPressed: () => ref.read(languageProvider.notifier).toggle(), child: Text(t.language)),
                ],
              ),
              _QueueBanner(queue: queue, t: t),
              dayAsync.when(
                loading: () => const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
                error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(myDayProvider)),
                data: (day) {
                  final current = day.current;
                  if (current == null) return EmptyNote(t.noShiftToday);
                  final punches = _allPunches(day, session);
                  final timeline = WorkTimeline.fromPunches(punches, now: now);
                  final released = current.shift.status == ShiftStatus.released;
                  final attendance = evaluateAttendance(
                    callTime: current.shift.callTime,
                    timeline: timeline,
                    rules: session.rules.attendance,
                    now: now,
                    released: released,
                  );
                  final breaks = evaluateBreaks(timeline: timeline, rules: session.rules.breaks, now: now);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _ShiftCard(shift: current, t: t, zone: zone, time: time, timeline: timeline, attendance: attendance, released: released),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                        child: _Actions(
                          state: released && timeline.state != TimelineState.working ? TimelineState.clockedOut : timeline.state,
                          busy: _busy,
                          t: t,
                          onPunch: (kind, [breakKind]) => _punch(kind, breakKind: breakKind, day: day, session: session),
                        ),
                      ),
                      if (timeline.state == TimelineState.working) _BreakHint(breaks: breaks, t: t),
                      if (day.shifts.length > 1) ...[
                        SectionHeading(t.upcoming),
                        for (final s in day.shifts.skip(1))
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                            title: Text(s.event.name),
                            subtitle: Text(
                              '${DateFormat('EEE MMM d').format(atVenue(s.shift.callTime, zone))} · ${t.callTime} ${time.format(atVenue(s.shift.callTime, zone))}\n'
                              '${s.storefront?.name ?? ''} · ${s.roleName}',
                            ),
                            isThreeLine: true,
                          ),
                      ],
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QueueBanner extends StatelessWidget {
  const _QueueBanner({required this.queue, required this.t});

  final PunchQueueState queue;
  final T t;

  @override
  Widget build(BuildContext context) {
    if (queue.pending == 0 && queue.needsReview == 0) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(AppSpace.screen, 0, AppSpace.screen, AppSpace.m),
      padding: const EdgeInsets.all(AppSpace.m),
      decoration: BoxDecoration(color: AppColors.warnSoft, borderRadius: BorderRadius.circular(6)),
      child: Row(
        children: [
          const Icon(Icons.cloud_upload_outlined, color: AppColors.warn),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              queue.needsReview > 0 ? '${t.waitingToSend(queue.pending)} · ${queue.lastError}' : '${t.waitingToSend(queue.pending)}. ${t.savedOffline}',
              style: AppText.body,
            ),
          ),
        ],
      ),
    );
  }
}

class _ShiftCard extends StatelessWidget {
  const _ShiftCard({
    required this.shift,
    required this.t,
    required this.zone,
    required this.time,
    required this.timeline,
    required this.attendance,
    required this.released,
  });

  final MyShift shift;
  final T t;
  final String zone;
  final DateFormat time;
  final WorkTimeline timeline;
  final AttendanceResult attendance;
  final bool released;

  @override
  Widget build(BuildContext context) {
    final (label, tone) = released
        ? (t.sentHome, Tone.idle)
        : switch (timeline.state) {
            TimelineState.notStarted => attendance.status == AttendanceStatus.notArrived || attendance.status == AttendanceStatus.noShow
                ? (t.late, Tone.bad)
                : (t.notClockedIn, Tone.idle),
            TimelineState.working => (t.working, Tone.good),
            TimelineState.onBreak => (t.onBreak, Tone.warn),
            TimelineState.clockedOut => (t.clockedOut, Tone.idle),
          };
    return Card(
      margin: const EdgeInsets.fromLTRB(AppSpace.screen, 0, AppSpace.screen, AppSpace.l),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.l),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(shift.event.name, style: AppText.meta.copyWith(fontWeight: FontWeight.w600))),
                StatusTag(label, tone),
              ],
            ),
            const SizedBox(height: 12),
            Text(t.yourPost.toUpperCase(), style: AppText.kicker),
            Text(shift.storefront?.name ?? '—', style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, height: 1.15)),
            Text(
              [shift.roleName, if (shift.stationName.isNotEmpty) shift.stationName, if ((shift.storefront?.section ?? '').isNotEmpty) 'Sec ${shift.storefront!.section}']
                  .join(' · '),
              style: AppText.body.copyWith(fontSize: 17),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _Fact(label: t.callTime, value: time.format(atVenue(shift.shift.callTime, zone))),
                ),
                Expanded(
                  child: _Fact(
                    label: attendance.status == AttendanceStatus.late ? t.late : t.hoursWorked(''),
                    value: attendance.status == AttendanceStatus.late
                        ? t.minutesLate(attendance.minutesLate)
                        : (timeline.workedMinutes / 60).toStringAsFixed(1),
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

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.trim().toUpperCase(), style: AppText.kicker),
          Text(value, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        ],
      );
}

class _Actions extends StatelessWidget {
  const _Actions({required this.state, required this.busy, required this.t, required this.onPunch});

  final TimelineState state;
  final bool busy;
  final T t;
  final void Function(PunchKind kind, [BreakKind? breakKind]) onPunch;

  Widget _big(BuildContext context, String label, IconData icon, Color color, VoidCallback? onTap) => SizedBox(
        height: 72,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: color, textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          onPressed: busy ? null : onTap,
          icon: busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white)) : Icon(icon, size: 28),
          label: Text(label),
        ),
      );

  Widget _second(String label, IconData icon, VoidCallback onTap) => SizedBox(
        height: 56,
        child: OutlinedButton.icon(onPressed: busy ? null : onTap, icon: Icon(icon), label: Text(label, style: const TextStyle(fontSize: 17))),
      );

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case TimelineState.notStarted:
        return _big(context, t.clockIn, Icons.login, AppColors.good, () => onPunch(PunchKind.clockIn));
      case TimelineState.working:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _big(context, t.startBreak, Icons.free_breakfast_outlined, Theme.of(context).colorScheme.primary,
                () => onPunch(PunchKind.breakStart, BreakKind.rest)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _second(t.startMeal, Icons.restaurant_outlined, () => onPunch(PunchKind.breakStart, BreakKind.meal))),
                const SizedBox(width: 10),
                Expanded(child: _second(t.clockOut, Icons.logout, () => onPunch(PunchKind.clockOut))),
              ],
            ),
          ],
        );
      case TimelineState.onBreak:
        return _big(context, t.endBreak, Icons.play_arrow, AppColors.warn, () => onPunch(PunchKind.breakEnd));
      case TimelineState.clockedOut:
        return Container(
          padding: const EdgeInsets.all(AppSpace.l),
          decoration: BoxDecoration(color: AppColors.idleSoft, borderRadius: BorderRadius.circular(6)),
          child: Row(children: [const Icon(Icons.check_circle_outline), const SizedBox(width: 10), Text(t.clockedOut, style: AppText.sectionHeading)]),
        );
    }
  }
}

class _BreakHint extends StatelessWidget {
  const _BreakHint({required this.breaks, required this.t});

  final BreakEvaluation breaks;
  final T t;

  @override
  Widget build(BuildContext context) {
    final next = breaks.minutesUntilNextDue;
    if (next == null) return const SizedBox.shrink();
    final due = next == 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.l, AppSpace.screen, 0),
      child: Row(
        children: [
          Icon(due ? Icons.notifications_active : Icons.schedule, color: due ? AppColors.warn : AppColors.muted),
          const SizedBox(width: 8),
          Text(due ? t.breakDueNow : t.breakDueIn(next),
              style: AppText.body.copyWith(fontSize: 17, fontWeight: FontWeight.w600, color: due ? AppColors.warn : AppColors.text)),
        ],
      ),
    );
  }
}
