import 'package:flutter/material.dart';

import '../../core/widgets/common.dart';

/// Pickups, drops, and swaps waiting for a manager. (Phase 3, placeholder until built.)
class RequestsScreen extends StatelessWidget {
  const RequestsScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: SafeArea(child: Column(children: [ScreenHeader(title: 'Requests'), EmptyNote('Coming in Phase 3.')])),
      );
}
