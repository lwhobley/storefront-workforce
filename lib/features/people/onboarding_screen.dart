import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/people_repository.dart';
import '../schedule/schedule_actions.dart' show workerTypeLabel;
import 'people_providers.dart';
import 'people_widgets.dart';
import 'ai_card_scan_dialog.dart';

enum _Filter { all, notFinished, needsReview, overdue }

/// Who has finished onboarding and what is left. Managers review uploads, tick
/// training, mark Paycom onboarding done, and send reminders.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  _Filter _filter = _Filter.notFinished;
  WorkerType? _type;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider)!;
    final overview = ref.watch(onboardingOverviewProvider);
    return Scaffold(
      body: SafeArea(
        child: overview.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(onboardingOverviewProvider)),
          data: (all) {
            final summary = OnboardingSummary.of(all);
            final shown = [
              for (final s in all)
                if ((_type == null || s.workerType == _type) &&
                    (_query.isEmpty || s.displayName.toLowerCase().contains(_query) || s.employeeNumber.toLowerCase().contains(_query)) &&
                    switch (_filter) {
                      _Filter.all => true,
                      _Filter.notFinished => !s.finished,
                      _Filter.needsReview => s.needsReview,
                      _Filter.overdue => s.overdue,
                    })
                  s,
            ]..sort((a, b) {
                if (a.needsReview != b.needsReview) return a.needsReview ? -1 : 1;
                return b.daysOpen.compareTo(a.daysOpen);
              });
            final wide = MediaQuery.sizeOf(context).width >= 700;
            final tiles = [
              StatTile(label: 'Completion rate', value: '${(summary.completionRate * 100).round()}%', detail: '${summary.finished} of ${summary.people} finished'),
              StatTile(
                label: 'Average days to finish',
                value: summary.averageDaysToComplete == null ? '—' : summary.averageDaysToComplete!.toStringAsFixed(1),
                detail: 'from added to last step',
              ),
              StatTile(
                label: 'Needs review',
                value: '${summary.needsReview}',
                tone: summary.needsReview > 0 ? Tone.warn : null,
                onTap: () => setState(() => _filter = _Filter.needsReview),
              ),
              StatTile(
                label: 'Overdue (over 7 days)',
                value: '${summary.overdue}',
                tone: summary.overdue > 0 ? Tone.bad : null,
                onTap: () => setState(() => _filter = _Filter.overdue),
              ),
            ];
            return RefreshIndicator(
              onRefresh: () async => ref.invalidate(onboardingOverviewProvider),
              child: ListView.builder(
                itemCount: shown.length + 1,
                itemBuilder: (context, i) {
                  if (i == 0) {
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      ScreenHeader(
                        kicker: session.venue.name,
                        title: 'Onboarding',
                        subtitle: '${summary.people - summary.finished} in progress · ${shown.length} shown',
                        actions: [
                          OutlinedButton.icon(
                            onPressed: () => showDocumentsDialog(context),
                            icon: const Icon(Icons.description_outlined),
                            label: const Text('Documents'),
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen - 4),
                        child: wide
                            ? Row(children: [for (final t in tiles) Expanded(child: t)])
                            : Column(children: [
                                Row(children: [Expanded(child: tiles[0]), Expanded(child: tiles[1])]),
                                Row(children: [Expanded(child: tiles[2]), Expanded(child: tiles[3])]),
                              ]),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, 0),
                        child: TextField(
                          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search name or employee number'),
                          onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(AppSpace.screen, 8, AppSpace.screen, 8),
                        child: Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final (f, label) in const [
                            (_Filter.notFinished, 'Not finished'),
                            (_Filter.needsReview, 'Needs review'),
                            (_Filter.overdue, 'Overdue'),
                            (_Filter.all, 'Everyone'),
                          ])
                            ChoiceChip(label: Text(label), selected: _filter == f, onSelected: (_) => setState(() => _filter = f)),
                          const SizedBox(width: 8),
                          for (final t in [null, ...WorkerType.values])
                            FilterChip(
                              label: Text(t == null ? 'All types' : workerTypeLabel(t)),
                              selected: _type == t,
                              onSelected: (_) => setState(() => _type = t),
                            ),
                        ]),
                      ),
                      if (shown.isEmpty) const EmptyNote('Nobody here. Everyone in this view has finished.'),
                    ]);
                  }
                  final s = shown[i - 1];
                  return _PersonRow(state: s, onTap: () => showPersonOnboarding(context, s.workerId));
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({required this.state, required this.onTap});

  final OnboardingState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final status = s.finished
        ? 'Finished${s.startedAt != null ? ' in ${s.finishedAt!.difference(s.startedAt!).inDays} days' : ''}'
        : 'Open ${s.daysOpen} ${s.daysOpen == 1 ? 'day' : 'days'} · Missing: ${s.missing.join(', ')}';
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen, vertical: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text(s.displayName, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(width: 2),
                StatusTag(workerTypeLabel(s.workerType), s.workerType == WorkerType.regular ? Tone.idle : Tone.info),
                if (s.minor) const StatusTag('Minor', Tone.warn),
                if (s.needsReview) const StatusTag('Review', Tone.warn, icon: Icons.hourglass_top),
                if (s.overdue) const StatusTag('Overdue', Tone.bad),
              ]),
            ),
            const SizedBox(width: 8),
            Text('${s.done}/${s.required}', style: AppText.meta.copyWith(fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          OnboardingBar(state: s, compact: true),
          const SizedBox(height: 4),
          Text('${s.employeeNumber} · $status', style: AppText.meta, maxLines: 2, overflow: TextOverflow.ellipsis),
        ]),
      ),
    );
  }
}

/// One person's onboarding, step by step, with the manager's actions.
Future<void> showPersonOnboarding(BuildContext context, String workerId) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 760),
      builder: (context) => FractionallySizedBox(heightFactor: 0.94, child: PersonOnboardingView(workerId: workerId)),
    );

class PersonOnboardingView extends ConsumerWidget {
  const PersonOnboardingView({super.key, required this.workerId});

  final String workerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(workerOnboardingProvider(workerId));
    final canManage = ref.watch(sessionProvider)?.canVenueWide(Perm.manageWorkers) ?? false;
    return state.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(workerOnboardingProvider(workerId))),
      data: (s) => ListView(
        padding: const EdgeInsets.fromLTRB(AppSpace.screen, 0, AppSpace.screen, 40),
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.displayName, style: AppText.screenTitle.copyWith(fontSize: 26)),
                const SizedBox(height: 4),
                Text(
                  '${s.employeeNumber} · ${workerTypeLabel(s.workerType)}${s.minor ? ' · Minor' : ''} · '
                  '${s.finished ? 'Finished' : 'Open ${s.daysOpen} days'}${s.hasLogin ? '' : ' · No sign-in yet'}',
                  style: AppText.meta,
                ),
              ]),
            ),
            if (canManage && !s.finished)
              OutlinedButton.icon(
                onPressed: s.hasLogin ? () => _run(context, ref, () => ref.people.sendOnboardingReminder(workerId), done: 'Reminder sent') : null,
                icon: const Icon(Icons.notifications_active_outlined),
                label: const Text('Send reminder'),
              ),
          ]),
          const SizedBox(height: 12),
          Text('${s.done} of ${s.required} steps done', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          OnboardingBar(state: s),
          const SizedBox(height: 12),
          for (final step in s.steps) _StepCard(state: s, step: step, canManage: canManage),
        ],
      ),
    );
  }
}

Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() action, {required String done, String? workerId}) async {
  try {
    await action();
    if (workerId != null) ref.invalidate(workerOnboardingProvider(workerId));
    ref.invalidate(onboardingOverviewProvider);
    ref.invalidate(workersProvider);
    if (context.mounted) showMessage(context, done);
  } on AppFailure catch (e) {
    if (context.mounted) showMessage(context, e.message);
  }
}

class _StepCard extends ConsumerStatefulWidget {
  const _StepCard({required this.state, required this.step, required this.canManage});

  final OnboardingState state;
  final OnboardingStepState step;
  final bool canManage;

  @override
  ConsumerState<_StepCard> createState() => _StepCardState();
}

class _StepCardState extends ConsumerState<_StepCard> {
  late Set<String> _items = {...widget.step.itemsDone};
  DateTime? _paycomDate;

  @override
  void didUpdateWidget(covariant _StepCard old) {
    super.didUpdateWidget(old);
    if (old.step.itemsDone.length != widget.step.itemsDone.length) _items = {...widget.step.itemsDone};
  }

  String get _workerId => widget.state.workerId;

  Future<void> _act(Future<void> Function() action, String done) => _run(context, ref, action, done: done, workerId: _workerId);

  void _openAiCardScan(BuildContext context, PendingCert cert, String certName) {
    final session = ref.read(sessionProvider)!;
    final worker = Worker(
      id: widget.state.workerId,
      venueId: session.venue.id,
      type: widget.state.workerType,
      employeeNumber: widget.state.employeeNumber,
      firstName: widget.state.firstName,
      lastName: widget.state.lastName,
      preferredName: widget.state.preferredName,
    );
    showDialog<void>(
      context: context,
      builder: (_) => AiCardScanDialog(
        worker: worker,
        certTypeCode: cert.typeCode,
        certName: certName,
        initialNumber: cert.number,
        initialExpiresOn: cert.expiresOn,
        onApproved: () => _act(() => ref.people.reviewOnboardingStep(_workerId, widget.step.code, approve: true), 'Card auto-approved by AI'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.step;
    final venue = ref.watch(venueProvider).value;
    final zone = ref.watch(sessionProvider)!.venue.timeZone;
    String when(DateTime? d) => d == null ? '' : shortDate.format(atVenue(d, zone));
    final children = <Widget>[];
    final data = step.data;

    switch (step.kind) {
      case StepKind.form when data.containsKey('date_of_birth'):
        children.add(Text('Birth date given: ${shortDate.format(DateTime.parse(data['date_of_birth'] as String))}', style: AppText.body));
      case StepKind.form:
        if (step.config['auto_complete_when'] == 'date_of_birth' && step.done) {
          children.add(const Text('Birth date on file.', style: AppText.body));
        }
        for (final (k, label) in const [
          ('address', 'Address'),
          ('phone', 'Phone'),
          ('email', 'Email'),
          ('emergency_contact_name', 'Emergency contact'),
          ('emergency_contact_phone', 'Emergency phone'),
          ('uniform_size', 'Uniform size'),
          ('preferred_language', 'Language'),
          ('notes', 'Notes'),
        ]) {
          if ('${data[k] ?? ''}'.isEmpty) continue;
          children.add(Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text.rich(TextSpan(children: [
              TextSpan(text: '$label: ', style: AppText.meta.copyWith(fontWeight: FontWeight.w600)),
              TextSpan(text: k == 'preferred_language' ? (data[k] == 'es' ? 'Spanish' : 'English') : '${data[k]}', style: AppText.body),
            ])),
          ));
        }
      case StepKind.document:
        for (final id in step.documentIds) {
          final doc = widget.state.document(id);
          final ack = step.acknowledgments.where((a) => a['document_id'] == id).lastOrNull;
          final signed = !step.missingDocumentIds.contains(id);
          children.add(ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(signed ? Icons.check_circle : Icons.radio_button_unchecked, color: signed ? AppColors.good : AppColors.idle),
            title: Text(doc?.title ?? 'Document'),
            subtitle: Text(ack == null || !signed
                ? (ack == null ? 'Not signed' : 'Signed an older version; needs to sign the new one')
                : 'Typed "${ack['typed_name']}"${ack['guardian_name'] != null ? ', guardian "${ack['guardian_name']}"' : ''}'
                    '${ack['at'] != null ? ' on ${when(DateTime.tryParse(ack['at'] as String))}' : ''}'),
          ));
        }
      case StepKind.upload:
        children.add(Text(
          'Needed for their roles: ${step.requiredCerts.map((c) => venue?.certName(c) ?? c).join(', ')}'
          '${step.missingCerts.isEmpty ? '' : '\nNot yet current: ${step.missingCerts.map((c) => venue?.certName(c) ?? c).join(', ')}'}',
          style: AppText.body,
        ));
        for (final c in step.pendingCerts) {
          children.add(Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (c.documentPath != null) CardPhoto(path: c.documentPath!, label: venue?.certName(c.typeCode) ?? c.typeCode, height: 120),
              Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(venue?.certName(c.typeCode) ?? c.typeCode, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                Text('Number: ${c.number.isEmpty ? '—' : c.number}', style: AppText.meta),
                Text('Expires: ${c.expiresOn == null ? '—' : shortDate.format(c.expiresOn!)}', style: AppText.meta),
                const Text('Uploaded, not checked yet', style: TextStyle(color: AppColors.warn, fontWeight: FontWeight.w600, fontSize: 13)),
                if (widget.canManage)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
                      icon: const Icon(Icons.auto_awesome, size: 16),
                      label: const Text('AI Auto-Scan Card'),
                      onPressed: () => _openAiCardScan(context, c, venue?.certName(c.typeCode) ?? c.typeCode),
                    ),
                  ),
              ]),
            ]),
          ));
        }
      case StepKind.checklist:
        for (final i in step.items) {
          children.add(CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _items.contains(i.code),
            onChanged: widget.canManage ? (v) => setState(() => v == true ? _items.add(i.code) : _items.remove(i.code)) : null,
            title: Text(i.label),
          ));
        }
        if (widget.canManage) {
          children.add(Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonal(
              onPressed: _items.length == step.itemsDone.length && _items.containsAll(step.itemsDone)
                  ? null
                  : () => _act(() => ref.people.completeOnboardingStep(_workerId, step.code, {'items': _items.toList()}), 'Training saved'),
              child: const Text('Save training'),
            ),
          ));
        }
      case StepKind.external:
        final on = data['completed_on'] as String?;
        children.add(Text(step.config['label'] as String? ?? step.description, style: AppText.body));
        if (on != null) {
          children.add(Text('Marked complete for ${shortDate.format(DateTime.parse(on))}', style: AppText.meta.copyWith(color: AppColors.good, fontWeight: FontWeight.w600)));
        } else if (widget.canManage) {
          final today = venueDate(DateTime.now().toUtc(), zone);
          children.add(Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.event),
                label: Text('Completed on ${shortDate.format(_paycomDate ?? today)}'),
                onPressed: () async {
                  final d = await showDatePicker(context: context, firstDate: DateTime(today.year - 2), lastDate: today, initialDate: _paycomDate ?? today);
                  if (d != null) setState(() => _paycomDate = DateTime.utc(d.year, d.month, d.day));
                },
              ),
              FilledButton(
                onPressed: () => _act(
                  () => ref.people.completeOnboardingStep(_workerId, step.code, {'completed_on': dateOnly(_paycomDate ?? today)}),
                  'Marked complete',
                ),
                child: const Text('Mark complete'),
              ),
            ]),
          ));
        }
    }

    final actions = <Widget>[
      if (widget.canManage && step.needsReview) ...[
        FilledButton.icon(
          onPressed: () => _act(() => ref.people.reviewOnboardingStep(_workerId, step.code, approve: true), 'Approved'),
          icon: const Icon(Icons.check),
          label: Text(step.kind == StepKind.upload ? 'Approve card' : 'Approve'),
        ),
        OutlinedButton.icon(
          onPressed: () async {
            final note = await askReason(context,
                title: 'What needs to change?',
                hint: 'Note for ${widget.state.displayName}',
                action: 'Send back',
                suggestions: step.kind == StepKind.upload ? const ['Photo is blurry', 'Card is expired', 'Wrong card', 'Name does not match'] : const []);
            if (note != null) await _act(() => ref.people.reviewOnboardingStep(_workerId, step.code, approve: false, note: note), 'Sent back');
          },
          icon: const Icon(Icons.undo),
          label: const Text('Needs changes'),
        ),
      ],
      if (widget.canManage && step.kind == StepKind.form && !step.done && !step.needsReview)
        TextButton(
          onPressed: () => _act(() => ref.people.completeOnboardingStep(_workerId, step.code, {'note': 'Completed on paper'}), 'Marked done'),
          child: const Text('Mark done (on paper)'),
        ),
    ];

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.m),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(stepIcon(step.status), color: toneColor(stepTone(step.status), context)),
            const SizedBox(width: 8),
            Expanded(child: Text(step.name, style: AppText.sectionHeading.copyWith(fontSize: 16))),
            StatusTag(_statusText(step), stepTone(step.status)),
          ]),
          if (step.submittedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 32),
              child: Text('Last update ${when(step.reviewedAt ?? step.submittedAt)}', style: AppText.meta),
            ),
          if (step.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 32),
              child: Text('Note: ${step.note}', style: AppText.meta.copyWith(color: AppColors.bad)),
            ),
          if (children.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8, left: 32), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children)),
          if (actions.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10, left: 32), child: Wrap(spacing: 8, runSpacing: 8, children: actions)),
        ]),
      ),
    );
  }

  String _statusText(OnboardingStepState s) => switch (s.status) {
        StepStatus.complete => 'Done',
        StepStatus.approved => 'Approved',
        StepStatus.submitted => 'Needs review',
        StepStatus.needsChanges => 'Sent back',
        StepStatus.notStarted => s.kind == StepKind.checklist && s.items.isNotEmpty ? '${s.itemsDone.where((c) => s.items.any((i) => i.code == c)).length}/${s.items.length}' : 'Not done',
      };
}

// ---------------------------------------------------------------------------
// Venue documents
// ---------------------------------------------------------------------------

Future<void> showDocumentsDialog(BuildContext context) => showDialog<void>(context: context, builder: (_) => const _DocumentsDialog());

class _DocumentsDialog extends ConsumerWidget {
  const _DocumentsDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final docs = ref.watch(onboardingDocumentsProvider);
    final canManage = ref.watch(sessionProvider)?.canVenueWide(Perm.manageWorkers) ?? false;
    return AlertDialog(
      title: const Text('Onboarding documents'),
      content: SizedBox(
        width: 560,
        child: docs.when(
          loading: () => const SizedBox(height: 120, child: Center(child: CircularProgressIndicator())),
          error: (e, _) => ErrorNote(e),
          data: (list) => ListView(shrinkWrap: true, children: [
            const Text('People sign these by typing their name. Editing the text asks everyone to sign again.', style: AppText.meta),
            const SizedBox(height: 8),
            for (final d in list)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(d.title),
                subtitle: Text('${d.stepCode == 'waiver' ? 'Waiver' : 'Policy'} · for ${d.appliesTo.map((a) => workerTypeLabel(WorkerType.fromCode(a))).join(', ')} · version ${d.version}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  StatusTag(d.active ? 'In use' : 'Off', d.active ? Tone.good : Tone.idle),
                  if (canManage) IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit_outlined), onPressed: () => _edit(context, ref, d)),
                ]),
              ),
          ]),
        ),
      ),
      actions: [
        if (canManage)
          TextButton.icon(
            onPressed: () => _edit(context, ref, const OnboardingDocument(id: '', title: '')),
            icon: const Icon(Icons.add),
            label: const Text('Add document'),
          ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, OnboardingDocument d) async {
    final saved = await showDialog<OnboardingDocument>(context: context, builder: (_) => _DocumentEditor(doc: d));
    if (saved == null) return;
    try {
      await ref.people.saveOnboardingDocument(ref.read(sessionProvider)!, saved);
      ref.invalidate(onboardingDocumentsProvider);
      ref.invalidate(onboardingOverviewProvider);
    } on AppFailure catch (e) {
      if (context.mounted) showMessage(context, e.message);
    }
  }
}

class _DocumentEditor extends StatefulWidget {
  const _DocumentEditor({required this.doc});

  final OnboardingDocument doc;

  @override
  State<_DocumentEditor> createState() => _DocumentEditorState();
}

class _DocumentEditorState extends State<_DocumentEditor> {
  late final _title = TextEditingController(text: widget.doc.title);
  late final _body = TextEditingController(text: widget.doc.body);
  late String _step = widget.doc.stepCode;
  late Set<String> _for = {...widget.doc.appliesTo};
  late bool _active = widget.doc.active;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.doc.id.isEmpty ? 'New document' : 'Edit document'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(controller: _title, decoration: const InputDecoration(labelText: 'Title')),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [ButtonSegment(value: 'policies', label: Text('Policy')), ButtonSegment(value: 'waiver', label: Text('NPO waiver'))],
                selected: {_step},
                onSelectionChanged: (s) => setState(() {
                  _step = s.first;
                  _for = _step == 'waiver' ? {'npo'} : {'regular', 'temp'};
                }),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 6, children: [
                for (final t in WorkerType.values)
                  FilterChip(
                    label: Text(workerTypeLabel(t)),
                    selected: _for.contains(t.code),
                    onSelected: (v) => setState(() => v ? _for.add(t.code) : _for.remove(t.code)),
                  ),
              ]),
              const SizedBox(height: 12),
              TextField(controller: _body, minLines: 6, maxLines: 14, decoration: const InputDecoration(labelText: 'Text people read', alignLabelWithHint: true)),
              SwitchListTile(contentPadding: EdgeInsets.zero, value: _active, onChanged: (v) => setState(() => _active = v), title: const Text('In use')),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: _title.text.trim().isEmpty && widget.doc.title.isEmpty && _for.isEmpty
                ? null
                : () => Navigator.pop(context, widget.doc.copyWith(title: _title.text.trim(), body: _body.text, stepCode: _step, appliesTo: _for.toList(), active: _active)),
            child: const Text('Save'),
          ),
        ],
      );
}
