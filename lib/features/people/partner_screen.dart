import 'package:flutter/material.dart';

import '../../core/widgets/common.dart';

/// Your group or agency: people, hours, and payouts. (Phase 3, placeholder until built.)
class PartnerScreen extends StatelessWidget {
  const PartnerScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
        body: SafeArea(child: Column(children: [ScreenHeader(title: 'Partner'), EmptyNote('Coming in Phase 3.')])),
      );
}
