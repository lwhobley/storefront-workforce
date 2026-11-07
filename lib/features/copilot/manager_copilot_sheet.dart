import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../live/live_model.dart';

/// Shows the Manager Copilot AI assistant bottom sheet.
Future<void> showManagerCopilotSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const FractionallySizedBox(
      heightFactor: 0.85,
      child: ManagerCopilotSheet(),
    ),
  );
}

class ManagerCopilotSheet extends ConsumerStatefulWidget {
  const ManagerCopilotSheet({super.key});

  @override
  ConsumerState<ManagerCopilotSheet> createState() => _ManagerCopilotSheetState();
}

class _ManagerCopilotSheetState extends ConsumerState<ManagerCopilotSheet> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final List<({bool isUser, String text, List<CopilotActionPill> pills, List<String> followUps})> _messages = [];
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _messages.add((
      isUser: false,
      text: '''
Hello! I am your **Storefront Workforce AI Copilot**.
I can answer operational questions, monitor concourse breaks, audit state certifications, and analyze event labor budgets in real time.
''',
      pills: const [
        CopilotActionPill(label: 'Live Concourse', route: '/live', iconName: 'sensors'),
        CopilotActionPill(label: 'Events', route: '/events', iconName: 'event'),
      ],
      followUps: const [
        'Who is on break right now?',
        'How many open shifts are there tonight?',
        'Check expiring certifications',
        'What is the labor budget?',
      ],
    ));
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _ask(String query) {
    if (query.trim().isEmpty) return;
    final text = query.trim();
    _inputController.clear();

    setState(() {
      _messages.add((isUser: true, text: text, pills: const [], followUps: const []));
    });

    final venue = ref.read(venueProvider).value;
    final currentEvent = ref.read(currentEventProvider);
    final board = currentEvent == null ? null : ref.read(boardProvider(currentEvent.id)).value;
    final workers = [for (final w in (ref.read(workersProvider).value ?? const <Worker>[])) w];
    final shifts = board?.shifts ?? const <Shift>[];

    final resp = ManagerCopilotAI.ask(
      query: text,
      liveEvent: currentEvent,
      shifts: shifts,
      workers: workers,
      punches: board?.punches ?? const [],
      storefronts: {for (final s in (venue?.storefronts ?? const <Storefront>[])) s.id: s},
      jobRoles: {for (final r in (venue?.jobRoles ?? const <JobRole>[])) r.code: r},
      onDate: DateTime.now().toUtc(),
    );

    setState(() {
      _messages.add((
        isUser: false,
        text: resp.answer,
        pills: resp.actionPills,
        followUps: resp.suggestedFollowUps,
      ));
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    if (!_initialized && session != null) {
      _initialized = true;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.auto_awesome, color: AppColors.good, size: 22),
            SizedBox(width: 8),
            Text('Manager AI Copilot'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Clear chat',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {
                _messages.clear();
                _messages.add((
                  isUser: false,
                  text: 'Chat history cleared. How can I help you manage tonight\'s event?',
                  pills: const [],
                  followUps: const [
                    'Who is on break right now?',
                    'How many open shifts are there tonight?',
                  ],
                ));
              });
            },
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(AppSpace.m),
                itemCount: _messages.length,
                itemBuilder: (context, idx) {
                  final msg = _messages[idx];
                  if (msg.isUser) {
                    return Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 12, left: 48),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppColors.good,
                          borderRadius: BorderRadius.circular(16).copyWith(bottomRight: Radius.zero),
                        ),
                        child: Text(
                          msg.text,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ),
                    );
                  }

                  return Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 16, right: 32),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.raised,
                        borderRadius: BorderRadius.circular(16).copyWith(topLeft: Radius.zero),
                        border: Border.all(color: AppColors.divider),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(msg.text.trim(), style: AppText.body),
                          if (msg.pills.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final p in msg.pills)
                                  ActionChip(
                                    avatar: Icon(_iconFor(p.iconName), size: 16),
                                    label: Text(p.label),
                                    onPressed: () {
                                      Navigator.pop(context);
                                      context.go(p.route);
                                    },
                                  ),
                              ],
                            ),
                          ],
                          if (msg.followUps.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            const Text('Suggested queries:', style: AppText.kicker),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final f in msg.followUps)
                                  ActionChip(
                                    label: Text(f),
                                    onPressed: () => _ask(f),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.all(AppSpace.m),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppColors.divider)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputController,
                      decoration: const InputDecoration(
                        hintText: 'Ask Copilot (e.g., breaks, certs, open shifts, budget)...',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      ),
                      onSubmitted: _ask,
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                    icon: const Icon(Icons.send, size: 18),
                    label: const Text('Ask'),
                    onPressed: () => _ask(_inputController.text),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(String name) => switch (name) {
        'sensors' => Icons.sensors,
        'event' => Icons.event,
        'badge' => Icons.badge_outlined,
        'task_alt' => Icons.task_alt,
        'payments' => Icons.payments_outlined,
        'insights' => Icons.insights_outlined,
        'calendar_month' => Icons.calendar_month_outlined,
        'swap_horiz' => Icons.swap_horiz,
        _ => Icons.arrow_forward,
      };
}
