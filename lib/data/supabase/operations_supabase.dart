part of '../supabase_repository.dart';

/// Supabase implementation of [OperationsRepository].
mixin _SupabaseOperations on _SupabaseCore implements OperationsRepository {
  @override
  Future<void> operationsReady(AppSession session) async {}
}
