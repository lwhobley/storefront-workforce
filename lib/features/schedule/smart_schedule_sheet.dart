import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/shift_market_repository.dart';
import 'schedule_actions.dart';

/// Shows the AI-optimized schedule proposals for the event.
Future<void> showSmartScheduleSheet(BuildContext context, WidgetRef ref, String eventId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.90,
      child: SmartScheduleSheet(eventId: eventId),
    ),
  );
}

class SmartScheduleSheet extends ConsumerStatefulWidget {
  const SmartScheduleSheet({super.key, required this.eventId});

  final String eventId;

  @override
  ConsumerState<SmartScheduleSheet> createState() => _SmartScheduleSheetState();
}

class _SmartScheduleSheetState extends ConsumerState<SmartScheduleSheet> {
  bool _strictOvertimeCap = true;
  bool _preferRegular = true;
  bool _balanceWorkload = true;
  bool _rotateStorefronts = true;

  late Future<ScheduleOptimizationPlan> _planFuture = _loadPlan();
  final Set<String> _deselectedShiftIds = {};
  bool _applying = false;

  SmartSchedulerConstraints get _currentConstraints => SmartSchedulerConstraints(
        strictOvertimeCap: _strictOvertimeCap,
        preferRegularStaff: _preferRegular,
        balanceWorkload: _balanceWorkload,
        rotateStorefronts: _rotateStorefronts,
      );

  Future<ScheduleOptimizationPlan> _loadPlan() {
    final repo = ref.read(repositoryProvider);
    if (repo is ShiftMarketRepository) {
      return (repo as ShiftMarketRepository).generateSmartSchedule(
        widget.eventId,
        constraints: _currentConstraints,
      );
    }
    throw const AppFailure('Smart scheduling is not supported in this repository mode');
  }

  void _recalculate() {
    setState(() {
      _deselectedShiftIds.clear();
      _planFuture = _loadPlan();
    });
  }

  Future<void> _apply(ScheduleOptimizationPlan plan) async {
    final selectedProposals = plan.proposals.where((p) => !_deselectedShiftIds.contains(p.shiftId)).toList();
    if (selectedProposals.isEmpty) {
      showMessage(context, 'No assignments selected.');
      return;
    }

    setState(() => _applying = true);
    try {
      final repo = ref.read(repositoryProvider) as ShiftMarketRepository;
      final count = await repo.applySmartSchedule(widget.eventId, selectedProposals);
      ref.invalidate(boardProvider(widget.eventId));
      if (mounted) {
        Navigator.pop(context);
        showMessage(context, 'AI Schedule applied: $count positions filled.');
      }
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, AppSpace.s),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome, color: AppColors.accent, size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('AI Smart Schedule', style: AppText.sectionHeading),
                    const Text(
                      'Optimizes open positions based on availability, rotation, and overtime prevention.',
                      style: TextStyle(fontSize: 12, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Close',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Settings Toggles Bar
        Container(
          color: AppColors.surface,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen, vertical: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                FilterChip(
                  label: const Text('Strict OT Cap (40h)'),
                  avatar: Icon(Icons.shield_outlined, size: 16, color: _strictOvertimeCap ? AppColors.accent : null),
                  selected: _strictOvertimeCap,
                  onSelected: (v) {
                    setState(() => _strictOvertimeCap = v);
                    _recalculate();
                  },
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('Storefront Rotation'),
                  avatar: Icon(Icons.sync_alt, size: 16, color: _rotateStorefronts ? AppColors.accent : null),
                  selected: _rotateStorefronts,
                  onSelected: (v) {
                    setState(() => _rotateStorefronts = v);
                    _recalculate();
                  },
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('Workload Balance'),
                  avatar: Icon(Icons.balance, size: 16, color: _balanceWorkload ? AppColors.accent : null),
                  selected: _balanceWorkload,
                  onSelected: (v) {
                    setState(() => _balanceWorkload = v);
                    _recalculate();
                  },
                ),
                const SizedBox(width: 8),
                FilterChip(
                  label: const Text('Staff First'),
                  selected: _preferRegular,
                  onSelected: (v) {
                    setState(() => _preferRegular = v);
                    _recalculate();
                  },
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: FutureBuilder<ScheduleOptimizationPlan>(
            future: _planFuture,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('Analyzing availability, workweek hours & rotation...'),
                    ],
                  ),
                );
              }
              if (snap.hasError) {
                return ErrorNote(snap.error!, onRetry: _recalculate);
              }
              final plan = snap.data!;
              if (plan.totalOpenPositions == 0) {
                return const EmptyNote('No open positions to fill for this event.');
              }

              final activeProposals = plan.proposals.where((p) => !_deselectedShiftIds.contains(p.shiftId)).toList();

              return Column(
                children: [
                  // Metric Tiles Header
                  Padding(
                    padding: const EdgeInsets.all(AppSpace.screen),
                    child: Row(
                      children: [
                        Expanded(
                          child: _MetricCard(
                            label: 'Filled',
                            value: '${plan.filledCount}/${plan.totalOpenPositions}',
                            subtitle: plan.unfilledShiftIds.isEmpty ? 'All filled' : '${plan.unfilledShiftIds.length} unfilled',
                            tone: plan.unfilledShiftIds.isEmpty ? Tone.good : Tone.warn,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _MetricCard(
                            label: 'OT Avoided',
                            value: '${plan.overtimeHoursAvoided}h',
                            subtitle: plan.projectedOvertimeHours == 0.0 ? '0h overtime' : '${plan.projectedOvertimeHours}h OT',
                            tone: plan.projectedOvertimeHours == 0.0 ? Tone.good : Tone.bad,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _MetricCard(
                            label: 'Rotation Index',
                            value: '${plan.rotationScorePercentage}%',
                            subtitle: 'Variety & rest',
                            tone: plan.rotationScorePercentage >= 80 ? Tone.good : Tone.idle,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: plan.proposals.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final p = plan.proposals[i];
                        final isSelected = !_deselectedShiftIds.contains(p.shiftId);
                        return CheckboxListTile(
                          value: isSelected,
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _deselectedShiftIds.remove(p.shiftId);
                              } else {
                                _deselectedShiftIds.add(p.shiftId);
                              }
                            });
                          },
                          secondary: _ScorePill(score: p.fitScore),
                          title: Row(
                            children: [
                              Text(p.workerName, style: const TextStyle(fontWeight: FontWeight.w600)),
                              const SizedBox(width: 6),
                              StatusTag(workerTypeLabel(p.workerType), p.workerType == WorkerType.regular ? Tone.idle : Tone.info),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 2),
                              Text('${p.jobRoleName} at ${p.storefrontName}', style: const TextStyle(fontWeight: FontWeight.w500)),
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 4,
                                runSpacing: 4,
                                children: [
                                  for (final r in p.reasons)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: AppColors.goodSoft,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(r, style: const TextStyle(fontSize: 10, color: AppColors.good, fontWeight: FontWeight.w600)),
                                    ),
                                  for (final w in p.warnings)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: AppColors.warnSoft,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(w, style: const TextStyle(fontSize: 10, color: AppColors.warn, fontWeight: FontWeight.w600)),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  // Bottom Bar with Apply Button
                  Container(
                    padding: const EdgeInsets.all(AppSpace.screen),
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2))],
                    ),
                    child: SafeArea(
                      top: false,
                      child: Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _applying || activeProposals.isEmpty ? null : () => _apply(plan),
                              icon: _applying
                                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                  : const Icon(Icons.check_circle_outline),
                              label: Text(_applying ? 'Applying assignments...' : 'Apply ${activeProposals.length} Assignments'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.subtitle,
    required this.tone,
  });

  final String label;
  final String value;
  final String subtitle;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final bg = switch (tone) {
      Tone.good => AppColors.goodSoft,
      Tone.warn => AppColors.warnSoft,
      Tone.bad => AppColors.badSoft,
      Tone.idle || Tone.info => AppColors.surface,
    };
    final fg = switch (tone) {
      Tone.good => AppColors.good,
      Tone.warn => AppColors.warn,
      Tone.bad => AppColors.bad,
      Tone.idle || Tone.info => AppColors.text,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.muted, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: fg)),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(fontSize: 10, color: fg), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

class _ScorePill extends StatelessWidget {
  const _ScorePill({required this.score});

  final int score;

  @override
  Widget build(BuildContext context) {
    final good = score >= 80;
    final warn = score >= 50 && score < 80;
    final color = good ? AppColors.good : (warn ? AppColors.warn : AppColors.bad);
    final bg = good ? AppColors.goodSoft : (warn ? AppColors.warnSoft : AppColors.badSoft);

    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        '$score',
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: color),
      ),
    );
  }
}
