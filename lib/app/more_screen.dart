import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/i18n/strings.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/common.dart';
import '../features/clock/punch_queue.dart';
import '../features/copilot/manager_copilot_sheet.dart';
import 'package:go_router/go_router.dart';

import 'providers.dart';
import 'router.dart';

class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider)!;
    final t = ref.watch(stringsProvider);
    final queue = ref.watch(punchQueueProvider);
    final repo = ref.watch(repositoryProvider);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          children: [
            ScreenHeader(kicker: session.venue.name, title: session.displayName, subtitle: session.roleLabel),
            // Sections that do not fit in the phone's bottom bar.
            if (MediaQuery.sizeOf(context).width < 840)
              for (final item in navFor(session).skip(4).where((i) => i.path != '/more'))
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                  leading: Icon(item.icon),
                  title: Text(item.label),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go(item.path),
                ),
            if (session.isManagerView)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                leading: const Icon(Icons.auto_awesome, color: AppColors.good),
                title: const Text('Manager AI Copilot'),
                subtitle: const Text('Operations assistant for concourse breaks, open shifts, certs & budget'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showManagerCopilotSheet(context),
              ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
              leading: const Icon(Icons.translate),
              title: Text(t.language),
              onTap: () => ref.read(languageProvider.notifier).toggle(),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
              leading: const Icon(Icons.cloud_upload_outlined),
              title: Text(queue.pending == 0 ? t.allSent : t.waitingToSend(queue.pending)),
              subtitle: queue.needsReview > 0 ? Text('${queue.needsReview} need a manager: ${queue.lastError}') : null,
              onTap: () => ref.read(punchQueueProvider.notifier).flush(),
            ),
            if (repo.isDemo)
              const ListTile(
                contentPadding: EdgeInsets.symmetric(horizontal: AppSpace.screen),
                leading: Icon(Icons.science_outlined),
                title: Text('Demo mode'),
                subtitle: Text('Fictional Pecan Valley Arena. Changes last until the page is closed.'),
              ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
              leading: const Icon(Icons.logout),
              title: Text(t.signOut),
              onTap: () => ref.read(sessionProvider.notifier).signOut(),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
