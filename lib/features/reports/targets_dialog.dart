import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/reports_repository.dart';
import 'reports_providers.dart';

/// Edits the venue's targets (manage_settings).
Future<void> showTargetsDialog(BuildContext context, WidgetRef ref, ReportTargets targets) {
  return showDialog<void>(context: context, builder: (_) => _TargetsDialog(targets: targets));
}

class _TargetsDialog extends ConsumerStatefulWidget {
  const _TargetsDialog({required this.targets});

  final ReportTargets targets;

  @override
  ConsumerState<_TargetsDialog> createState() => _TargetsDialogState();
}

class _TargetsDialogState extends ConsumerState<_TargetsDialog> {
  late final _fillGreen = TextEditingController(text: _p(widget.targets.fillGreen));
  late final _fillYellow = TextEditingController(text: _p(widget.targets.fillYellow));
  late final _onTimeGreen = TextEditingController(text: _p(widget.targets.attendanceGreen));
  late final _onTimeYellow = TextEditingController(text: _p(widget.targets.attendanceYellow));
  String? _error;
  bool _busy = false;

  static String _p(double v) {
    final x = v * 100;
    return x == x.roundToDouble() ? x.toStringAsFixed(0) : x.toStringAsFixed(1);
  }

  double? _read(TextEditingController c) {
    final v = double.tryParse(c.text.trim().replaceAll('%', ''));
    return v == null ? null : v / 100;
  }

  @override
  void dispose() {
    for (final c in [_fillGreen, _fillYellow, _onTimeGreen, _onTimeYellow]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final values = [_read(_fillGreen), _read(_fillYellow), _read(_onTimeGreen), _read(_onTimeYellow)];
    if (values.any((v) => v == null)) {
      setState(() => _error = 'Enter each target as a percent, like 95.');
      return;
    }
    final next = widget.targets.copyWith(fillGreen: values[0], fillYellow: values[1], attendanceGreen: values[2], attendanceYellow: values[3]);
    final problem = next.validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = ref.read(sessionProvider)!;
      await (ref.read(repositoryProvider) as ReportsRepository).saveReportTargets(session, next);
      ref.invalidate(reportTargetsProvider);
      if (mounted) {
        Navigator.pop(context);
        showMessage(context, 'Targets saved.');
      }
    } on AppFailure catch (e) {
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  Widget _field(String label, TextEditingController c) => Expanded(
        child: TextField(
          controller: c,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
          decoration: InputDecoration(labelText: label, suffixText: '%'),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Targets'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('At or above green shows green; at or above yellow shows yellow; below that, red.', style: AppText.meta),
              const SizedBox(height: AppSpace.l),
              const Text('Fill rate: positions staffed out of planned', style: TextStyle(fontWeight: FontWeight.w600)),
              Row(children: [_field('Green', _fillGreen), const SizedBox(width: 12), _field('Yellow', _fillYellow)]),
              const SizedBox(height: AppSpace.l),
              const Text('On time: clocked in on time, out of everyone scheduled', style: TextStyle(fontWeight: FontWeight.w600)),
              Row(children: [_field('Green', _onTimeGreen), const SizedBox(width: 12), _field('Yellow', _onTimeYellow)]),
              const SizedBox(height: AppSpace.l),
              Text(
                'Labor budget: at or under budget is green, up to ${(widget.targets.budgetYellowOver * 100).round()}% over is yellow, more is red.',
                style: AppText.meta,
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpace.m),
                Text(_error!, style: const TextStyle(color: AppColors.bad, fontWeight: FontWeight.w600)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
    );
  }
}
