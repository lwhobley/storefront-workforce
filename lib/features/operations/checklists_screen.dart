import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/operations_repository.dart';
import 'checklist_run_sheet.dart';
import 'operations_logic.dart';
import 'operations_providers.dart';
import 'ops_widgets.dart';

enum _Filter { all, needsSignOff, notDone }

/// Opening and closing checklists for the current or next event, per storefront in the
/// person's scope. Venue-wide managers also edit the templates. Manager screen: English.
class ChecklistsScreen extends ConsumerStatefulWidget {
  const ChecklistsScreen({super.key});

  @override
  ConsumerState<ChecklistsScreen> createState() => _ChecklistsScreenState();
}

class _ChecklistsScreenState extends ConsumerState<ChecklistsScreen> {
  String? _eventId;
  bool _templates = false;
  _Filter _filter = _Filter.all;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider)!;
    final venue = ref.watch(venueProvider).value;
    final events = ref.watch(eventsProvider).value ?? const <Event>[];
    final current = ref.watch(currentEventProvider);
    final now = ref.watch(clockProvider).value ?? DateTime.now().toUtc();
    final choices = recentEvents(events, now);
    final eventId = _eventId ?? current?.id;
    final event = events.where((e) => e.id == eventId).firstOrNull;
    final canEditTemplates = session.canVenueWide(Perm.manageSchedule);

    final header = <Widget>[
      ScreenHeader(
        title: 'Checklists',
        subtitle: _templates
            ? 'Opening, closing and other checklists for every storefront'
            : event == null
                ? 'No event coming up'
                : '${event.name} · ${eventWhen(event, venue?.venue.timeZone ?? session.venue.timeZone)}',
        actions: [
          if (!_templates && choices.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: 'Choose event',
              onSelected: (id) => setState(() => _eventId = id),
              itemBuilder: (_) => [
                for (final e in choices.reversed)
                  PopupMenuItem(value: e.id, child: Text('${e.name} · ${eventWhen(e, session.venue.timeZone)}')),
              ],
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.event), SizedBox(width: 6), Text('Event'), Icon(Icons.arrow_drop_down)]),
              ),
            ),
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              if (eventId != null) ref.read(eventChecklistsProvider(eventId).notifier).refresh();
              ref.invalidate(checklistTemplatesProvider);
            },
          ),
        ],
      ),
      if (canEditTemplates)
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.screen, 0, AppSpace.screen, AppSpace.s),
          child: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('Tonight'), icon: Icon(Icons.checklist)),
              ButtonSegment(value: true, label: Text('Templates'), icon: Icon(Icons.edit_note)),
            ],
            selected: {_templates},
            onSelectionChanged: (v) => setState(() => _templates = v.first),
          ),
        ),
      const OpsQueueBanner(),
    ];

    final body = _templates
        ? _TemplatesList(header: header)
        : eventId == null || venue == null
            ? ListView(children: [...header, if (venue != null) const EmptyNote('No event in the next month. Checklists show here for each event.')])
            : _RunsList(header: header, eventId: eventId, venue: venue, filter: _filter, onFilter: (f) => setState(() => _filter = f));

    return Scaffold(body: SafeArea(child: body));
  }
}

class _RunsList extends ConsumerWidget {
  const _RunsList({required this.header, required this.eventId, required this.venue, required this.filter, required this.onFilter});

  final List<Widget> header;
  final String eventId;
  final VenueContext venue;
  final _Filter filter;
  final ValueChanged<_Filter> onFilter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(eventChecklistsProvider(eventId));
    final data = checklistsView(ref, eventId);
    if (data == null) {
      return ListView(children: [
        ...header,
        if (async.hasError)
          ErrorNote(async.error!, onRetry: () => ref.invalidate(eventChecklistsProvider(eventId)))
        else
          const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
      ]);
    }
    final all = <(Storefront, List<ChecklistRun>)>[
      for (final id in data.storefrontIds)
        if (venue.storefront(id) case final sf?) (sf, data.runsAt(id, sf.kind)),
    ];
    final summary = ChecklistSummary.of([for (final (_, runs) in all) ...runs]);
    bool keep(ChecklistRun r) => switch (filter) {
          _Filter.all => true,
          _Filter.needsSignOff => r.status == ChecklistStatus.complete,
          _Filter.notDone => r.status == ChecklistStatus.notStarted || r.status == ChecklistStatus.inProgress,
        };
    final shown = [
      for (final (sf, runs) in all)
        if (runs.where(keep).isNotEmpty) (sf, runs.where(keep).toList()),
    ];

    return RefreshIndicator(
      onRefresh: () => ref.read(eventChecklistsProvider(eventId).notifier).refresh(),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          ...header,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              StatusTag('${summary.signedOff} signed off', Tone.good),
              StatusTag('${summary.ready} ready to sign off', Tone.info),
              StatusTag('${summary.inProgress} in progress', Tone.warn),
              StatusTag('${summary.notStarted} not started', Tone.idle),
            ]),
          ),
          const SizedBox(height: AppSpace.s),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (f, label) in const [(_Filter.all, 'All'), (_Filter.needsSignOff, 'Ready to sign off'), (_Filter.notDone, 'Not done')])
                ChoiceChip(label: Text(label), selected: filter == f, onSelected: (_) => onFilter(f)),
            ]),
          ),
          const SizedBox(height: AppSpace.s),
          if (all.isEmpty) const EmptyNote('No open storefronts in your area for this event.'),
          if (all.isNotEmpty && shown.isEmpty) const EmptyNote('Nothing here.'),
          for (final (sf, runs) in shown)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen - 4, vertical: 4),
              child: Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text('${sf.name}  ·  ${storefrontKindLabel(sf.kind)}', style: AppText.sectionHeading.copyWith(fontSize: 16)),
                    ),
                    for (final r in runs) _RunRow(run: r, eventId: eventId),
                    const SizedBox(height: 4),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RunRow extends StatelessWidget {
  const _RunRow({required this.run, required this.eventId});

  final ChecklistRun run;
  final String eventId;

  @override
  Widget build(BuildContext context) {
    final tone = checklistTone(run.status);
    return InkWell(
      onTap: () => showChecklistRunSheet(context, eventId: eventId, storefrontId: run.storefrontId, templateId: run.templateId),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Icon(run.signedOff ? Icons.verified : Icons.checklist, color: toneColor(tone, context)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(child: Text(run.templateName, style: AppText.body.copyWith(fontWeight: FontWeight.w600))),
                    Text('${run.doneCount}/${run.total}', style: AppText.meta.copyWith(fontWeight: FontWeight.w700)),
                  ]),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: run.total == 0 ? 0 : run.doneCount / run.total,
                    minHeight: 5,
                    color: toneColor(tone, context),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, runSpacing: 4, children: [
                    StatusTag(run.status.label, tone),
                    if (run.hasPending) const StatusTag('Waiting to send', Tone.warn),
                    if (run.items.any((i) => i.photoCount > 0)) const StatusTag('Photos', Tone.idle, icon: Icons.photo_outlined),
                  ]),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.muted),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Templates
// ---------------------------------------------------------------------------

class _TemplatesList extends ConsumerWidget {
  const _TemplatesList({required this.header});

  final List<Widget> header;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(checklistTemplatesProvider);
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        ...header,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: () => _edit(context, ref, const ChecklistTemplate(kind: ChecklistKind.custom, name: '', items: [ChecklistTemplateItem(label: '')])),
              icon: const Icon(Icons.add),
              label: const Text('New checklist'),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.s),
        if (async.hasError) ErrorNote(async.error!, onRetry: () => ref.invalidate(checklistTemplatesProvider)),
        if (async.isLoading && !async.hasValue) const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
        for (final t in async.value ?? const <ChecklistTemplate>[])
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen - 4, vertical: 4),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(child: Text(t.name, style: AppText.sectionHeading.copyWith(fontSize: 17))),
                      if (!t.active) const StatusTag('Off', Tone.idle),
                      TextButton.icon(onPressed: () => _edit(context, ref, t), icon: const Icon(Icons.edit_outlined), label: const Text('Edit')),
                    ]),
                    for (final i in t.items)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                          Text('• ${i.label}', style: AppText.body.copyWith(fontSize: 14)),
                          if (i.photoRequired) const StatusTag('Photo', Tone.info, icon: Icons.photo_camera_outlined),
                          if (i.storefrontKinds.isNotEmpty)
                            StatusTag([for (final k in i.storefrontKinds) storefrontKindLabel(StorefrontKind.fromCode(k))].join(', '), Tone.idle),
                        ]),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, ChecklistTemplate t) async {
    final saved = await showDialog<bool>(context: context, builder: (_) => _TemplateEditor(template: t));
    if (saved == true) {
      ref.invalidate(checklistTemplatesProvider);
      ref.invalidate(eventChecklistsProvider);
    }
  }
}

class _ItemDraft {
  _ItemDraft(this.id, String label, this.photo, this.kinds) : controller = TextEditingController(text: label);

  final String id;
  final TextEditingController controller;
  bool photo;
  Set<String> kinds;
}

class _TemplateEditor extends ConsumerStatefulWidget {
  const _TemplateEditor({required this.template});

  final ChecklistTemplate template;

  @override
  ConsumerState<_TemplateEditor> createState() => _TemplateEditorState();
}

class _TemplateEditorState extends ConsumerState<_TemplateEditor> {
  late final _name = TextEditingController(text: widget.template.name);
  late ChecklistKind _kind = widget.template.kind;
  late bool _active = widget.template.active;
  late final List<_ItemDraft> _items = [
    for (final i in widget.template.items) _ItemDraft(i.id, i.label, i.photoRequired, {...i.storefrontKinds}),
  ];
  // Help text is kept as it was for existing items.
  late final Map<String, String> _help = {for (final i in widget.template.items) i.id: i.help};
  bool _saving = false;

  Future<void> _save() async {
    final session = ref.read(sessionProvider)!;
    final items = [
      for (final d in _items)
        if (d.controller.text.trim().isNotEmpty)
          ChecklistTemplateItem(id: d.id, label: d.controller.text.trim(), help: _help[d.id] ?? '', photoRequired: d.photo, storefrontKinds: d.kinds.toList()),
    ];
    if (_name.text.trim().isEmpty || items.isEmpty) {
      showMessage(context, 'Give it a name and at least one item.');
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.ops.saveChecklistTemplate(
        session,
        ChecklistTemplate(id: widget.template.id, kind: _kind, name: _name.text.trim(), sort: widget.template.sort, active: _active, items: items),
      );
      if (mounted) Navigator.pop(context, true);
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = MediaQuery.sizeOf(context).width < 600;
    final content = Column(
      children: [
        AppBar(
          title: Text(widget.template.id.isEmpty ? 'New checklist' : 'Edit checklist'),
          automaticallyImplyLeading: false,
          leading: IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(onPressed: _saving ? null : _save, child: const Text('Save')),
            ),
          ],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpace.l),
            children: [
              TextField(controller: _name, maxLength: 80, decoration: const InputDecoration(labelText: 'Name')),
              Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                for (final k in ChecklistKind.values)
                  ChoiceChip(label: Text(k.label), selected: _kind == k, onSelected: (_) => setState(() => _kind = k)),
                FilterChip(label: const Text('In use'), selected: _active, onSelected: (v) => setState(() => _active = v)),
              ]),
              const SizedBox(height: AppSpace.m),
              Text('Items', style: AppText.sectionHeading.copyWith(fontSize: 16)),
              const Text('Leave all storefront types off to use an item everywhere. Edits apply to checklists started after you save.', style: AppText.meta),
              for (final (n, d) in _items.indexed)
                Card(
                  margin: const EdgeInsets.only(top: 8),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(child: TextField(controller: d.controller, maxLength: 120, decoration: InputDecoration(labelText: 'Item ${n + 1}'))),
                          IconButton(
                            tooltip: 'Remove item',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: _items.length == 1 ? null : () => setState(() => _items.removeAt(n)),
                          ),
                        ]),
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          FilterChip(
                            avatar: const Icon(Icons.photo_camera_outlined, size: 18),
                            label: const Text('Photo needed'),
                            selected: d.photo,
                            onSelected: (v) => setState(() => d.photo = v),
                          ),
                          for (final k in StorefrontKind.values)
                            FilterChip(
                              label: Text(storefrontKindLabel(k)),
                              selected: d.kinds.contains(k.code),
                              onSelected: (v) => setState(() => v ? d.kinds.add(k.code) : d.kinds.remove(k.code)),
                            ),
                        ]),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: AppSpace.s),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _items.length >= 40 ? null : () => setState(() => _items.add(_ItemDraft('', '', false, {}))),
                  icon: const Icon(Icons.add),
                  label: const Text('Add item'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return phone ? Dialog.fullscreen(child: content) : Dialog(child: SizedBox(width: 640, height: 720, child: content));
  }
}
