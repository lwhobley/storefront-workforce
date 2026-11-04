import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';

Tone eventStatusTone(EventStatus s) => switch (s) {
      EventStatus.live => Tone.good,
      EventStatus.scheduled => Tone.info,
      EventStatus.completed => Tone.idle,
      EventStatus.cancelled => Tone.bad,
    };

String eventStatusLabel(EventStatus s) => switch (s) {
      EventStatus.live => 'Live',
      EventStatus.scheduled => 'Scheduled',
      EventStatus.completed => 'Completed',
      EventStatus.cancelled => 'Cancelled',
    };

/// Events grouped by day in venue time, the same calendar Premium Command shows. Events
/// imported from Premium Command are marked; their names and times follow it.
class EventCalendarScreen extends ConsumerStatefulWidget {
  const EventCalendarScreen({super.key});

  @override
  ConsumerState<EventCalendarScreen> createState() => _EventCalendarScreenState();
}

class _EventCalendarScreenState extends ConsumerState<EventCalendarScreen> {
  bool _past = false;
  bool _syncing = false;

  Future<void> _sync() async {
    final session = ref.read(sessionProvider)!;
    setState(() => _syncing = true);
    try {
      final result = await ref.read(repositoryProvider).syncEvents(session);
      ref.invalidate(eventsProvider);
      if (mounted) showMessage(context, result);
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider)!;
    final events = ref.watch(eventsProvider);
    final venue = ref.watch(venueProvider).value;
    final zone = session.venue.timeZone;
    final now = DateTime.now().toUtc();
    final day = DateFormat('EEEE, MMMM d');
    final time = DateFormat('h:mm a');

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async => ref.invalidate(eventsProvider),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 48),
            children: [
              ScreenHeader(
                kicker: session.venue.name,
                title: 'Events',
                actions: [
                  if (session.canVenueWide(Perm.manageEvents))
                    TextButton.icon(
                      onPressed: _syncing ? null : _sync,
                      icon: _syncing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.sync),
                      label: const Text('Sync from Premium Command'),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                child: SegmentedButton<bool>(
                  segments: const [ButtonSegment(value: false, label: Text('Upcoming')), ButtonSegment(value: true, label: Text('Past'))],
                  selected: {_past},
                  onSelectionChanged: (v) => setState(() => _past = v.first),
                ),
              ),
              ...events.when(
                loading: () => [const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))],
                error: (e, _) => [ErrorNote(e, onRetry: () => ref.invalidate(eventsProvider))],
                data: (all) {
                  final shown = [
                    for (final e in all)
                      if (_past
                          ? (e.endTime ?? e.startTime.add(const Duration(hours: 3))).isBefore(now.subtract(const Duration(hours: 3)))
                          : !(e.endTime ?? e.startTime.add(const Duration(hours: 3))).isBefore(now.subtract(const Duration(hours: 3))))
                        e,
                  ];
                  if (_past) shown.sort((a, b) => b.startTime.compareTo(a.startTime));
                  if (shown.isEmpty) return [const EmptyNote('No events.')];
                  final byDay = <String, List<Event>>{};
                  for (final e in shown) {
                    byDay.putIfAbsent(day.format(atVenue(e.startTime, zone)), () => []).add(e);
                  }
                  return [
                    for (final entry in byDay.entries) ...[
                      SectionHeading(entry.key),
                      for (final e in entry.value)
                        ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                          title: Text(e.name),
                          subtitle: Text(
                            'Call ${time.format(atVenue(e.callTime, zone))} · Doors ${time.format(atVenue(e.doorsTime, zone))} · '
                            'Start ${time.format(atVenue(e.startTime, zone))}\n'
                            '${venue?.eventTypes[e.eventTypeCode] ?? e.eventTypeCode} · '
                            '${NumberFormat.decimalPattern().format(e.actualAttendance ?? e.expectedAttendance)} '
                            '${e.actualAttendance != null ? 'attended' : 'expected'}'
                            '${e.source == 'premium_command' ? ' · from Premium Command' : ''}',
                          ),
                          isThreeLine: true,
                          trailing: StatusTag(eventStatusLabel(e.status), eventStatusTone(e.status)),
                          onTap: () => context.go('/events/${e.id}'),
                        ),
                    ],
                  ];
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
