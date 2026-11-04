import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/models.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/clock/clock_screen.dart';
import '../features/comms/inbox_screen.dart';
import '../features/comms/messages_screen.dart';
import '../features/events/event_calendar_screen.dart';
import '../features/events/event_screen.dart';
import '../features/kiosk/kiosk_screen.dart';
import '../features/pay/pay_period_screen.dart';
import '../features/pay/pay_screen.dart';
import '../features/people/me_screen.dart';
import '../features/people/onboarding_screen.dart';
import '../features/people/partner_screen.dart';
import '../features/shift_market/requests_screen.dart';
import '../features/shift_market/schedule_screen.dart';
import '../features/performance/rankings_screen.dart';
import '../features/staff/staff_screen.dart';
import '../features/operations/checklists_screen.dart';
import '../features/operations/incidents_screen.dart';
import '../features/operations/ops_queue.dart';
import '../features/reports/event_report_screen.dart';
import '../features/reports/reports_screen.dart';
import 'more_screen.dart';
import 'providers.dart';

class NavItem {
  const NavItem(this.path, this.label, this.icon);

  final String path;
  final String label;
  final IconData icon;
}

/// Sections a person sees, by role, in order. On phones the first four show in the
/// bottom bar and the rest are listed under More.
List<NavItem> navFor(AppSession s) {
  final partner = !s.isManagerView && s.workerId == null && (s.can('npo_portal') || s.can('agency_portal'));
  return [
    if (s.can(Perm.viewLive)) const NavItem('/live', 'Live', Icons.sensors),
    if (s.isManagerView) const NavItem('/events', 'Events', Icons.event),
    if (s.workerId != null && !s.isManagerView) ...[
      const NavItem('/clock', 'My shift', Icons.punch_clock_outlined),
      const NavItem('/schedule', 'Schedule', Icons.calendar_month_outlined),
    ],
    if (partner) const NavItem('/partner', 'My group', Icons.groups_outlined),
    const NavItem('/inbox', 'Inbox', Icons.inbox_outlined),
    if (s.workerId != null && !s.isManagerView) const NavItem('/me', 'Me', Icons.person_outline),
    if (s.can(Perm.manageSchedule)) const NavItem('/requests', 'Requests', Icons.swap_horiz),
    if (s.can(Perm.viewWorkers)) const NavItem('/staff', 'Staff', Icons.badge_outlined),
    if (s.canVenueWide('view_pay')) const NavItem('/pay', 'Pay', Icons.payments_outlined),
    if (s.canVenueWide(Perm.manageWorkers)) const NavItem('/onboarding', 'Onboarding', Icons.task_alt),
    if (s.isManagerView) const NavItem('/messages', 'Messages', Icons.campaign_outlined),
    if (s.can(Perm.viewReports)) const NavItem('/reports', 'Reports', Icons.insights_outlined),
    if (s.isManagerView) const NavItem('/checklists', 'Checklists', Icons.checklist),
    if (s.isManagerView) const NavItem('/incidents', 'Incidents', Icons.report_outlined),
    if (s.workerId != null && s.isManagerView) ...[
      const NavItem('/clock', 'My shift', Icons.punch_clock_outlined),
      const NavItem('/schedule', 'My schedule', Icons.calendar_month_outlined),
      const NavItem('/me', 'Me', Icons.person_outline),
    ],
    const NavItem('/more', 'More', Icons.menu),
  ];
}

String homeFor(AppSession s) {
  if (s.isKiosk) return '/kiosk';
  return navFor(s).first.path;
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(sessionProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final loc = state.matchedLocation;
      if (session == null) return loc == '/sign-in' ? null : '/sign-in';
      if (session.isKiosk) return loc == '/kiosk' ? null : '/kiosk';
      if (loc == '/sign-in' || loc == '/' || loc == '/kiosk') return homeFor(session);
      final allowed = navFor(session).map((n) => n.path).toSet();
      final section = '/${loc.split('/')[1]}';
      if (section == '/events' && !session.isManagerView) return homeFor(session);
      if (section != '/events' && !allowed.contains(section)) return homeFor(session);
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SizedBox.shrink()),
      GoRoute(path: '/sign-in', builder: (_, _) => const SignInScreen()),
      GoRoute(path: '/kiosk', builder: (_, _) => const KioskScreen()),
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(path: '/live', builder: (_, _) => const LiveShortcutScreen()),
          GoRoute(path: '/events', builder: (_, _) => const EventCalendarScreen()),
          GoRoute(
            path: '/events/:id',
            builder: (_, state) => EventScreen(eventId: state.pathParameters['id']!),
          ),
          GoRoute(path: '/staff', builder: (_, _) => const StaffScreen()),
          GoRoute(path: '/staff/rankings', builder: (_, _) => const RankingsScreen()),
          GoRoute(path: '/pay', builder: (_, _) => const PayScreen()),
          GoRoute(
            path: '/pay/period/:id',
            builder: (_, state) => PayPeriodScreen(periodId: state.pathParameters['id']!),
          ),
          GoRoute(path: '/clock', builder: (_, _) => const ClockScreen()),
          GoRoute(path: '/more', builder: (_, _) => const MoreScreen()),
          GoRoute(path: '/schedule', builder: (_, _) => const ScheduleScreen()),
          GoRoute(path: '/requests', builder: (_, _) => const RequestsScreen()),
          GoRoute(path: '/inbox', builder: (_, _) => const InboxScreen()),
          GoRoute(path: '/messages', builder: (_, _) => const MessagesScreen()),
          GoRoute(path: '/me', builder: (_, _) => const MeScreen()),
          GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
          GoRoute(path: '/partner', builder: (_, _) => const PartnerScreen()),
          GoRoute(path: '/reports', builder: (_, _) => const ReportsScreen()),
          GoRoute(
            path: '/reports/event/:id',
            builder: (_, state) => EventReportScreen(eventId: state.pathParameters['id']!, season: int.tryParse(state.uri.queryParameters['season'] ?? '')),
          ),
          GoRoute(path: '/checklists', builder: (_, _) => const ChecklistsScreen()),
          GoRoute(path: '/incidents', builder: (_, _) => const IncidentsScreen()),
        ],
      ),
    ],
  );
});

/// Bottom bar on phones, side rail on tablets and desktops.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    if (session == null) return child;
    // Keeps the checklist and incident outbox sending in the background on any screen.
    if (session.isManagerView) ref.listen(opsQueueProvider, (_, _) {});
    final all = navFor(session);
    if (all.length < 2) return child;
    final section = '/${location.split('/')[1]}';
    final wide = MediaQuery.sizeOf(context).width >= 840;
    // Phones: four sections plus More; the rest are listed on the More screen.
    final items = wide || all.length <= 5 ? all : [...all.take(4), all.last];
    final found = items.indexWhere((i) => i.path == section);
    final index = found < 0 ? items.length - 1 : found;
    void go(int i) => context.go(items[i].path);

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: index,
              onDestinationSelected: go,
              labelType: NavigationRailLabelType.all,
              destinations: [for (final i in items) NavigationRailDestination(icon: Icon(i.icon), label: Text(i.label))],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: child),
          ],
        ),
      );
    }
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: go,
        destinations: [for (final i in items) NavigationDestination(icon: Icon(i.icon), label: i.label)],
      ),
    );
  }
}
