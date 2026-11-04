import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../schedule/schedule_actions.dart';

/// Staff directory with trained roles and certification status. Full profiles and
/// onboarding come in a later phase.
class StaffScreen extends ConsumerStatefulWidget {
  const StaffScreen({super.key});

  @override
  ConsumerState<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends ConsumerState<StaffScreen> {
  String _query = '';
  WorkerType? _type;
  bool _certIssues = false;

  Future<void> _issuePin(Worker w) async {
    final again = w.userId != null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(again ? 'New PIN for ${w.displayName}?' : 'Give ${w.displayName} a sign-in PIN?'),
        content: Text(again
            ? 'Their current PIN stops working. The new PIN is shown once; hand it to them in person.'
            : 'They will sign in and clock in with a 6-digit PIN. It is shown once; hand it to them in person.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(again ? 'Issue new PIN' : 'Create PIN')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final pin = await ref.read(repositoryProvider).issuePin(ref.read(sessionProvider)!, w);
      ref.invalidate(workersProvider);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('PIN for ${w.displayName}'),
          content: SelectableText(pin, style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: 6)),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
        ),
      );
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final workers = ref.watch(workersProvider);
    final venue = ref.watch(venueProvider).value;
    final session = ref.watch(sessionProvider)!;
    final today = DateTime.now().toUtc();
    final day = DateTime.utc(today.year, today.month, today.day);
    final rules = session.rules;

    List<(String, CertificationState)> certStates(Worker w) {
      final out = <(String, CertificationState)>[];
      for (final code in {for (final r in w.jobRoles) ...?venue?.jobRole(r)?.requiredCertifications}) {
        final role = JobRole(venueId: '', code: 'x', name: 'x', requiredCertifications: [code]);
        final check = checkCertifications(role: role, certs: w.certifications, onDate: day, rules: rules.certifications);
        out.add((code, check.results.first.state));
      }
      return out;
    }

    return Scaffold(
      body: SafeArea(
        child: workers.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(workersProvider)),
          data: (all) {
            final shown = [
              for (final w in all)
                if ((_type == null || w.type == _type) &&
                    (_query.isEmpty || w.displayName.toLowerCase().contains(_query) || w.employeeNumber.toLowerCase().contains(_query)) &&
                    (!_certIssues || certStates(w).any((c) => c.$2 != CertificationState.ok)))
                  w,
            ];
            return ListView.builder(
              itemCount: shown.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    ScreenHeader(kicker: session.venue.name, title: 'Staff', subtitle: '${all.length} people · ${shown.length} shown'),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                      child: TextField(
                        decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name or employee number'),
                        onChanged: (v) => setState(() => _query = v.toLowerCase()),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpace.screen, 8, AppSpace.screen, 8),
                      child: Wrap(spacing: 6, runSpacing: 6, children: [
                        for (final t in [null, ...WorkerType.values])
                          ChoiceChip(label: Text(t == null ? 'All' : workerTypeLabel(t)), selected: _type == t, onSelected: (_) => setState(() => _type = t)),
                        FilterChip(label: const Text('Certification issues'), selected: _certIssues, onSelected: (v) => setState(() => _certIssues = v)),
                      ]),
                    ),
                  ]);
                }
                final w = shown[i - 1];
                final age = w.ageOn(day);
                final org = w.type == WorkerType.temp ? venue?.agencyName(w.agencyId) : w.type == WorkerType.npo ? venue?.npoName(w.npoGroupId) : null;
                final certs = certStates(w);
                return ListTile(
                  onTap: session.can('manage_workers') ? () => _issuePin(w) : null,
                  contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                  title: Row(children: [
                    Flexible(child: Text(w.displayName, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 6),
                    StatusTag(workerTypeLabel(w.type), w.type == WorkerType.regular ? Tone.idle : Tone.info),
                    if (age != null && age < rules.minors.adultAge) ...[const SizedBox(width: 4), StatusTag('Minor $age', Tone.warn)],
                    if (w.preferredLanguage == 'es') ...[const SizedBox(width: 4), const StatusTag('ES', Tone.idle)],
                  ]),
                  subtitle: Text([
                    '${w.employeeNumber}${org == null || org.isEmpty ? '' : ' · $org'} · ${w.jobRoles.map((r) => venue?.roleName(r) ?? r).join(', ')}',
                    if (w.hireDate != null) 'Since ${DateFormat('MMM y').format(w.hireDate!)} · Uniform ${w.uniformSize}',
                  ].join('\n')),
                  isThreeLine: true,
                  trailing: Wrap(spacing: 4, children: [
                    for (final (code, state) in certs)
                      StatusTag(
                        '${code == 'tabc' ? 'TABC' : 'Food'} ${switch (state) {
                          CertificationState.ok => 'OK',
                          CertificationState.expiringSoon => 'expiring',
                          CertificationState.expired => 'expired',
                          CertificationState.missing => 'missing',
                        }}',
                        switch (state) {
                          CertificationState.ok => Tone.good,
                          CertificationState.expiringSoon => Tone.warn,
                          _ => Tone.bad,
                        },
                      ),
                  ]),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
