part of '../demo_repository.dart';

/// Demo (in-memory) implementation of [PerformanceRepository].
mixin _DemoPerformance on _DemoCore implements PerformanceRepository {
  @override
  Future<void> performanceReady(AppSession session) async {}
}
