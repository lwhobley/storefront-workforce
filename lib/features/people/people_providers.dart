import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/people_repository.dart';

PeopleRepository peopleRepo(Ref ref) => ref.read(repositoryProvider) as PeopleRepository;

/// Own time records for the last ~4 months (a few pay periods).
final myHoursProvider = FutureProvider.autoDispose<MyHoursData>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) throw StateError('Not signed in');
  final now = DateTime.now().toUtc();
  return peopleRepo(ref).loadMyHours(session, now.subtract(const Duration(days: 130)), now.add(const Duration(days: 1)));
});

final myTipsProvider = FutureProvider.autoDispose<List<MyTip>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  return peopleRepo(ref).loadMyTips(session);
});

final myOnboardingProvider = FutureProvider.autoDispose<OnboardingState>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) throw StateError('Not signed in');
  return peopleRepo(ref).myOnboarding(session);
});

/// A person's certifications with whether a manager checked them.
final certsProvider = FutureProvider.autoDispose.family<List<CertRecord>, String>((ref, workerId) => peopleRepo(ref).workerCertifications(workerId));

final onboardingOverviewProvider = FutureProvider.autoDispose<List<OnboardingState>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  return peopleRepo(ref).onboardingOverview(session);
});

final workerOnboardingProvider = FutureProvider.autoDispose.family<OnboardingState, String>((ref, workerId) => peopleRepo(ref).workerOnboarding(workerId));

final onboardingDocumentsProvider = FutureProvider.autoDispose<List<OnboardingDocument>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session == null) return const [];
  return peopleRepo(ref).listOnboardingDocuments(session);
});

extension PeopleRepoOnWidgetRef on WidgetRef {
  PeopleRepository get people => read(repositoryProvider) as PeopleRepository;
}
