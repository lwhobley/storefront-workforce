import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/shift_market_repository.dart';

ShiftMarketRepository marketRepo(Ref ref) => ref.read(repositoryProvider) as ShiftMarketRepository;

final openShiftsProvider = FutureProvider.autoDispose<List<OpenShift>>((ref) {
  if (ref.watch(sessionProvider) == null) return const [];
  return marketRepo(ref).openShiftsForMe();
});

final myRequestsProvider = FutureProvider.autoDispose<List<ShiftRequest>>((ref) {
  if (ref.watch(sessionProvider) == null) return const [];
  return marketRepo(ref).myShiftRequests();
});

final myAvailabilityProvider = FutureProvider.autoDispose<MyAvailability>((ref) {
  if (ref.watch(sessionProvider) == null) return const MyAvailability(events: [], blackouts: []);
  return marketRepo(ref).myAvailability();
});

/// The manager's queue: open requests, or (true) recent decided ones.
final reviewRequestsProvider = FutureProvider.autoDispose.family<List<ShiftRequest>, bool>((ref, history) {
  if (ref.watch(sessionProvider) == null) return const [];
  return marketRepo(ref).reviewShiftRequests(history: history);
});

/// Reloads everything the schedule screen shows after a change.
void refreshMarket(WidgetRef ref) {
  ref.invalidate(openShiftsProvider);
  ref.invalidate(myRequestsProvider);
  ref.invalidate(myAvailabilityProvider);
  ref.invalidate(reviewRequestsProvider);
  ref.invalidate(myDayProvider);
}
