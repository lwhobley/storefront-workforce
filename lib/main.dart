import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/app.dart';
import 'app/providers.dart';
import 'data/demo_repository.dart';
import 'data/supabase_repository.dart';
import 'data/workforce_repository.dart';

// Run with a backend:
//   flutter run --dart-define=SUPABASE_URL=https://<ref>.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=<key>
// Run without one (demo mode, sample arena in memory):
//   flutter run
// On the web, adding ?demo to the address opens demo mode even when a backend is set.
const _url = String.fromEnvironment('SUPABASE_URL');
const _key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  WorkforceRepository repo;
  final demoRequested = kIsWeb && Uri.base.queryParameters.containsKey('demo');
  if (_url.isNotEmpty && _key.isNotEmpty && !demoRequested) {
    await Supabase.initialize(url: _url, publishableKey: _key);
    repo = SupabaseWorkforceRepository(Supabase.instance.client);
  } else {
    repo = DemoWorkforceRepository();
  }
  final container = ProviderContainer(overrides: [repositoryProvider.overrideWithValue(repo)]);
  await container.read(sessionProvider.notifier).restore();
  runApp(UncontrolledProviderScope(container: container, child: const WorkforceApp()));
}
