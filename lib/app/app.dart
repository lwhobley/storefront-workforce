import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/i18n/strings.dart';
import '../core/theme/app_theme.dart';
import '../features/clock/punch_queue.dart';
import 'intro_video.dart';
import 'providers.dart';
import 'router.dart';

class WorkforceApp extends ConsumerWidget {
  const WorkforceApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final session = ref.watch(sessionProvider);
    final lang = ref.watch(languageProvider);
    // Keep the offline punch queue running for the whole session.
    if (session != null) ref.watch(punchQueueProvider);
    final branding = session?.venue.branding ?? const {};
    return MaterialApp.router(
      title: (branding['app_name'] as String?) ?? 'Storefront Workforce',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(accent: brandColor(branding['primary_color'])),
      routerConfig: router,
      locale: Locale(lang),
      supportedLocales: const [Locale('en'), Locale('es')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      // Brand intro over the first screen; sign-in keeps loading underneath.
      builder: (context, child) => IntroGate(child: child ?? const SizedBox.shrink()),
    );
  }
}
