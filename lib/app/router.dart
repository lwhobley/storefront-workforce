import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/models.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/clock/clock_screen.dart';
import '../features/events/event_calendar_screen.dart';
import '../features/events/event_screen.dart';
import '../features/kiosk/kiosk_screen.dart';
import '../features/staff/staff_screen.dart';
import 'more_screen.dart';
import 'providers.dart';

class NavItem {
  const NavItem(this.path, this.label, this.icon);

  final String path;
  final String label;
  final IconData icon;
}

/// Sections a person sees, by role. Employees get a single clock screen.
List<NavItem> navFor(AppSession s) => [
      if (s.can(Perm.viewLive)) const NavItem('/live', 'Live', Icons.sensors),
      if (s.isManagerView) const NavItem('/events', 'Events', Icons.event),
      if (s.can(Perm.viewWorkers)) const NavItem('/staff', 'Staff', Icons.badge_outlined),
      if (s.workerId != null) const NavItem('/clock', 'My shift', Icons.punch_clock_outlined),
      const NavItem('/more', 'More', Icons.menu),
    ];

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
          GoRoute(path: '/events/:id', builder: (_, state) => EventScreen(eventId: state.pathParameters['id']!)),
          GoRoute(path: '/staff', builder: (_, _) => const StaffScreen()),
          GoRoute(path: '/clock', builder: (_, _) => const ClockScreen()),
          GoRoute(path: '/more', builder: (_, _) => const MoreScreen()),
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
    final items = navFor(session);
    if (items.length < 2) return child;
    final section = '/${location.split('/')[1]}';
    final index = items.indexWhere((i) => i.path == section).clamp(0, items.length - 1);
    void go(int i) => context.go(items[i].path);

    final wide = MediaQuery.sizeOf(context).width >= 840;
    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: index,
            onDestinationSelected: go,
            labelType: NavigationRailLabelType.all,
            destinations: [for (final i in items) NavigationRailDestination(icon: Icon(i.icon), label: Text(i.label))],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ]),
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
