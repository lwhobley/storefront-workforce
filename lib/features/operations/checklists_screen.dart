import 'package:flutter/material.dart';

import '../../core/widgets/common.dart';

/// Phase 4 placeholder, replaced as the area is built.
class ChecklistsScreen extends StatelessWidget {
  const ChecklistsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(child: Column(children: [ScreenHeader(title: 'Checklists'), EmptyNote('Coming in Phase 4.')])),
    );
  }
}
