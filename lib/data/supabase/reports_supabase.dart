part of '../supabase_repository.dart';

/// Supabase implementation of [ReportsRepository].
mixin _SupabaseReports on _SupabaseCore implements ReportsRepository {
  @override
  Future<void> reportsReady(AppSession session) async {}
}
