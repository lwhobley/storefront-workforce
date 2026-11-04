import 'models.dart';

/// Phase 4: opening and closing checklists per storefront (photo proof, manager
/// sign-off, works offline) and incidents (injuries, safety, employee incidents, with
/// photos and follow-up).
abstract interface class OperationsRepository {
  /// Placeholder so the interface is not empty; replace with the real API.
  Future<void> operationsReady(AppSession session);
}
