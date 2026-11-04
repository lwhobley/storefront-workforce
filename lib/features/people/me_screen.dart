import 'package:flutter/material.dart';

import '../../core/widgets/common.dart';

/// Your hours, tips, and onboarding checklist. (Phase 3, placeholder until built.)
class MeScreen extends StatelessWidget {
  const MeScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: SafeArea(child: Column(children: [ScreenHeader(title: 'Me'), EmptyNote('Coming in Phase 3.')])),
      );
}
