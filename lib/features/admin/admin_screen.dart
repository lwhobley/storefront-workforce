import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/admin_repository.dart';
import '../../data/models.dart';

AdminRepository _admin(WidgetRef ref) => ref.read(repositoryProvider) as AdminRepository;

final retentionProvider = FutureProvider.autoDispose<RetentionPolicy>((ref) {
  final session = ref.watch(sessionProvider)!;
  return _adminOf(ref).loadRetention(session);
});

final retentionDueProvider = FutureProvider.autoDispose<RetentionDue>((ref) {
  final session = ref.watch(sessionProvider)!;
  return _adminOf(ref).retentionDue(session);
});

final deletionRequestsProvider = FutureProvider.autoDispose<List<DeletionRequest>>((ref) {
  final session = ref.watch(sessionProvider)!;
  return _adminOf(ref).loadDeletionRequests(session);
});

final myVenuesProvider = FutureProvider.autoDispose<List<VenueSummary>>((ref) {
  final session = ref.watch(sessionProvider)!;
  return _adminOf(ref).listMyVenues(session);
});

AdminRepository _adminOf(Ref ref) => ref.read(repositoryProvider) as AdminRepository;

/// A yes/no question before something that cannot be undone.
Future<bool> _confirm(BuildContext context, {required String title, required String message, required String action}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(action)),
      ],
    ),
  );
  return ok ?? false;
}

/// Venue admin: name and branding, how long records are kept, and requests to remove
/// someone's personal data.
class AdminScreen extends ConsumerWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider)!;
    final canSettings = session.canVenueWide('manage_settings');
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(retentionProvider);
            ref.invalidate(retentionDueProvider);
            ref.invalidate(deletionRequestsProvider);
          },
          child: ListView(
            padding: const EdgeInsets.only(bottom: 48),
            children: [
              ScreenHeader(kicker: session.venue.name, title: 'Admin'),
              const _CompanyCard(),
              if (canSettings) ...[
                const SectionHeading('Venue and branding'),
                _VenueCard(),
              ],
              const SectionHeading('Keeping records'),
              _RetentionCard(canEdit: canSettings),
              const SectionHeading('Personal data requests'),
              _DeletionCard(canDecide: canSettings),
            ],
          ),
        ),
      ),
    );
  }
}

/// The company this venue belongs to, and the other venues this person can work in.
class _CompanyCard extends ConsumerWidget {
  const _CompanyCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider)!;
    final venues = ref.watch(myVenuesProvider);
    return venues.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(myVenuesProvider)),
      data: (list) {
        final company = list.firstWhere(
          (v) => v.id == session.venue.id,
          orElse: () => VenueSummary(id: session.venue.id, name: session.venue.name, organizationId: session.venue.organizationId),
        );
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionHeading(company.organizationName.isEmpty ? 'Company' : company.organizationName),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
            child: Text(
              list.length < 2
                  ? 'You work in one venue: ${session.venue.name}.'
                  : 'You work in ${list.length} venues. Everything else on this screen applies to the one you are in.',
              style: AppText.meta,
            ),
          ),
          for (final v in list)
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
              title: Text(v.name),
              trailing: v.id == session.venue.id
                  ? const StatusTag('Current', Tone.good)
                  : TextButton(onPressed: () => _switch(context, ref, v), child: const Text('Switch')),
            ),
        ]);
      },
    );
  }

  Future<void> _switch(BuildContext context, WidgetRef ref, VenueSummary venue) async {
    try {
      await _admin(ref).switchVenue(ref.read(sessionProvider)!, venue.id);
      // The repository remembers the choice; restoring rebuilds the session around it.
      await ref.read(sessionProvider.notifier).restore();
      ref.invalidate(myVenuesProvider);
      if (context.mounted) showMessage(context, 'Now in ${venue.name}');
    } on AppFailure catch (e) {
      if (context.mounted) showMessage(context, e.message);
    }
  }
}

class _VenueCard extends ConsumerStatefulWidget {
  @override
  ConsumerState<_VenueCard> createState() => _VenueCardState();
}

class _VenueCardState extends ConsumerState<_VenueCard> {
  late final _name = TextEditingController(text: ref.read(sessionProvider)!.venue.name);
  late final _appName = TextEditingController(text: (_branding['app_name'] as String?) ?? '');
  late final _color = TextEditingController(text: (_branding['primary_color'] as String?) ?? '');
  bool _saving = false;

  Map<String, dynamic> get _branding => ref.read(sessionProvider)!.venue.branding;

  @override
  void dispose() {
    for (final c in [_name, _appName, _color]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final session = ref.read(sessionProvider)!;
    final color = _color.text.trim();
    if (color.isNotEmpty && !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(color)) {
      showMessage(context, 'Use a colour like #1D4ED8, or leave it blank.');
      return;
    }
    setState(() => _saving = true);
    try {
      await _admin(ref).saveVenueProfile(
        session,
        name: _name.text.trim(),
        branding: {
          ..._branding,
          if (_appName.text.trim().isEmpty) 'app_name': null else 'app_name': _appName.text.trim(),
          if (color.isEmpty) 'primary_color': null else 'primary_color': color,
        }..removeWhere((_, v) => v == null),
      );
      if (mounted) showMessage(context, 'Saved. Sign in again to see the new branding.');
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Venue name')),
        TextField(
          controller: _appName,
          decoration: const InputDecoration(labelText: 'App name', helperText: 'Shown in the title bar; blank uses the default'),
        ),
        TextField(
          controller: _color,
          decoration: const InputDecoration(labelText: 'Accent colour', hintText: '#1D4ED8', helperText: 'Blank uses the default'),
        ),
        const SizedBox(height: 12),
        FilledButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
        const SizedBox(height: 8),
        Text('Status colours (green, amber, red) never change, so they always mean the same thing.', style: AppText.meta),
      ]),
    );
  }
}

class _RetentionCard extends ConsumerWidget {
  const _RetentionCard({required this.canEdit});

  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy = ref.watch(retentionProvider);
    final due = ref.watch(retentionDueProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
      child: policy.when(
        loading: () => const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
        error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(retentionProvider)),
        data: (p) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'Time and pay records are kept ${_years(p.timeRecordsMonths)}. Clock-in photos are kept '
            '${_years(p.punchPhotoMonths)}. A staff record may be cleared ${_years(p.inactiveWorkerMonths)} after '
            'someone last worked.',
          ),
          const SizedBox(height: 4),
          Text('Wage and hour records must be kept at least two years, so that is the lowest you can set.', style: AppText.meta),
          const SizedBox(height: 12),
          due.when(
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
            data: (d) => d.isEmpty
                ? Text('Nothing is past its retention period.', style: AppText.meta)
                : Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    if (d.punchPhotos > 0) StatusTag('${d.punchPhotos} clock-in photos past their period', Tone.warn),
                    if (d.inactiveWorkers > 0) StatusTag('${d.inactiveWorkers} staff records may be cleared', Tone.warn),
                  ]),
          ),
          if (canEdit) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                onPressed: () => _edit(context, ref, p),
                icon: const Icon(Icons.tune),
                label: const Text('Change periods'),
              ),
              if (due.value != null && due.value!.punchPhotos > 0)
                OutlinedButton.icon(
                  onPressed: () => _purge(context, ref),
                  icon: const Icon(Icons.auto_delete_outlined),
                  label: const Text('Clear old photos'),
                ),
            ]),
          ],
        ]),
      ),
    );
  }

  static String _years(int months) {
    if (months % 12 == 0) {
      final y = months ~/ 12;
      return '$y year${y == 1 ? '' : 's'}';
    }
    return '$months months';
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, RetentionPolicy current) async {
    final chosen = await showDialog<RetentionPolicy>(context: context, builder: (_) => _RetentionDialog(current: current));
    if (chosen == null) return;
    try {
      await _admin(ref).saveRetention(ref.read(sessionProvider)!, chosen);
      ref.invalidate(retentionProvider);
      ref.invalidate(retentionDueProvider);
      if (context.mounted) showMessage(context, 'Saved');
    } on AppFailure catch (e) {
      if (context.mounted) showMessage(context, e.message);
    }
  }

  Future<void> _purge(BuildContext context, WidgetRef ref) async {
    final ok = await _confirm(
      context,
      title: 'Clear old clock-in photos?',
      message: 'The photos go; the clock-in times stay. This cannot be undone.',
      action: 'Clear',
    );
    if (!ok) return;
    try {
      final n = await _admin(ref).purgeOldPunchPhotos(ref.read(sessionProvider)!);
      ref.invalidate(retentionDueProvider);
      if (context.mounted) showMessage(context, 'Cleared $n photo${n == 1 ? '' : 's'}');
    } on AppFailure catch (e) {
      if (context.mounted) showMessage(context, e.message);
    }
  }
}

class _RetentionDialog extends StatefulWidget {
  const _RetentionDialog({required this.current});

  final RetentionPolicy current;

  @override
  State<_RetentionDialog> createState() => _RetentionDialogState();
}

class _RetentionDialogState extends State<_RetentionDialog> {
  late final _time = TextEditingController(text: '${widget.current.timeRecordsMonths}');
  late final _photos = TextEditingController(text: '${widget.current.punchPhotoMonths}');
  late final _workers = TextEditingController(text: '${widget.current.inactiveWorkerMonths}');
  String? _error;

  @override
  void dispose() {
    for (final c in [_time, _photos, _workers]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final t = int.tryParse(_time.text.trim());
    final p = int.tryParse(_photos.text.trim());
    final w = int.tryParse(_workers.text.trim());
    if (t == null || p == null || w == null) {
      setState(() => _error = 'Enter each period as a number of months.');
      return;
    }
    final policy = RetentionPolicy(timeRecordsMonths: t, punchPhotoMonths: p, inactiveWorkerMonths: w);
    final problem = policy.validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.of(context).pop(policy);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('How long to keep records'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: _time, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Time and pay records (months)')),
        TextField(controller: _photos, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Clock-in photos (months)')),
        TextField(controller: _workers, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Staff records after last shift (months)')),
        if (_error != null) ...[const SizedBox(height: 8), Text(_error!, style: AppText.meta)],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class _DeletionCard extends ConsumerWidget {
  const _DeletionCard({required this.canDecide});

  final bool canDecide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requests = ref.watch(deletionRequestsProvider);
    final workers = ref.watch(workersProvider).value ?? const [];
    final names = {for (final w in workers) w.id: w.displayName};
    final date = DateFormat('MMM d, yyyy');

    return requests.when(
      loading: () => const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
      error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(deletionRequestsProvider)),
      data: (rows) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.screen),
          child: Text(
            'Approving a request removes the person\'s name, contact details and photos. Their hours, '
            'pay and audit history stay, so payroll records are still complete.',
            style: AppText.meta,
          ),
        ),
        if (rows.isEmpty) const EmptyNote('No requests.'),
        for (final r in rows)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.screen, vertical: 4),
            title: Text(names[r.workerId] ?? 'Staff member'),
            isThreeLine: r.note.isNotEmpty || r.decisionNote.isNotEmpty,
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Asked ${date.format(r.requestedAt)}${r.requestedByMe ? ' by you' : ''}'),
              if (r.note.isNotEmpty) Text(r.note, style: AppText.meta),
              if (r.decisionNote.isNotEmpty) Text('Decision: ${r.decisionNote}', style: AppText.meta),
            ]),
            trailing: r.isPending
                ? (canDecide && !r.requestedByMe
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        TextButton(onPressed: () => _approve(context, ref, r), child: const Text('Approve')),
                        TextButton(onPressed: () => _refuse(context, ref, r), child: const Text('Refuse')),
                      ])
                    : StatusTag(r.requestedByMe ? 'Waiting for another admin' : 'Pending', Tone.warn))
                : StatusTag(r.status, r.status == 'completed' ? Tone.idle : Tone.bad),
          ),
      ]),
    );
  }

  Future<void> _approve(BuildContext context, WidgetRef ref, DeletionRequest r) async {
    final ok = await _confirm(
      context,
      title: 'Remove personal data?',
      message: 'Their name, contact details and photos go for good. Hours and pay stay. This cannot be undone.',
      action: 'Remove',
    );
    if (!ok) return;
    try {
      await _admin(ref).approveDataDeletion(ref.read(sessionProvider)!, r.id);
      ref.invalidate(deletionRequestsProvider);
      ref.invalidate(workersProvider);
      if (context.mounted) showMessage(context, 'Personal data removed');
    } on AppFailure catch (e) {
      if (context.mounted) showMessage(context, e.message);
    }
  }

  Future<void> _refuse(BuildContext context, WidgetRef ref, DeletionRequest r) async {
    final reason = await askReason(
      context,
      title: 'Refuse this request',
      hint: 'Reason',
      action: 'Refuse',
      suggestions: const ['Still inside the retention period', 'Open pay period', 'Needs more detail'],
    );
    if (reason == null || reason.trim().isEmpty) return;
    try {
      await _admin(ref).refuseDataDeletion(ref.read(sessionProvider)!, r.id, reason);
      ref.invalidate(deletionRequestsProvider);
      if (context.mounted) showMessage(context, 'Refused');
    } on AppFailure catch (e) {
      if (context.mounted) showMessage(context, e.message);
    }
  }
}

