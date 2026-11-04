import 'package:flutter/material.dart';

import '../../core/widgets/common.dart';

/// Message a storefront, a level, or everyone, and manage announcements. (Phase 3, placeholder until built.)
class MessagesScreen extends StatelessWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: SafeArea(child: Column(children: [ScreenHeader(title: 'Messages'), EmptyNote('Coming in Phase 3.')])),
      );
}
