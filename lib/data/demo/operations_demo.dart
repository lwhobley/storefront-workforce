part of '../demo_repository.dart';

/// Demo (in-memory) implementation of [OperationsRepository].
mixin _DemoOperations on _DemoCore implements OperationsRepository {
  @override
  Future<void> operationsReady(AppSession session) async {}
}
