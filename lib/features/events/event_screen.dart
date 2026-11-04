import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../live/live_view.dart';
import '../schedule/schedule_view.dart';
import 'event_calendar_screen.dart';

/// One event: the live board with the arena map, and the schedule builder.
class EventScreen extends ConsumerWidget {
  const EventScreen({super.key, required this.eventId, this.initialTab});

  final String eventId;

  /// 0 = Live, 1 = Schedule. When null, Live during the event and Schedule before it.
  final int? initialTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boardAsync = ref.watch(boardProvider(eventId));
    final session = ref.watch(sessionProvider)!;
    return boardAsync.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(appBar: AppBar(), body: ErrorNote(e, onRetry: () => ref.invalidate(boardProvider(eventId)))),
      data: (board) {
        final e = board.event;
        final zone = board.timeZone;
        final now = DateTime.now().toUtc();
        final during = !now.isBefore(e.callTime.subtract(const Duration(hours: 2))) && e.status != EventStatus.completed;
        final scope = session.canVenueWide('view_live') ? '' : ' · your storefronts only';
        return DefaultTabController(
          length: 2,
          initialIndex: initialTab ?? (during ? 0 : 1),
          child: Scaffold(
            body: SafeArea(
              child: NestedScrollView(
                headerSliverBuilder: (context, _) => [
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(left: 8, top: 4),
                          child: TextButton.icon(
                            onPressed: () => context.canPop() ? context.pop() : context.go('/events'),
                            icon: const Icon(Icons.arrow_back),
                            label: const Text('Events'),
                          ),
                        ),
                        ScreenHeader(
                          kicker: DateFormat('EEEE, MMMM d').format(atVenue(e.startTime, zone)),
                          title: e.name,
                          subtitle: 'Start ${DateFormat('h:mm a').format(atVenue(e.startTime, zone))} · '
                              '${NumberFormat.decimalPattern().format(e.expectedAttendance)} expected$scope',
                          actions: [StatusTag(eventStatusLabel(e.status), eventStatusTone(e.status))],
                        ),
                      ],
                    ),
                  ),
                  const SliverToBoxAdapter(
                    child: TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      padding: EdgeInsets.symmetric(horizontal: AppSpace.m),
                      tabs: [Tab(text: 'Live'), Tab(text: 'Schedule')],
                    ),
                  ),
                ],
                body: TabBarView(children: [LiveView(board: board), ScheduleView(board: board)]),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Opens the current event's live board, or says there is none.
class LiveShortcutScreen extends ConsumerWidget {
  const LiveShortcutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final events = ref.watch(eventsProvider);
    final current = ref.watch(currentEventProvider);
    if (events.isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (current == null) {
      return const Scaffold(body: SafeArea(child: Column(children: [ScreenHeader(title: 'Live'), EmptyNote('No event today.')])));
    }
    return EventScreen(eventId: current.id, initialTab: 0);
  }
}
