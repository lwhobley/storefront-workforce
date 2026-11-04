import 'package:flutter/material.dart';

import '../../core/widgets/common.dart';

/// Who has finished onboarding and what is left. (Phase 3, placeholder until built.)
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: SafeArea(child: Column(children: [ScreenHeader(title: 'Onboarding'), EmptyNote('Coming in Phase 3.')])),
      );
}
