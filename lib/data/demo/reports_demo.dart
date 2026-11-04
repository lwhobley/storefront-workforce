part of '../demo_repository.dart';

/// Demo (in-memory) implementation of [ReportsRepository].
mixin _DemoReports on _DemoCore implements ReportsRepository {
  @override
  Future<void> reportsReady(AppSession session) async {}
}
