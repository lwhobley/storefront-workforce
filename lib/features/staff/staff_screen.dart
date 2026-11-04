import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/download.dart';
import '../../core/theme/app_theme.dart';
import '../../core/time/venue_time.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import '../../data/people_repository.dart';
import '../people/onboarding_screen.dart' show showPersonOnboarding;
import '../people/people_logic.dart';
import '../people/people_providers.dart';
import '../people/people_widgets.dart';
import '../people/pick_text_file.dart';
import '../performance/performance_section.dart';
import '../schedule/schedule_actions.dart';

/// Staff directory with trained roles and certification status. Managers add people one
/// at a time or import a roster, open a person to verify uploaded cards, follow their
/// onboarding, and give them a sign-in PIN.
class StaffScreen extends ConsumerStatefulWidget {
  const StaffScreen({super.key});

  @override
  ConsumerState<StaffScreen> createState() => _StaffScreenState();
}

/// Gives a staff member a sign-in PIN (or a new one) and shows it once.
Future<void> issuePinFlow(BuildContext context, WidgetRef ref, Worker w) async {
  final again = w.userId != null;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(again ? 'New PIN for ${w.displayName}?' : 'Give ${w.displayName} a sign-in PIN?'),
      content: Text(again
          ? 'Their current PIN stops working. The new PIN is shown once; hand it to them in person.'
          : 'They will sign in, clock in and finish onboarding with a 6-digit PIN. It is shown once; hand it to them in person.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(again ? 'Issue new PIN' : 'Create PIN')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  try {
    final pin = await ref.read(repositoryProvider).issuePin(ref.read(sessionProvider)!, w);
    ref.invalidate(workersProvider);
    ref.invalidate(onboardingOverviewProvider);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('PIN for ${w.displayName}'),
        content: SelectableText(pin, style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: 6)),
        actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
      ),
    );
  } on AppFailure catch (e) {
    if (context.mounted) showMessage(context, e.message);
  }
}

class _StaffScreenState extends ConsumerState<StaffScreen> {
  String _query = '';
  WorkerType? _type;
  bool _certIssues = false;

  Future<void> _addPerson(List<Worker> all) async {
    final person = await showDialog<NewPerson>(context: context, builder: (_) => _AddPersonDialog(existing: all));
    if (person == null || !mounted) return;
    try {
      final w = await ref.people.addWorker(ref.read(sessionProvider)!, person);
      ref.invalidate(workersProvider);
      ref.invalidate(onboardingOverviewProvider);
      if (!mounted) return;
      final pin = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${w.displayName} added'),
          content: const Text('Their onboarding has started. Create a sign-in PIN now so they can finish it on their phone?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Later')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Create sign-in PIN')),
          ],
        ),
      );
      if (pin == true && mounted) await issuePinFlow(context, ref, w);
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    }
  }

  Future<void> _import(List<Worker> all) async {
    final venue = ref.read(venueProvider).value;
    if (venue == null) return;
    final result = await showDialog<RosterImportResult>(context: context, builder: (_) => _ImportDialog(existing: all, venue: venue));
    if (result == null || !mounted) return;
    ref.invalidate(workersProvider);
    ref.invalidate(onboardingOverviewProvider);
    showMessage(context, '${result.added} added, ${result.updated} updated${result.skipped > 0 ? ', ${result.skipped} left as they were' : ''}');
  }

  @override
  Widget build(BuildContext context) {
    final workers = ref.watch(workersProvider);
    final venue = ref.watch(venueProvider).value;
    final session = ref.watch(sessionProvider)!;
    final canManage = session.canVenueWide(Perm.manageWorkers);
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
                    ScreenHeader(
                      kicker: session.venue.name,
                      title: 'Staff',
                      subtitle: '${all.length} people · ${shown.length} shown',
                      actions: [
                        if (session.canVenueWide(Perm.viewWorkers))
                          OutlinedButton.icon(
                            onPressed: () => context.push('/staff/rankings'),
                            icon: const Icon(Icons.leaderboard_outlined),
                            label: const Text('Rankings'),
                          ),
                      ],
                    ),
                    if (canManage)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(AppSpace.screen, 0, AppSpace.screen, AppSpace.m),
                        child: Wrap(spacing: 8, runSpacing: 8, children: [
                          FilledButton.icon(onPressed: () => _addPerson(all), icon: const Icon(Icons.person_add_alt_1), label: const Text('Add person')),
                          OutlinedButton.icon(onPressed: () => _import(all), icon: const Icon(Icons.upload_file), label: const Text('Import roster')),
                        ]),
                      ),
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
                  onTap: () => _showPerson(context, w.id),
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

  void _showPerson(BuildContext context, String workerId) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        constraints: const BoxConstraints(maxWidth: 720),
        builder: (context) => FractionallySizedBox(heightFactor: 0.9, child: _PersonSheet(workerId: workerId)),
      );
}

// ---------------------------------------------------------------------------
// Person detail
// ---------------------------------------------------------------------------

class _PersonSheet extends ConsumerWidget {
  const _PersonSheet({required this.workerId});

  final String workerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider)!;
    final venue = ref.watch(venueProvider).value;
    final w = ref.watch(workersProvider).value?.where((w) => w.id == workerId).firstOrNull;
    if (w == null) return const Center(child: CircularProgressIndicator());
    final canManage = session.canVenueWide(Perm.manageWorkers);
    final certs = ref.watch(certsProvider(workerId));
    final onboarding = ref.watch(workerOnboardingProvider(workerId));
    final day = venueDate(DateTime.now().toUtc(), session.venue.timeZone);
    final age = w.ageOn(day);
    final org = w.type == WorkerType.temp ? venue?.agencyName(w.agencyId) : w.type == WorkerType.npo ? venue?.npoName(w.npoGroupId) : '';
    final requiredCerts = {for (final r in w.jobRoles) ...?venue?.jobRole(r)?.requiredCertifications};
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 140, child: Text(label, style: AppText.meta.copyWith(fontWeight: FontWeight.w600))),
            Expanded(child: SelectableText(value.isEmpty ? '—' : value, style: AppText.body)),
          ]),
        );

    return ListView(padding: const EdgeInsets.fromLTRB(AppSpace.screen, 0, AppSpace.screen, 40), children: [
      Text(w.displayName, style: AppText.screenTitle.copyWith(fontSize: 26)),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        StatusTag(workerTypeLabel(w.type), w.type == WorkerType.regular ? Tone.idle : Tone.info),
        if (age != null && age < session.rules.minors.adultAge) StatusTag('Minor $age', Tone.warn),
        StatusTag(w.userId == null ? 'No sign-in' : 'Has sign-in', w.userId == null ? Tone.idle : Tone.good),
        if (w.status != 'active') const StatusTag('Inactive', Tone.idle),
      ]),
      const SizedBox(height: 12),
      row('Employee number', w.employeeNumber),
      if (org != null && org.isNotEmpty) row(w.type == WorkerType.temp ? 'Agency' : 'NPO group', org),
      if (w.type == WorkerType.regular) row('Paycom code', w.paycomEmployeeCode),
      row('Birth date', w.dateOfBirth == null ? '' : '${DateFormat('MMM d, y').format(w.dateOfBirth!)} (age $age)'),
      row('Hire date', w.hireDate == null ? '' : DateFormat('MMM d, y').format(w.hireDate!)),
      row('Phone', w.phone),
      row('Email', w.email),
      row('Emergency contact', [w.emergencyContactName, w.emergencyContactPhone].where((x) => x.isNotEmpty).join(' · ')),
      row('Uniform', w.uniformSize),
      row('Language', w.preferredLanguage == 'es' ? 'Spanish' : 'English'),
      SectionHeading('Trained roles'),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final r in w.jobRoles) Chip(label: Text(venue?.roleName(r) ?? r)),
        if (w.jobRoles.isEmpty) const Text('None yet', style: AppText.meta),
      ]),
      SectionHeading('Certifications'),
      certs.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => ErrorNote(e),
        data: (list) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (list.isEmpty && requiredCerts.isEmpty) const Text('None needed for their roles.', style: AppText.meta),
          for (final code in requiredCerts.where((c) => !list.any((x) => x.typeCode == c)))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(venue?.certName(code) ?? code),
              trailing: const StatusTag('Missing', Tone.bad),
            ),
          for (final c in list)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (c.awaitingCheck && c.documentPath != null) CardPhoto(path: c.documentPath!, label: venue?.certName(c.typeCode) ?? c.typeCode, height: 110),
                ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 220),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(venue?.certName(c.typeCode) ?? c.typeCode, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                    Text('${c.number.isEmpty ? 'No number' : c.number} · ${c.expiresOn == null ? 'no expiry' : 'expires ${DateFormat('MMM d, y').format(c.expiresOn!)}'}', style: AppText.meta),
                    const SizedBox(height: 4),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      if (c.awaitingCheck)
                        const StatusTag('Uploaded, not checked', Tone.warn)
                      else
                        switch (certState(c.expiresOn, day, session.rules.certifications)) {
                          CertificationState.ok => const StatusTag('Current', Tone.good),
                          CertificationState.expiringSoon => const StatusTag('Expiring soon', Tone.warn),
                          _ => const StatusTag('Expired', Tone.bad),
                        },
                      if (c.awaitingCheck && canManage) ...[
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          onPressed: () async {
                            try {
                              await ref.people.verifyCertification(session, c.id);
                              ref.invalidate(certsProvider(workerId));
                              ref.invalidate(workerOnboardingProvider(workerId));
                              ref.invalidate(onboardingOverviewProvider);
                              if (context.mounted) showMessage(context, 'Card verified');
                            } on AppFailure catch (e) {
                              if (context.mounted) showMessage(context, e.message);
                            }
                          },
                          child: const Text('Verify'),
                        ),
                      ],
                    ]),
                  ]),
                ),
              ]),
            ),
        ]),
      ),
      SectionHeading('Onboarding'),
      onboarding.when(
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => ErrorNote(e),
        data: (s) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(s.finished ? 'Finished' : '${s.done} of ${s.required} steps · open ${s.daysOpen} days${s.needsReview ? ' · needs review' : ''}', style: AppText.body),
          const SizedBox(height: 6),
          OnboardingBar(state: s),
          if (s.missing.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Missing: ${s.missing.join(', ')}', style: AppText.meta)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: () => showPersonOnboarding(context, workerId), icon: const Icon(Icons.task_alt), label: const Text('Open onboarding')),
          ),
        ]),
      ),
      if (session.canVenueWide(Perm.viewWorkers)) ...[
        SectionHeading('Performance'),
        PerformanceSection(worker: w),
      ],
      if (canManage) ...[
        SectionHeading('Sign-in'),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: () => issuePinFlow(context, ref, w),
            icon: const Icon(Icons.pin_outlined),
            label: Text(w.userId == null ? 'Create sign-in PIN' : 'Issue new PIN'),
          ),
        ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Add person
// ---------------------------------------------------------------------------

class _AddPersonDialog extends ConsumerStatefulWidget {
  const _AddPersonDialog({required this.existing});

  final List<Worker> existing;

  @override
  ConsumerState<_AddPersonDialog> createState() => _AddPersonDialogState();
}

class _AddPersonDialogState extends ConsumerState<_AddPersonDialog> {
  WorkerType _type = WorkerType.regular;
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _preferred = TextEditingController();
  final _number = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _paycom = TextEditingController();
  bool _numberEdited = false;
  DateTime? _dob;
  DateTime? _hire = DateTime.utc(DateTime.now().year, DateTime.now().month, DateTime.now().day);
  final Set<String> _roles = {};
  String? _agency;
  String? _npo;
  String _lang = 'en';
  String? _error;

  @override
  void initState() {
    super.initState();
    _suggest();
  }

  void _suggest() {
    if (!_numberEdited) _number.text = suggestEmployeeNumber(_type, widget.existing.map((w) => w.employeeNumber));
  }

  @override
  void dispose() {
    for (final c in [_first, _last, _preferred, _number, _phone, _email, _paycom]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<DateTime?> _pickDate(DateTime? initial, {required DateTime first, required DateTime last}) async {
    final d = await showDatePicker(context: context, initialEntryMode: DatePickerEntryMode.input, firstDate: first, lastDate: last, initialDate: initial ?? last);
    return d == null ? null : DateTime.utc(d.year, d.month, d.day);
  }

  void _save() {
    final number = _number.text.trim().toUpperCase();
    String? error;
    if (_first.text.trim().isEmpty || _last.text.trim().isEmpty) {
      error = 'Enter a first and last name.';
    } else if (!RegExp(r'^[A-Z0-9-]{2,20}$').hasMatch(number)) {
      error = 'Employee numbers are 2 to 20 letters, digits or dashes.';
    } else if (widget.existing.any((w) => w.employeeNumber == number)) {
      error = 'Employee number $number is already used.';
    } else if (_type == WorkerType.temp && _agency == null) {
      error = 'Choose the temp agency.';
    } else if (_type == WorkerType.npo && _npo == null) {
      error = 'Choose the NPO group.';
    } else if (_roles.isEmpty) {
      error = 'Choose at least one trained role.';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(
      context,
      NewPerson(
        type: _type,
        employeeNumber: number,
        firstName: _first.text.trim(),
        lastName: _last.text.trim(),
        preferredName: _preferred.text.trim(),
        dateOfBirth: _dob,
        phone: _phone.text.trim(),
        email: _email.text.trim(),
        jobRoles: _roles.toList(),
        agencyId: _agency,
        npoGroupId: _npo,
        paycomEmployeeCode: _paycom.text.trim(),
        hireDate: _hire,
        preferredLanguage: _lang,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(venueProvider).value;
    final now = DateTime.now();
    final f = DateFormat('MMM d, y');
    Widget gap() => const SizedBox(height: 10);
    return AlertDialog(
      title: const Text('Add person'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<WorkerType>(
              segments: const [
                ButtonSegment(value: WorkerType.regular, label: Text('Staff')),
                ButtonSegment(value: WorkerType.temp, label: Text('Temp')),
                ButtonSegment(value: WorkerType.npo, label: Text('NPO')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() {
                _type = s.first;
                _suggest();
              }),
            ),
            gap(),
            Row(children: [
              Expanded(child: TextField(controller: _first, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'First name *'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _last, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Last name *'))),
            ]),
            gap(),
            Row(children: [
              Expanded(child: TextField(controller: _preferred, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Preferred name'))),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _number,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Employee number *', helperText: 'Suggested; change if needed'),
                  onChanged: (_) => _numberEdited = true,
                ),
              ),
            ]),
            gap(),
            if (_type == WorkerType.temp)
              DropdownButtonFormField<String>(
                initialValue: _agency,
                decoration: const InputDecoration(labelText: 'Temp agency *'),
                items: [for (final a in venue?.agencies ?? const <TempAgency>[]) DropdownMenuItem(value: a.id, child: Text(a.name))],
                onChanged: (v) => setState(() => _agency = v),
              ),
            if (_type == WorkerType.npo)
              DropdownButtonFormField<String>(
                initialValue: _npo,
                decoration: const InputDecoration(labelText: 'NPO group *'),
                items: [for (final g in venue?.npoGroups ?? const <NpoGroup>[]) DropdownMenuItem(value: g.id, child: Text(g.displayName))],
                onChanged: (v) => setState(() => _npo = v),
              ),
            if (_type == WorkerType.regular) TextField(controller: _paycom, decoration: const InputDecoration(labelText: 'Paycom employee code')),
            gap(),
            Row(children: [
              Expanded(child: TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone'))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email'))),
            ]),
            gap(),
            Wrap(spacing: 8, runSpacing: 8, children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.cake_outlined),
                label: Text(_dob == null ? 'Birth date' : 'Born ${f.format(_dob!)}'),
                onPressed: () async {
                  final d = await _pickDate(_dob ?? DateTime(now.year - 20), first: DateTime(1920), last: DateTime(now.year - 14, now.month, now.day));
                  if (d != null) setState(() => _dob = d);
                },
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.event_available),
                label: Text(_hire == null ? 'Hire date' : 'Hired ${f.format(_hire!)}'),
                onPressed: () async {
                  final d = await _pickDate(_hire, first: DateTime(2000), last: DateTime(now.year + 1, 12, 31));
                  if (d != null) setState(() => _hire = d);
                },
              ),
            ]),
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('A birth date lets the schedule apply the rules for minors and minimum ages.', style: AppText.meta),
            ),
            gap(),
            const Text('Trained roles *', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final r in venue?.jobRoles ?? const <JobRole>[])
                FilterChip(label: Text(r.name), selected: _roles.contains(r.code), onSelected: (v) => setState(() => v ? _roles.add(r.code) : _roles.remove(r.code))),
            ]),
            gap(),
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'en', label: Text('English')), ButtonSegment(value: 'es', label: Text('Spanish'))],
              selected: {_lang},
              onSelectionChanged: (s) => setState(() => _lang = s.first),
            ),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: AppColors.bad, fontWeight: FontWeight.w600))),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Add person')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Import roster
// ---------------------------------------------------------------------------

class _ImportDialog extends ConsumerStatefulWidget {
  const _ImportDialog({required this.existing, required this.venue});

  final List<Worker> existing;
  final VenueContext venue;

  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<_ImportDialog> {
  final _text = TextEditingController();
  RosterPreview? _preview;
  bool _update = false;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _check() {
    final today = venueDate(DateTime.now().toUtc(), widget.venue.venue.timeZone);
    setState(() {
      _preview = parseRoster(_text.text, venue: widget.venue, existingNumbers: widget.existing.map((w) => w.employeeNumber), today: today);
      _update = false;
    });
  }

  Future<void> _import() async {
    final p = _preview!;
    if (p.updateCount > 0 && _update) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Update ${p.updateCount == 1 ? 'one person' : '${p.updateCount} people'} already on file?'),
          content: const Text('Their names, type, contact details, birth date, roles, agency or group, Paycom code and hire date are replaced with the file\'s values.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Update them')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    try {
      final result = await ref.people.importRoster(ref.read(sessionProvider)!, [for (final r in p.valid) r.person!], updateExisting: _update);
      if (mounted) Navigator.pop(context, result);
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _preview;
    final importable = p == null ? 0 : p.newCount + (_update ? p.updateCount : 0);
    return AlertDialog(
      title: const Text('Import roster'),
      content: SizedBox(
        width: 720,
        child: p == null
            ? SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text(
                    'Paste a CSV or choose a file. Columns: employee_number, first_name, last_name, type (regular, temp or npo), '
                    'phone, email, date_of_birth, roles (separated by ;), paycom_code, agency, npo_group, hire_date. Dates as yyyy-mm-dd.',
                    style: AppText.meta,
                  ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, children: [
                    if (canPickTextFile)
                      OutlinedButton.icon(
                        onPressed: () async {
                          final text = await pickTextFile();
                          if (text != null) {
                            _text.text = text;
                            _check();
                          }
                        },
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Choose file'),
                      ),
                    TextButton.icon(
                      onPressed: () async {
                        final ok = await saveTextFile('roster-template.csv', rosterTemplate);
                        if (context.mounted) showMessage(context, ok ? 'Template downloaded' : 'Template copied to the clipboard');
                      },
                      icon: const Icon(Icons.download),
                      label: const Text('Template'),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _text,
                    minLines: 8,
                    maxLines: 14,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    decoration: const InputDecoration(hintText: 'employee_number,first_name,last_name,type,...', alignLabelWithHint: true),
                  ),
                ]),
              )
            : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final problem in p.problems) Text(problem, style: AppText.meta.copyWith(color: AppColors.warn)),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  StatusTag('${p.newCount} new', Tone.good),
                  StatusTag('${p.updateCount} already on file', p.updateCount > 0 ? Tone.info : Tone.idle),
                  StatusTag('${p.invalid.length} with errors', p.invalid.isEmpty ? Tone.idle : Tone.bad),
                ]),
                if (p.updateCount > 0)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _update,
                    onChanged: (v) => setState(() => _update = v ?? false),
                    title: Text('Update the ${p.updateCount == 1 ? 'person' : '${p.updateCount} people'} already on file (matched by employee number)'),
                    subtitle: const Text('Unticked, they are left as they are.'),
                  ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(shrinkWrap: true, children: [
                    for (final r in [...p.invalid, ...p.valid])
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(r.valid ? (r.isUpdate ? Icons.sync : Icons.add_circle_outline) : Icons.error_outline,
                            color: r.valid ? (r.isUpdate ? AppColors.accent : AppColors.good) : AppColors.bad),
                        title: Text('Line ${r.line}: ${r.cells['employee_number'] ?? ''} ${r.name}'),
                        subtitle: Text(r.valid ? (r.isUpdate ? 'Updates the person on file' : 'New ${workerTypeLabel(r.person!.type).toLowerCase()}') : r.errors.join(' · '),
                            style: TextStyle(color: r.valid ? null : AppColors.bad)),
                      ),
                  ]),
                ),
              ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (p == null)
          FilledButton(onPressed: _check, child: const Text('Check'))
        else ...[
          TextButton(onPressed: () => setState(() => _preview = null), child: const Text('Back')),
          FilledButton(
            onPressed: importable == 0 || _busy ? null : _import,
            child: Text('Import $importable ${importable == 1 ? 'person' : 'people'}'),
          ),
        ],
      ],
    );
  }
}
