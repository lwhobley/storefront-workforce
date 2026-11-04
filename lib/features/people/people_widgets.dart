import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/people_repository.dart';
import 'people_providers.dart';

final _filesProvider = FutureProvider.autoDispose.family<Uint8List?, String>((ref, path) => peopleRepo(ref).downloadOnboardingFile(path));

/// An uploaded card photo, or a stand-in when the file cannot be shown.
class CardPhoto extends ConsumerWidget {
  const CardPhoto({super.key, required this.path, this.label = '', this.height = 180});

  final String path;
  final String label;
  final double height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(_filesProvider(path));
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: height,
        width: height * 1.58,
        child: bytes.when(
          loading: () => const ColoredBox(color: AppColors.surface, child: Center(child: CircularProgressIndicator())),
          error: (_, _) => _CardStandIn(label: label),
          data: (b) => b == null
              ? _CardStandIn(label: label)
              : InkWell(
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (context) => Dialog(child: InteractiveViewer(child: Image.memory(b, fit: BoxFit.contain))),
                  ),
                  child: Image.memory(b, fit: BoxFit.cover),
                ),
        ),
      ),
    );
  }
}

class _CardStandIn extends StatelessWidget {
  const _CardStandIn({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF2F5D7C), Color(0xFF4F86A6)]),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.badge_outlined, color: Colors.white, size: 28),
            const Spacer(),
            Text(label.isEmpty ? 'Card photo' : label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            const Text('Photo on file (preview not available here)', style: TextStyle(color: Colors.white70, fontSize: 11)),
          ],
        ),
      );
}

/// A labeled progress bar for onboarding.
class OnboardingBar extends StatelessWidget {
  const OnboardingBar({super.key, required this.state, this.compact = false});

  final OnboardingState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = state.finished
        ? AppColors.good
        : state.needsReview
            ? AppColors.warn
            : Theme.of(context).colorScheme.primary;
    return Semantics(
      label: '${state.done} of ${state.required} steps done',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: state.required == 0 ? 1 : state.done / state.required,
          minHeight: compact ? 6 : 10,
          color: color,
          backgroundColor: AppColors.idleSoft,
        ),
      ),
    );
  }
}

Tone stepTone(StepStatus s) => switch (s) {
      StepStatus.complete || StepStatus.approved => Tone.good,
      StepStatus.submitted => Tone.warn,
      StepStatus.needsChanges => Tone.bad,
      StepStatus.notStarted => Tone.idle,
    };

IconData stepIcon(StepStatus s) => switch (s) {
      StepStatus.complete || StepStatus.approved => Icons.check_circle,
      StepStatus.submitted => Icons.hourglass_top,
      StepStatus.needsChanges => Icons.error_outline,
      StepStatus.notStarted => Icons.radio_button_unchecked,
    };

/// Expiry state of a certification on [day].
CertificationState certState(DateTime? expiresOn, DateTime day, CertificationRules rules) {
  if (expiresOn == null) return CertificationState.ok;
  if (expiresOn.isBefore(day)) return CertificationState.expired;
  if (expiresOn.difference(day).inDays <= rules.expiringSoonDays) return CertificationState.expiringSoon;
  return CertificationState.ok;
}

final shortDate = DateFormat('MMM d, y');
