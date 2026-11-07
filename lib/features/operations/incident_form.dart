import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/operations_repository.dart';
import 'checklist_run_sheet.dart' show eventWhen;
import 'operations_logic.dart';
import 'operations_providers.dart';
import 'ops_queue.dart';
import 'ops_widgets.dart';

Future<void> showIncidentForm(BuildContext context) => showDialog<void>(context: context, builder: (_) => const IncidentForm());

/// Shown on injuries: a reminder, not advice.
class InjuryReminder extends StatelessWidget {
  const InjuryReminder({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppColors.warnSoft, borderRadius: BorderRadius.circular(6)),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, color: AppColors.warn),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Reminder: report injuries to HR and start the workers\' comp report the venue uses. '
                'First aid or 911 comes first.',
                style: TextStyle(fontSize: 14, height: 1.4),
              ),
            ),
          ],
        ),
      );
}

/// Log an incident. Works with no signal: it is saved on the device and sent later.
class IncidentForm extends ConsumerStatefulWidget {
  const IncidentForm({super.key});

  @override
  ConsumerState<IncidentForm> createState() => _IncidentFormState();
}

class _IncidentFormState extends ConsumerState<IncidentForm> {
  final _id = const Uuid().v4();
  final _description = TextEditingController();
  IncidentKind _kind = IncidentKind.injury;
  IncidentSeverity _severity = IncidentSeverity.low;
  String? _storefrontId;
  String? _eventId;
  bool _eventPicked = false;
  DateTime _occurredAt = DateTime.now().toUtc();
  final List<IncidentPerson> _people = [];
  final List<Uint8List> _photos = [];
  bool _saving = false;
  StructuredIncidentAnalysis? _oshaResult;

  void _runAiOshaAnalysis() {
    final text = _description.text.trim();
    if (text.isEmpty) {
      showMessage(context, 'Enter incident details first to analyze.');
      return;
    }
    final res = IncidentAssistantAI.analyzeIncidentNotes(text);
    setState(() {
      _oshaResult = res;
      if (res.isOshaRecordable) {
        _severity = IncidentSeverity.high;
      }
    });
  }

  void _applyFormattedSummary() {
    if (_oshaResult == null) return;
    setState(() {
      _description.text = '''Summary: ${_oshaResult!.structuredSummary}
Root Cause: ${_oshaResult!.rootCause}
OSHA Classification: ${_oshaResult!.isOshaRecordable ? 'OSHA 300 Recordable (${_oshaResult!.category})' : 'First Aid Only'}
Actions: ${_oshaResult!.actions.join('; ')}
'''.trim();
    });
  }

  Future<void> _pickTime(String zone) async {
    final local = atVenue(_occurredAt, zone);
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime(local.year, local.month, local.day),
      firstDate: DateTime(local.year - 1),
      lastDate: DateTime(local.year, local.month, local.day),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay(hour: local.hour, minute: local.minute));
    if (time == null) return;
    try {
      final utc = venueWallTimeUtc(DateTime(date.year, date.month, date.day, time.hour, time.minute), zone);
      setState(() => _occurredAt = utc.isAfter(DateTime.now().toUtc()) ? DateTime.now().toUtc() : utc);
    } on ArgumentError {
      if (mounted) showMessage(context, 'That time does not exist (clock change). Pick another.');
    }
  }

  Future<void> _addPerson(List<IncidentPerson> candidates) async {
    final picked = await showDialog<IncidentPerson>(context: context, builder: (_) => _PersonPicker(candidates: candidates, exclude: {for (final p in _people) p.id}));
    if (picked != null) setState(() => _people.add(picked));
  }

  Future<void> _save(AppSession session) async {
    if (_description.text.trim().isEmpty) {
      showMessage(context, 'Describe what happened.');
      return;
    }
    final scope = storefrontsInScope(session, ref.read(venueProvider).value!, {Perm.viewLive});
    if (_storefrontId == null && !session.canVenueWide(Perm.viewLive)) {
      showMessage(context, 'Choose the storefront.');
      return;
    }
    if (_storefrontId != null && !scope.contains(_storefrontId)) return;
    final draft = IncidentDraft(
      id: _id,
      venueId: session.venue.id,
      kind: _kind,
      severity: _severity,
      occurredAt: _occurredAt,
      description: _description.text.trim(),
      eventId: _eventId,
      storefrontId: _storefrontId,
      people: _people,
    );
    setState(() => _saving = true);
    final ok = await runQueued(context, () => ref.read(opsQueueProvider.notifier).logIncident(draft, photos: _photos), sent: 'Incident logged.');
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider)!;
    final venue = ref.watch(venueProvider).value;
    final events = ref.watch(eventsProvider).value ?? const <Event>[];
    final current = ref.watch(currentEventProvider);
    if (!_eventPicked && _eventId == null && current != null) _eventId = current.id;
    final now = ref.watch(clockProvider).value ?? DateTime.now().toUtc();
    final choices = recentEvents(events, now).where((e) => !e.startTime.isAfter(now.add(const Duration(days: 1)))).toList();
    if (_eventId != null && !choices.any((e) => e.id == _eventId)) {
      final e = events.where((e) => e.id == _eventId).firstOrNull;
      if (e != null) choices.add(e);
    }
    final zone = venue?.venue.timeZone ?? session.venue.timeZone;
    final scope = venue == null ? <String>{} : storefrontsInScope(session, venue, {Perm.viewLive});
    final storefronts = [for (final s in venue?.storefronts ?? const <Storefront>[]) if (scope.contains(s.id) && s.active) s]
      ..sort((a, b) => a.name.compareTo(b.name));
    final venueWide = session.canVenueWide(Perm.viewLive);
    if (!venueWide && _storefrontId == null && storefronts.length == 1) _storefrontId = storefronts.first.id;

    // People: the staff list for managers who see it, plus whoever works the event (leads).
    final board = _eventId == null ? null : ref.watch(boardProvider(_eventId!)).value;
    final candidates = <String, IncidentPerson>{
      for (final w in ref.watch(workersProvider).value ?? const <Worker>[])
        if (session.canVenueWide(Perm.viewWorkers)) w.id: IncidentPerson(id: w.id, name: w.displayName, employeeNumber: w.employeeNumber),
      for (final bw in board?.workers.values ?? const <BoardWorker>[])
        bw.id: IncidentPerson(id: bw.id, name: bw.worker.displayName, employeeNumber: bw.worker.employeeNumber),
    }.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    final phone = MediaQuery.sizeOf(context).width < 600;
    final form = Column(
      children: [
        AppBar(
          title: const Text('Log incident'),
          automaticallyImplyLeading: false,
          leading: IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(onPressed: _saving || venue == null ? null : () => _save(session), child: const Text('Save')),
            ),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpace.l),
            children: [
              const Text('What happened', style: AppText.kicker),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final k in IncidentKind.values)
                  ChoiceChip(
                    avatar: Icon(_iconFor(k), size: 18),
                    label: Text(k.label),
                    selected: _kind == k,
                    onSelected: (_) => setState(() => _kind = k),
                  ),
              ]),
              const SizedBox(height: AppSpace.m),
              if (_kind == IncidentKind.injury) const InjuryReminder(),
              if (_kind == IncidentKind.employee)
                const Text('Employee incidents are seen only by managers who handle staff (and you).', style: AppText.meta),
              const SizedBox(height: AppSpace.m),
              const Text('How serious', style: AppText.kicker),
              const SizedBox(height: 6),
              Wrap(spacing: 8, children: [
                for (final s in IncidentSeverity.values)
                  ChoiceChip(label: Text(s.label), selected: _severity == s, onSelected: (_) => setState(() => _severity = s)),
              ]),
              if (_severity == IncidentSeverity.high || _kind == IncidentKind.injury)
                const Padding(padding: EdgeInsets.only(top: 6), child: Text('Venue managers get an alert when you save.', style: AppText.meta)),
              const SizedBox(height: AppSpace.l),
              DropdownButtonFormField<String?>(
                initialValue: _storefrontId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Where'),
                items: [
                  if (venueWide) const DropdownMenuItem(value: null, child: Text('Not at a storefront')),
                  for (final s in storefronts) DropdownMenuItem(value: s.id, child: Text('${s.name} (${s.code})')),
                ],
                onChanged: (v) => setState(() => _storefrontId = v),
              ),
              const SizedBox(height: AppSpace.m),
              DropdownButtonFormField<String?>(
                initialValue: _eventId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Event'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('No event')),
                  for (final e in choices.reversed) DropdownMenuItem(value: e.id, child: Text('${e.name} · ${eventWhen(e, zone)}', overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setState(() {
                  _eventId = v;
                  _eventPicked = true;
                }),
              ),
              const SizedBox(height: AppSpace.m),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.schedule),
                title: Text('When: ${DateFormat('EEE, MMM d · h:mm a').format(atVenue(_occurredAt, zone))}'),
                trailing: TextButton(onPressed: () => _pickTime(zone), child: const Text('Change')),
              ),
              const SizedBox(height: AppSpace.s),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Description', style: AppText.kicker),
                  TextButton.icon(
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    icon: const Icon(Icons.auto_awesome, size: 16),
                    label: const Text('AI OSHA Review & Summary'),
                    onPressed: _runAiOshaAnalysis,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _description,
                minLines: 4,
                maxLines: 10,
                maxLength: 4000,
                decoration: const InputDecoration(hintText: 'What happened, who helped, what was done', alignLabelWithHint: true),
              ),
              if (_oshaResult != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _oshaResult!.isOshaRecordable ? AppColors.badSoft : AppColors.goodSoft,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _oshaResult!.isOshaRecordable ? AppColors.bad : AppColors.good,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                _oshaResult!.isOshaRecordable ? Icons.warning_amber : Icons.verified_user_outlined,
                                color: _oshaResult!.isOshaRecordable ? AppColors.bad : AppColors.good,
                                size: 20,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _oshaResult!.isOshaRecordable ? 'OSHA 300 Recordable' : 'First Aid Only',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: _oshaResult!.isOshaRecordable ? AppColors.bad : AppColors.good,
                                ),
                              ),
                            ],
                          ),
                          TextButton(
                            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                            onPressed: _applyFormattedSummary,
                            child: const Text('Insert Summary'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text('Category: ${_oshaResult!.category}', style: AppText.meta.copyWith(fontWeight: FontWeight.w600)),
                      Text('Summary: ${_oshaResult!.structuredSummary}', style: AppText.body),
                      const SizedBox(height: 4),
                      Text('Root Cause: ${_oshaResult!.rootCause}', style: AppText.meta),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: AppSpace.s),
              const Text('People involved', style: AppText.kicker),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final p in _people) InputChip(label: Text(p.name), onDeleted: () => setState(() => _people.remove(p))),
                ActionChip(
                  avatar: const Icon(Icons.person_add_alt, size: 18),
                  label: const Text('Add person'),
                  onPressed: candidates.isEmpty ? null : () => _addPerson(candidates),
                ),
              ]),
              const SizedBox(height: AppSpace.l),
              const Text('Photos', style: AppText.kicker),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                for (final (n, p) in _photos.indexed) LocalPhotoThumb(bytes: p, size: 72, onRemove: () => setState(() => _photos.removeAt(n))),
                OutlinedButton.icon(
                  onPressed: _photos.length >= 12
                      ? null
                      : () async {
                          final p = await takeOpsPhoto();
                          if (p != null) setState(() => _photos.add(p));
                        },
                  icon: const Icon(Icons.add_a_photo_outlined),
                  label: const Text('Add photo'),
                ),
              ]),
              const SizedBox(height: AppSpace.l),
              const Text('No signal? Save anyway. It sends when the phone reconnects.', style: AppText.meta),
            ],
          ),
        ),
      ],
    );
    return phone ? Dialog.fullscreen(child: form) : Dialog(child: SizedBox(width: 640, height: 760, child: form));
  }

  static IconData _iconFor(IncidentKind k) => switch (k) {
        IncidentKind.injury => Icons.medical_services_outlined,
        IncidentKind.safety => Icons.warning_amber_outlined,
        IncidentKind.employee => Icons.badge_outlined,
        IncidentKind.other => Icons.report_outlined,
      };
}

class _PersonPicker extends StatefulWidget {
  const _PersonPicker({required this.candidates, required this.exclude});

  final List<IncidentPerson> candidates;
  final Set<String> exclude;

  @override
  State<_PersonPicker> createState() => _PersonPickerState();
}

class _PersonPickerState extends State<_PersonPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final list = [
      for (final p in widget.candidates)
        if (!widget.exclude.contains(p.id) && (q.isEmpty || p.name.toLowerCase().contains(q) || p.employeeNumber.toLowerCase().contains(q))) p,
    ];
    return AlertDialog(
      title: const Text('Add person'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(autofocus: true, decoration: const InputDecoration(hintText: 'Name or employee number', prefixIcon: Icon(Icons.search)), onChanged: (v) => setState(() => _query = v)),
            Expanded(
              child: ListView(
                children: [
                  for (final p in list.take(60))
                    ListTile(title: Text(p.name), subtitle: Text(p.employeeNumber), onTap: () => Navigator.pop(context, p)),
                  if (list.isEmpty) const EmptyNote('No one matches.'),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}
