import 'package:flutter/material.dart';

import '../../core/widgets/common.dart';

/// Messages, announcements to acknowledge, and notifications. (Phase 3, placeholder until built.)
class InboxScreen extends StatelessWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: SafeArea(child: Column(children: [ScreenHeader(title: 'Inbox'), EmptyNote('Coming in Phase 3.')])),
      );
}
