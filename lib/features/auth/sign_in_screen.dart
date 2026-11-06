import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/demo_repository.dart';
import '../../data/models.dart';

/// PIN-only sign-in for everyone: staff, managers, partner contacts, and kiosks.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _submit(String pin) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).signIn(pin);
    } on AppFailure catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Sign-in failed. Check your connection.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final isDemo = ref.watch(repositoryProvider).isDemo;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpace.xl),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(onPressed: () => ref.read(languageProvider.notifier).toggle(), child: Text(t.language)),
                ),
                // The logo carries the app name, so it replaces the name line.
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.asset(
                    'assets/branding/logo.jpg',
                    width: 168,
                    semanticLabel: t.appName,
                    errorBuilder: (_, _, _) => Text(t.appName.toUpperCase(), style: AppText.kicker),
                  ),
                ),
                const SizedBox(height: AppSpace.l),
                Text(t.enterPin, style: AppText.screenTitle, textAlign: TextAlign.center),
                const SizedBox(height: 6),
                Text(t.pinHelp, style: AppText.meta, textAlign: TextAlign.center),
                const SizedBox(height: AppSpace.xl),
                PinPad(onComplete: _submit, busy: _busy, error: _error, clearLabel: t.clear),
                if (isDemo) ...[
                  const SizedBox(height: AppSpace.xxl),
                  const _DemoPersonas(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DemoPersonas extends ConsumerWidget {
  const _DemoPersonas();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.l),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('DEMO MODE', style: AppText.kicker),
              const SizedBox(height: 4),
              const Text(
                'Fictional Pecan Valley Arena, with a game live right now. Tap a role to sign in as it. Nothing is saved.',
                style: AppText.meta,
              ),
              const SizedBox(height: AppSpace.m),
              for (final p in DemoWorkforceRepository.personas)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(p.label),
                  subtitle: Text('${p.description} · PIN ${p.pin}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    try {
                      await ref.read(sessionProvider.notifier).signIn(p.pin);
                    } on AppFailure catch (e) {
                      if (context.mounted) showMessage(context, e.message);
                    }
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}
