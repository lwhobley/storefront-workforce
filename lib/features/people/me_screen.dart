import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/people_repository.dart';
import '../pay/pay_logic.dart' show money;
import 'people_logic.dart';
import 'people_providers.dart';
import 'people_strings.dart';
import 'people_widgets.dart';

/// Dates in the person's language, falling back to English.
String _fmt(String pattern, String lang, DateTime d) {
  try {
    return DateFormat(pattern, lang).format(d);
  } catch (_) {
    return DateFormat(pattern).format(d);
  }
}

/// The employee's own page: hours by pay period, tips, onboarding checklist, profile.
/// Never shows wages or pay rates.
class MeScreen extends ConsumerStatefulWidget {
  const MeScreen({super.key});

  @override
  ConsumerState<MeScreen> createState() => _MeScreenState();
}

class _MeScreenState extends ConsumerState<MeScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final session = ref.watch(sessionProvider)!;
    final onboarding = ref.watch(myOnboardingProvider).value;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ScreenHeader(
              kicker: session.venue.name,
              title: session.displayName,
              actions: [TextButton(onPressed: () => ref.read(languageProvider.notifier).toggle(), child: Text(t.language))],
            ),
            if (onboarding != null && !onboarding.finished)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.screen, 0, AppSpace.screen, AppSpace.s),
                child: Material(
                  color: AppColors.warnSoft,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _tabs.animateTo(2),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpace.m),
                      child: Row(children: [
                        const Icon(Icons.task_alt, color: AppColors.warn),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text('${t.onboardingBanner} · ${t.stepsDone(onboarding.done, onboarding.required)}',
                              style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                        ),
                        Text(t.continueOnboarding, style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  ),
                ),
              ),
            TabBar(
              controller: _tabs,
              isScrollable: MediaQuery.sizeOf(context).width < 420,
              tabAlignment: MediaQuery.sizeOf(context).width < 420 ? TabAlignment.start : null,
              labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              tabs: [
                Tab(height: 52, text: t.hoursTab),
                Tab(height: 52, text: t.tipsTab),
                Tab(height: 52, text: t.onboardingTab),
                Tab(height: 52, text: t.profileTab),
              ],
            ),
            Expanded(
              child: TabBarView(controller: _tabs, children: const [_HoursTab(), _TipsTab(), _OnboardingTab(), _ProfileTab()]),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hours
// ---------------------------------------------------------------------------

class _HoursTab extends ConsumerStatefulWidget {
  const _HoursTab();

  @override
  ConsumerState<_HoursTab> createState() => _HoursTabState();
}

class _HoursTabState extends ConsumerState<_HoursTab> {
  /// Null until chosen: the current period, or the latest one with hours.
  int? _index;

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final session = ref.watch(sessionProvider)!;
    final venue = ref.watch(venueProvider).value;
    final data = ref.watch(myHoursProvider);
    final zone = session.venue.timeZone;
    final now = ref.watch(clockProvider).value ?? DateTime.now().toUtc();
    return data.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(myHoursProvider)),
      data: (d) {
        final items = hoursByEvent(d, timeZone: zone, breakRules: session.rules.breaks, storefronts: venue?.storefronts ?? const [], now: now);
        final today = venueDate(now, zone);
        final periods = hoursByPayPeriod(items, venueSettings: session.venue.settings, from: today.subtract(const Duration(days: 120)), to: today);
        final latest = periods.indexWhere((p) => p.items.isNotEmpty);
        final i = (_index ?? (periods.first.items.isEmpty && latest > 0 ? latest : 0)).clamp(0, periods.length - 1);
        final p = periods[i];
        final range = '${_fmt('MMM d', t.lang, p.period.startsOn)} – ${_fmt('MMM d', t.lang, p.period.endsOn)}';
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(myHoursProvider),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.s, AppSpace.m, AppSpace.s, 0),
                child: Row(children: [
                  IconButton(
                    iconSize: 32,
                    tooltip: t.previousPeriod,
                    onPressed: i < periods.length - 1 ? () => setState(() => _index = i + 1) : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Column(children: [
                      Text(t.payPeriod.toUpperCase(), style: AppText.kicker),
                      const SizedBox(height: 2),
                      Text(range, style: AppText.sectionHeading, textAlign: TextAlign.center),
                      Text(t.paidOn(_fmt('EEE MMM d', t.lang, p.period.payDate)), style: AppText.meta),
                    ]),
                  ),
                  IconButton(
                    iconSize: 32,
                    tooltip: t.nextPeriod,
                    onPressed: i > 0 ? () => setState(() => _index = i - 1) : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen - 4, vertical: AppSpace.s),
                child: IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(flex: 4, child: _MiniStat(label: t.hoursWorkedLabel, value: hoursMinutes(p.paidMinutes))),
                    Expanded(flex: 3, child: _MiniStat(label: t.eventsLabel, value: '${p.items.length}')),
                    Expanded(flex: 4, child: _MiniStat(label: t.breaksLabel, value: hoursMinutes(p.breakMinutes))),
                  ]),
                ),
              ),
              if (p.items.isEmpty) EmptyNote(t.noHoursInPeriod),
              for (final e in p.items) _EventHoursCard(item: e, t: t, zone: zone, roleName: venue?.roleName),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.l, AppSpace.screen, 0),
                child: Text(t.hoursNote, style: AppText.meta),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.m),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(label, style: AppText.meta.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, style: AppText.numeral.copyWith(fontSize: 24))),
          ]),
        ),
      );
}

class _EventHoursCard extends StatelessWidget {
  const _EventHoursCard({required this.item, required this.t, required this.zone, this.roleName});

  final EventHours item;
  final T t;
  final String zone;
  final String Function(String)? roleName;

  @override
  Widget build(BuildContext context) {
    String time(DateTime? d) => d == null ? '—' : DateFormat('h:mm a').format(atVenue(d, zone));
    final details = [
      _fmt('EEE MMM d', t.lang, item.date),
      if (item.storefrontName.isNotEmpty) item.storefrontName,
      if (item.jobRoleCode != null && roleName != null) roleName!(item.jobRoleCode!),
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: AppSpace.screen - 4, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.m),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.event?.name ?? t.otherWork, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(details, style: AppText.meta),
              const SizedBox(height: 4),
              Text(
                item.open
                    ? '${t.inLabel} ${time(item.firstIn)} · ${t.stillClockedIn}'
                    : '${t.inLabel} ${time(item.firstIn)} · ${t.outLabel} ${time(item.lastOut)}'
                        '${item.breakCount > 0 ? ' · ${t.breaksLabel} ${hoursMinutes(item.breakMinutes)}' : ''}',
                style: AppText.meta,
              ),
            ]),
          ),
          const SizedBox(width: 8),
          Text(hoursMinutes(item.paidMinutes), style: AppText.numeral.copyWith(fontSize: 22)),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tips
// ---------------------------------------------------------------------------

class _TipsTab extends ConsumerWidget {
  const _TipsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final zone = ref.watch(sessionProvider)!.venue.timeZone;
    return ref.watch(myTipsProvider).when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(myTipsProvider)),
          data: (tips) {
            final total = tips.fold(0, (s, x) => s + x.amountCents);
            return RefreshIndicator(
              onRefresh: () async => ref.invalidate(myTipsProvider),
              child: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpace.screen - 4, AppSpace.m, AppSpace.screen - 4, 0),
                  child: StatTile(label: t.tipsTotal, value: money(total), detail: '${tips.length} ${t.eventsLabel.toLowerCase()}', tone: Tone.good),
                ),
                if (tips.isEmpty) EmptyNote(t.noTips),
                for (final x in tips)
                  ListTile(
                    minVerticalPadding: 12,
                    contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                    title: Text(x.eventName, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text([
                      _fmt('EEE MMM d', t.lang, venueDate(x.startTime, zone)),
                      if (x.storefrontName.isNotEmpty) x.storefrontName,
                      t.hoursShort(formatHundredths(x.hoursHundredths)),
                    ].join(' · ')),
                    trailing: Text(money(x.amountCents), style: AppText.numeral.copyWith(fontSize: 20)),
                  ),
                Padding(padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.l, AppSpace.screen, 0), child: Text(t.tipsNote, style: AppText.meta)),
              ]),
            );
          },
        );
  }
}

// ---------------------------------------------------------------------------
// Onboarding
// ---------------------------------------------------------------------------

class _OnboardingTab extends ConsumerWidget {
  const _OnboardingTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    return ref.watch(myOnboardingProvider).when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(myOnboardingProvider)),
          data: (s) => RefreshIndicator(
            onRefresh: () async => ref.invalidate(myOnboardingProvider),
            child: ListView(padding: const EdgeInsets.only(bottom: 40), children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.l, AppSpace.screen, AppSpace.s),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.finished ? t.allDone : t.stepsDone(s.done, s.required), style: AppText.sectionHeading),
                  const SizedBox(height: 8),
                  OnboardingBar(state: s),
                ]),
              ),
              for (final step in s.steps)
                Card(
                  margin: const EdgeInsets.symmetric(horizontal: AppSpace.screen - 4, vertical: 4),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => _openStep(context, step),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpace.m),
                      child: Row(children: [
                        Icon(stepIcon(step.status), color: toneColor(stepTone(step.status), context), size: 30),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(t.stepName(step.code, step.name), style: AppText.body.copyWith(fontWeight: FontWeight.w700, fontSize: 16)),
                            const SizedBox(height: 2),
                            Text(
                              step.kind == StepKind.checklist && step.items.isNotEmpty
                                  ? t.itemsDone(step.itemsDone.where((c) => step.items.any((i) => i.code == c)).length, step.items.length)
                                  : t.stepHelp(step.code, step.description),
                              style: AppText.meta,
                            ),
                            if (step.status == StepStatus.needsChanges && step.note.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text('${t.managerSays} ${step.note}', style: AppText.meta.copyWith(color: AppColors.bad, fontWeight: FontWeight.w600)),
                            ],
                          ]),
                        ),
                        const SizedBox(width: 8),
                        StatusTag(t.statusLabel(step.status.code), stepTone(step.status)),
                      ]),
                    ),
                  ),
                ),
            ]),
          ),
        );
  }

  void _openStep(BuildContext context, OnboardingStepState step) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => FractionallySizedBox(heightFactor: 0.92, child: _StepSheet(code: step.code)),
    );
  }
}

/// One step, opened from the checklist.
class _StepSheet extends ConsumerWidget {
  const _StepSheet({required this.code});

  final String code;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final state = ref.watch(myOnboardingProvider).value;
    final step = state?.step(code);
    if (state == null || step == null) return const Center(child: CircularProgressIndicator());
    final body = switch (step.kind) {
      StepKind.form when step.code == 'age_confirmation' || ((step.config['fields'] as List?)?.contains('date_of_birth') ?? false) =>
        _BirthDateForm(step: step),
      StepKind.form => _ApplicationForm(state: state, step: step),
      StepKind.document => _DocumentsForm(state: state, step: step),
      StepKind.upload => _CardsForm(step: step),
      StepKind.checklist => _ChecklistView(step: step),
      StepKind.external => _ExternalView(step: step),
    };
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpace.screen, 0, AppSpace.screen, 40),
      children: [
        Text(t.stepName(step.code, step.name), style: AppText.screenTitle.copyWith(fontSize: 26)),
        const SizedBox(height: 6),
        Row(children: [StatusTag(t.statusLabel(step.status.code), stepTone(step.status), icon: stepIcon(step.status))]),
        const SizedBox(height: 8),
        Text(t.stepHelp(step.code, step.description), style: AppText.body),
        if (step.status == StepStatus.needsChanges && step.note.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppColors.badSoft, borderRadius: BorderRadius.circular(8)),
            child: Text('${t.managerSays} ${step.note}', style: const TextStyle(color: AppColors.bad, fontWeight: FontWeight.w600)),
          ),
        const SizedBox(height: 16),
        body,
      ],
    );
  }
}

/// Submits a step and refreshes the checklist; shows the server's message on refusal.
Future<bool> _submit(BuildContext context, WidgetRef ref, String step, Map<String, dynamic> data, {List<String> files = const []}) async {
  final t = ref.read(stringsProvider);
  try {
    await ref.people.submitOnboardingStep(ref.read(sessionProvider)!, step, data, files: files);
    ref.invalidate(myOnboardingProvider);
    ref.invalidate(workersProvider);
    if (context.mounted) showMessage(context, t.saved);
    return true;
  } on AppFailure catch (e) {
    if (context.mounted) showMessage(context, e.message);
    return false;
  }
}

class _BigButton extends StatelessWidget {
  const _BigButton({required this.label, required this.onPressed, this.busy = false});

  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 56,
        width: double.infinity,
        child: FilledButton(
          onPressed: busy ? null : onPressed,
          style: FilledButton.styleFrom(textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          child: busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3)) : Text(label),
        ),
      );
}

class _ApplicationForm extends ConsumerStatefulWidget {
  const _ApplicationForm({required this.state, required this.step});

  final OnboardingState state;
  final OnboardingStepState step;

  @override
  ConsumerState<_ApplicationForm> createState() => _ApplicationFormState();
}

class _ApplicationFormState extends ConsumerState<_ApplicationForm> {
  static const _sizes = ['XS', 'S', 'M', 'L', 'XL', '2XL', '3XL'];
  late final Map<String, TextEditingController> _c;
  late String _size;
  late String _lang;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final data = widget.step.data;
    final profile = widget.state.profile;
    String v(String k) => '${data[k] ?? profile[k] ?? ''}';
    _c = {for (final k in const ['address', 'phone', 'email', 'emergency_contact_name', 'emergency_contact_phone', 'notes']) k: TextEditingController(text: v(k))};
    _size = v('uniform_size');
    _lang = v('preferred_language') == 'es' ? 'es' : 'en';
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _field(String key, String label, {TextInputType? keyboard, bool required = false, int lines = 1}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: _c[key],
          keyboardType: keyboard,
          minLines: lines,
          maxLines: lines,
          style: const TextStyle(fontSize: 17),
          decoration: InputDecoration(labelText: required ? '$label *' : label),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _field('address', t.address, keyboard: TextInputType.streetAddress, lines: 2),
      _field('phone', t.phone, keyboard: TextInputType.phone, required: true),
      _field('email', t.email, keyboard: TextInputType.emailAddress),
      _field('emergency_contact_name', t.emergencyName, keyboard: TextInputType.name, required: true),
      _field('emergency_contact_phone', t.emergencyPhone, keyboard: TextInputType.phone, required: true),
      Text(t.uniformSize, style: AppText.meta.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final s in _sizes)
          ChoiceChip(
            label: Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6), child: Text(s, style: const TextStyle(fontSize: 16))),
            selected: _size == s,
            onSelected: (_) => setState(() => _size = s),
          ),
      ]),
      const SizedBox(height: 16),
      Text(t.preferredLanguage, style: AppText.meta.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      SegmentedButton<String>(
        segments: [ButtonSegment(value: 'en', label: Text(t.english)), ButtonSegment(value: 'es', label: Text(t.spanish))],
        selected: {_lang},
        onSelectionChanged: (s) => setState(() => _lang = s.first),
      ),
      const SizedBox(height: 16),
      _field('notes', t.notes, lines: 2),
      const SizedBox(height: 8),
      _BigButton(
        label: t.submit,
        busy: _busy,
        onPressed: () async {
          setState(() => _busy = true);
          final ok = await _submit(context, ref, widget.step.code, {
            for (final e in _c.entries) e.key: e.value.text.trim(),
            'uniform_size': _size,
            'preferred_language': _lang,
          });
          if (!mounted) return;
          setState(() => _busy = false);
          if (ok) {
            ref.read(languageProvider.notifier).set(_lang);
            if (context.mounted) Navigator.of(context).maybePop();
          }
        },
      ),
    ]);
  }
}

class _DocumentsForm extends ConsumerStatefulWidget {
  const _DocumentsForm({required this.state, required this.step});

  final OnboardingState state;
  final OnboardingStepState step;

  @override
  ConsumerState<_DocumentsForm> createState() => _DocumentsFormState();
}

class _DocumentsFormState extends ConsumerState<_DocumentsForm> {
  final Map<String, TextEditingController> _names = {};
  final Map<String, TextEditingController> _guardians = {};
  bool _adult = false;
  String? _busy;

  TextEditingController _ctl(Map<String, TextEditingController> m, String id) => m.putIfAbsent(id, TextEditingController.new);

  @override
  void dispose() {
    for (final c in [..._names.values, ..._guardians.values]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final step = widget.step;
    final zone = ref.watch(sessionProvider)!.venue.timeZone;
    final askAdult = step.config['guardian_for_minors'] == true && !step.birthDateOnFile;
    final needGuardian = step.guardianRequired || (askAdult && !_adult);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final id in step.documentIds)
        if (widget.state.document(id) case final doc?)
          Card(
            margin: const EdgeInsets.only(bottom: 16),
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.m),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(doc.title, style: AppText.sectionHeading),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 220),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: AppColors.raised, border: Border.all(color: AppColors.divider), borderRadius: BorderRadius.circular(6)),
                  child: SingleChildScrollView(child: SelectableText(doc.body, style: AppText.body)),
                ),
                const SizedBox(height: 12),
                if (!step.missingDocumentIds.contains(id))
                  Builder(builder: (_) {
                    final ack = step.acknowledgments.lastWhere((a) => a['document_id'] == id, orElse: () => const {});
                    final at = ack['at'] == null ? null : DateTime.tryParse(ack['at'] as String);
                    return Row(children: [
                      const Icon(Icons.check_circle, color: AppColors.good),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          t.signedBy('${ack['typed_name'] ?? ''}${ack['guardian_name'] != null ? ' / ${ack['guardian_name']}' : ''}',
                              at == null ? '' : _fmt('MMM d, y', t.lang, venueDate(at, zone))),
                          style: AppText.meta,
                        ),
                      ),
                    ]);
                  })
                else ...[
                  if (step.acknowledgments.any((a) => a['document_id'] == id))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(t.updatedSignAgain, style: AppText.meta.copyWith(color: AppColors.warn, fontWeight: FontWeight.w600)),
                    ),
                  TextField(
                    controller: _ctl(_names, id),
                    textCapitalization: TextCapitalization.words,
                    style: const TextStyle(fontSize: 18),
                    decoration: InputDecoration(labelText: t.typeYourName, helperText: t.nameMustMatch),
                  ),
                  if (askAdult)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _adult,
                      onChanged: (v) => setState(() => _adult = v ?? false),
                      title: Text(t.iAmAdult),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  if (needGuardian) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _ctl(_guardians, id),
                      textCapitalization: TextCapitalization.words,
                      style: const TextStyle(fontSize: 18),
                      decoration: InputDecoration(labelText: t.guardianName),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _BigButton(
                    label: t.sign,
                    busy: _busy == id,
                    onPressed: () async {
                      setState(() => _busy = id);
                      await _submit(context, ref, step.code, {
                        'acknowledgments': [
                          {
                            'document_id': id,
                            'typed_name': _ctl(_names, id).text.trim(),
                            if (needGuardian) 'guardian_name': _ctl(_guardians, id).text.trim(),
                          },
                        ],
                        if (askAdult && _adult) 'adult_confirmed': true,
                      });
                      if (mounted) setState(() => _busy = null);
                    },
                  ),
                ],
              ]),
            ),
          ),
    ]);
  }
}

class _CardsForm extends ConsumerStatefulWidget {
  const _CardsForm({required this.step});

  final OnboardingStepState step;

  @override
  ConsumerState<_CardsForm> createState() => _CardsFormState();
}

class _CardDraft {
  XFile? file;
  final number = TextEditingController();
  DateTime? expires;
}

class _CardsFormState extends ConsumerState<_CardsForm> {
  final Map<String, _CardDraft> _drafts = {};
  bool _busy = false;

  @override
  void dispose() {
    for (final d in _drafts.values) {
      d.number.dispose();
    }
    super.dispose();
  }

  Future<void> _pick(_CardDraft d, ImageSource source) async {
    try {
      final f = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 80);
      if (f != null) setState(() => d.file = f);
    } catch (_) {
      // Camera unavailable or permission refused; the person can choose a photo instead.
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    final venue = ref.watch(venueProvider).value;
    final step = widget.step;
    final pendingTypes = {for (final c in step.pendingCerts) c.typeCode};
    final toUpload = [for (final c in step.missingCerts) if (!pendingTypes.contains(c) || step.status == StepStatus.needsChanges) c];
    final today = DateTime.now().toUtc();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (step.missingCerts.isEmpty && step.pendingCerts.isEmpty) EmptyNote(t.nothingNeeded),
      for (final c in step.pendingCerts)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.hourglass_top, color: AppColors.warn),
          title: Text(venue?.certName(c.typeCode) ?? c.typeCode),
          subtitle: Text(t.waitingForCheck),
        ),
      for (final code in toUpload)
        Builder(builder: (context) {
          final d = _drafts.putIfAbsent(code, _CardDraft.new);
          return Card(
            margin: const EdgeInsets.only(bottom: 16),
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.m),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(venue?.certName(code) ?? code, style: AppText.sectionHeading),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: FilledButton.tonalIcon(onPressed: () => _pick(d, ImageSource.camera), icon: const Icon(Icons.photo_camera), label: Text(t.takePhotoOfCard)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton.icon(onPressed: () => _pick(d, ImageSource.gallery), icon: const Icon(Icons.photo_library_outlined), label: Text(t.choosePhoto)),
                    ),
                  ),
                ]),
                if (d.file != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(children: [const Icon(Icons.check_circle, color: AppColors.good), const SizedBox(width: 6), Expanded(child: Text('${t.photoAdded}: ${d.file!.name}', overflow: TextOverflow.ellipsis))]),
                  ),
                const SizedBox(height: 12),
                TextField(controller: d.number, style: const TextStyle(fontSize: 17), decoration: InputDecoration(labelText: t.cardNumber)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 52,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.event),
                    label: Text(d.expires == null ? '${t.expiresOn}: ${t.chooseDate}' : '${t.expiresOn}: ${_fmt('MMM d, y', t.lang, d.expires!)}'),
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        firstDate: today,
                        lastDate: DateTime(today.year + 6),
                        initialDate: d.expires ?? DateTime(today.year + 2, today.month, today.day),
                      );
                      if (picked != null) setState(() => d.expires = DateTime.utc(picked.year, picked.month, picked.day));
                    },
                  ),
                ),
              ]),
            ),
          );
        }),
      if (toUpload.isNotEmpty)
        _BigButton(
          label: t.submit,
          busy: _busy,
          onPressed: () async {
            final ready = [for (final code in toUpload) if (_drafts[code]?.file != null) code];
            if (ready.isEmpty) {
              showMessage(context, t.addPhotoFirst);
              return;
            }
            setState(() => _busy = true);
            try {
              final session = ref.read(sessionProvider)!;
              final certs = <Map<String, dynamic>>[];
              final files = <String>[];
              for (final code in ready) {
                final d = _drafts[code]!;
                final bytes = await d.file!.readAsBytes();
                final path = await ref.people.uploadOnboardingFile(session, '$code-card.jpg', bytes, contentType: d.file!.mimeType ?? 'image/jpeg');
                files.add(path);
                certs.add({
                  'cert_type_code': code,
                  'number': d.number.text.trim(),
                  if (d.expires != null) 'expires_on': dateOnly(d.expires!),
                  'file_path': path,
                });
              }
              if (!context.mounted) return;
              final ok = await _submit(context, ref, step.code, {'certs': certs}, files: files);
              if (ok && context.mounted) Navigator.of(context).maybePop();
            } on AppFailure catch (e) {
              if (context.mounted) showMessage(context, e.message);
            } finally {
              if (mounted) setState(() => _busy = false);
            }
          },
        ),
    ]);
  }
}

class _BirthDateForm extends ConsumerStatefulWidget {
  const _BirthDateForm({required this.step});

  final OnboardingStepState step;

  @override
  ConsumerState<_BirthDateForm> createState() => _BirthDateFormState();
}

class _BirthDateFormState extends ConsumerState<_BirthDateForm> {
  DateTime? _dob;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(stringsProvider);
    if (widget.step.done) return Text(t.birthDateOnFile, style: AppText.body);
    final now = DateTime.now();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: 56,
        child: OutlinedButton.icon(
          icon: const Icon(Icons.cake_outlined),
          label: Text(_dob == null ? '${t.birthDate}: ${t.chooseDate}' : '${t.birthDate}: ${_fmt('MMM d, y', t.lang, _dob!)}', style: const TextStyle(fontSize: 17)),
          onPressed: () async {
            final picked = await showDatePicker(
              context: context,
              initialEntryMode: DatePickerEntryMode.input,
              firstDate: DateTime(1920),
              lastDate: now,
              initialDate: _dob ?? DateTime(now.year - 16),
            );
            if (picked != null) setState(() => _dob = DateTime.utc(picked.year, picked.month, picked.day));
          },
        ),
      ),
      const SizedBox(height: 16),
      _BigButton(
        label: t.submit,
        busy: _busy,
        onPressed: _dob == null
            ? null
            : () async {
                setState(() => _busy = true);
                final ok = await _submit(context, ref, widget.step.code, {'date_of_birth': dateOnly(_dob!)});
                if (mounted) setState(() => _busy = false);
                if (ok && context.mounted) Navigator.of(context).maybePop();
              },
      ),
    ]);
  }
}

class _ChecklistView extends ConsumerWidget {
  const _ChecklistView({required this.step});

  final OnboardingStepState step;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final done = step.itemsDone;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final i in step.items)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(done.contains(i.code) ? Icons.check_circle : Icons.radio_button_unchecked,
              color: done.contains(i.code) ? AppColors.good : AppColors.idle, size: 28),
          title: Text(i.label, style: const TextStyle(fontSize: 16)),
        ),
      const SizedBox(height: 8),
      Text(t.managerDoesThis, style: AppText.meta),
    ]);
  }
}

class _ExternalView extends ConsumerWidget {
  const _ExternalView({required this.step});

  final OnboardingStepState step;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final on = step.data['completed_on'] as String?;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (on != null)
        Row(children: [
          const Icon(Icons.check_circle, color: AppColors.good),
          const SizedBox(width: 8),
          Text('${t.statusLabel('complete')} · ${_fmt('MMM d, y', t.lang, DateTime.parse(on))}'),
        ])
      else
        Text(t.managerDoesThis, style: AppText.body),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Profile
// ---------------------------------------------------------------------------

class _ProfileTab extends ConsumerWidget {
  const _ProfileTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(stringsProvider);
    final session = ref.watch(sessionProvider)!;
    final venue = ref.watch(venueProvider).value;
    final workers = ref.watch(workersProvider);
    final workerId = session.workerId!;
    final certs = ref.watch(certsProvider(workerId)).value ?? const <CertRecord>[];
    final onboarding = ref.watch(myOnboardingProvider).value;
    return workers.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(workersProvider)),
      data: (all) {
        final w = all.where((w) => w.id == workerId).firstOrNull;
        if (w == null) return const SizedBox.shrink();
        final day = venueDate(DateTime.now().toUtc(), session.venue.timeZone);
        final required = {for (final r in w.jobRoles) ...?venue?.jobRole(r)?.requiredCertifications};
        final haveTypes = {for (final c in certs) c.typeCode};
        Widget row(String label, String value) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen, vertical: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 150, child: Text(label, style: AppText.meta.copyWith(fontWeight: FontWeight.w600))),
                Expanded(child: Text(value.isEmpty ? '—' : value, style: AppText.body)),
              ]),
            );
        return ListView(padding: const EdgeInsets.only(bottom: 40), children: [
          const SizedBox(height: 8),
          row(t.employeeNumber, w.employeeNumber),
          row(t.workerTypeLabel, t.typeName(w.type.code)),
          SectionHeading(t.roles),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
            child: Wrap(spacing: 8, runSpacing: 8, children: [for (final r in w.jobRoles) Chip(label: Text(venue?.roleName(r) ?? r))]),
          ),
          SectionHeading(t.certifications),
          if (certs.isEmpty && required.isEmpty) EmptyNote(t.noCertsNeeded),
          for (final c in certs)
            Builder(builder: (_) {
              final state = certState(c.expiresOn, day, session.rules.certifications);
              final (label, tone) = c.awaitingCheck
                  ? (t.waitingForCheck, Tone.warn)
                  : switch (state) {
                      CertificationState.ok => (t.certOk, Tone.good),
                      CertificationState.expiringSoon => (t.certExpiring, Tone.warn),
                      _ => (t.certExpired, Tone.bad),
                    };
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
                title: Text(venue?.certName(c.typeCode) ?? c.typeCode),
                subtitle: Text([
                  if (c.number.isNotEmpty) c.number,
                  c.expiresOn == null ? t.noExpiry : '${t.expiresOn} ${_fmt('MMM d, y', t.lang, c.expiresOn!)}',
                ].join(' · ')),
                trailing: StatusTag(label, tone),
              );
            }),
          for (final code in required.where((c) => !haveTypes.contains(c)))
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
              title: Text(venue?.certName(code) ?? code),
              trailing: StatusTag(t.certMissing, Tone.bad),
            ),
          SectionHeading(t.contact),
          row(t.phone, w.phone),
          row(t.email, w.email),
          row(t.emergencyName, [w.emergencyContactName, w.emergencyContactPhone].where((x) => x.isNotEmpty).join(' · ')),
          row(t.uniformSize, w.uniformSize),
          row(t.preferredLanguage, w.preferredLanguage == 'es' ? t.spanish : t.english),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.screen, AppSpace.m, AppSpace.screen, 0),
            child: Text(onboarding?.step('application') != null ? t.changeInApplication : t.askManagerToChange, style: AppText.meta),
          ),
        ]);
      },
    );
  }
}
