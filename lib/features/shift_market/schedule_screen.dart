import 'package:flutter/material.dart';

import '../../core/widgets/common.dart';

/// Your shifts, open shifts to pick up, swaps, and availability. (Phase 3, placeholder until built.)
class ScheduleScreen extends StatelessWidget {
  const ScheduleScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: SafeArea(child: Column(children: [ScreenHeader(title: 'Schedule'), EmptyNote('Coming in Phase 3.')])),
      );
}
