part of '../supabase_repository.dart';

/// Supabase implementation of [PerformanceRepository].
mixin _SupabasePerformance on _SupabaseCore implements PerformanceRepository {
  @override
  Future<void> performanceReady(AppSession session) async {}
}
