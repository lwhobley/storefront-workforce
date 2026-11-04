import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../data/models.dart';
import '../../data/pay_data.dart';

/// Pay setup, after making sure pay periods exist through two weeks from today.
final paySetupProvider = FutureProvider<PaySetup>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) throw const AppFailure('Not signed in');
  final repo = ref.read(repositoryProvider);
  await repo.ensurePayPeriods(session, DateTime.now().toUtc().add(const Duration(days: 14)));
  return repo.loadPaySetup(session);
});

PayPeriod? findPeriod(PaySetup setup, String id) {
  for (final p in setup.periods) {
    if (p.id == id) return p;
  }
  return null;
}

/// The pay period that contains today, or the newest one.
PayPeriod? currentPeriod(PaySetup setup) {
  final now = DateTime.now().toUtc();
  final today = DateTime.utc(now.year, now.month, now.day);
  for (final p in setup.periods) {
    if (!today.isBefore(p.startsOn) && !today.isAfter(p.endsOn)) return p;
  }
  return setup.periods.isEmpty ? null : setup.periods.first;
}

/// Most recent period whose end has passed: usually the one being paid next.
PayPeriod? lastClosedPeriod(PaySetup setup) {
  final now = DateTime.now().toUtc();
  final today = DateTime.utc(now.year, now.month, now.day);
  for (final p in setup.periods) {
    if (p.endsOn.isBefore(today)) return p;
  }
  return null;
}

final periodDataProvider = FutureProvider.family<PeriodData, String>((ref, periodId) async {
  final session = ref.watch(sessionProvider);
  if (session == null) throw const AppFailure('Not signed in');
  final setup = await ref.watch(paySetupProvider.future);
  final period = findPeriod(setup, periodId);
  if (period == null) throw const AppFailure('Pay period not found');
  return ref.read(repositoryProvider).loadPeriodData(session, period);
});

/// Partner (NPO and temp) work for one pay period's dates.
final partnerDataProvider = FutureProvider.family<PartnerData, String>((ref, periodId) async {
  final session = ref.watch(sessionProvider);
  if (session == null) throw const AppFailure('Not signed in');
  final setup = await ref.watch(paySetupProvider.future);
  final period = findPeriod(setup, periodId);
  if (period == null) throw const AppFailure('Pay period not found');
  return ref.read(repositoryProvider).loadPartnerData(session, period.startsOn, period.endsOn);
});

String periodLabel(PayPeriod p) {
  String d(DateTime x) => '${_months[x.month - 1]} ${x.day}';
  return '${d(p.startsOn)} – ${d(p.endsOn)}, ${p.endsOn.year}';
}

String shortDate(DateTime x) => '${_months[x.month - 1]} ${x.day}';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
