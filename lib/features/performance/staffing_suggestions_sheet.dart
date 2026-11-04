import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../app/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';
import '../../data/models.dart';
import 'performance_providers.dart';

/// Opens the staffing suggestions for an event: headcount by role per open storefront,
/// from past similar events, each with a one-line reason and "Use suggestion".
Future<void> showStaffingSuggestions(BuildContext context, String eventId) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 760),
      builder: (_) => FractionallySizedBox(heightFactor: 0.9, child: StaffingSuggestionsSheet(eventId: eventId)),
    );

/// One role at one storefront where the suggestion differs from the current need.
class _Change {
  const _Change(this.storefrontId, this.role, this.from, this.to);

  final String storefrontId;
  final String role;
  final int from;
  final int to;
}

class StaffingSuggestionsSheet extends ConsumerStatefulWidget {
  const StaffingSuggestionsSheet({super.key, required this.eventId});

  final String eventId;

  @override
  ConsumerState<StaffingSuggestionsSheet> createState() => _StaffingSuggestionsSheetState();
}

class _StaffingSuggestionsSheetState extends ConsumerState<StaffingSuggestionsSheet> {
  bool _busy = false;

  Future<void> _apply(List<_Change> changes, String done) async {
    if (changes.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ref.read(boardProvider(widget.eventId).notifier).run((repo) async {
        for (final c in changes) {
          await repo.setStaffingNeed(widget.eventId, c.storefrontId, c.role, c.to);
        }
      });
      if (mounted) showMessage(context, done);
    } on AppFailure catch (e) {
      if (mounted) showMessage(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final board = ref.watch(boardProvider(widget.eventId)).value;
    final venue = ref.watch(venueProvider).value;
    if (board == null || venue == null) return const Center(child: CircularProgressIndicator());
    final event = board.event;
    final history = ref.watch(staffingHistoryProvider(event.eventTypeCode));
    final typeName = venue.eventTypes[event.eventTypeCode] ?? event.eventTypeCode;

    return history.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => ErrorNote(e, onRetry: () => ref.invalidate(staffingHistoryProvider(event.eventTypeCode))),
      data: (past) {
        final open = [
          for (final s in venue.storefronts)
            if (board.openStorefrontIds.contains(s.id)) s,
        ];
        final suggestions = suggestStaffing(
          eventTypeCode: event.eventTypeCode,
          typeName: typeName,
          expectedAttendance: event.expectedAttendance,
          storefrontIds: open.map((s) => s.id),
          history: past,
          defaults: venue.defaultNeeds,
          excludeEventId: event.id,
        );
        int current(String sf, String role) =>
            board.needs.where((n) => n.storefrontId == sf && n.jobRoleCode == role).fold(0, (s, n) => s + n.count);
        int roleSort(String code) => venue.jobRole(code)?.sort ?? 99;

        final allChanges = <_Change>[];
        for (final sf in open) {
          final s = suggestions[sf.id];
          if (s == null) continue;
          for (final MapEntry(key: role, value: to) in s.counts.entries) {
            final from = current(sf.id, role);
            if (from != to) allChanges.add(_Change(sf.id, role, from, to));
          }
        }
        final similar = similarEvents(
          eventTypeCode: event.eventTypeCode,
          expectedAttendance: event.expectedAttendance,
          history: past,
          excludeEventId: event.id,
        );

        return ListView(
          padding: const EdgeInsets.fromLTRB(AppSpace.screen, 0, AppSpace.screen, 40),
          children: [
            Text('Staffing suggestions', style: AppText.screenTitle.copyWith(fontSize: 26)),
            const SizedBox(height: 4),
            Text(
              '${formatCount(event.expectedAttendance)} expected · '
              '${similar.isEmpty ? 'no similar past ${typeName.toLowerCase()}s yet' : 'compared with ${similar.length} past ${typeName.toLowerCase()}${similar.length == 1 ? '' : 's'} with a similar crowd'}',
              style: AppText.meta,
            ),
            const SizedBox(height: 4),
            const Text(
              'Headcount that worked at past events of the same type, scaled to this crowd. '
              'Storefronts with no similar event keep their usual staffing.',
              style: AppText.meta,
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.icon(
                onPressed: _busy || allChanges.isEmpty
                    ? null
                    : () => _apply(allChanges, '${allChanges.length} headcount${allChanges.length == 1 ? '' : 's'} updated'),
                icon: const Icon(Icons.auto_fix_high),
                label: Text(allChanges.isEmpty ? 'Matches the suggestions' : 'Use all suggestions (${allChanges.length})'),
              ),
            ]),
            if (open.isEmpty) const EmptyNote('No storefronts are open for this event yet.'),
            for (final sf in open)
              Builder(builder: (context) {
                final s = suggestions[sf.id]!;
                final roles = {...s.counts.keys, for (final n in board.needs) if (n.storefrontId == sf.id) n.jobRoleCode}.toList()
                  ..sort((a, b) => roleSort(a).compareTo(roleSort(b)));
                final changes = [for (final c in allChanges) if (c.storefrontId == sf.id) c];
                return Card(
                  margin: const EdgeInsets.only(top: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.m),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        Expanded(child: Text(sf.name, style: AppText.body.copyWith(fontWeight: FontWeight.w700))),
                        if (changes.isEmpty)
                          const StatusTag('Matches', Tone.good, icon: Icons.check)
                        else
                          FilledButton.tonal(
                            onPressed: _busy ? null : () => _apply(changes, '${sf.name}: suggestion used'),
                            child: const Text('Use suggestion'),
                          ),
                      ]),
                      const SizedBox(height: 2),
                      Text(s.explanation, style: AppText.meta.copyWith(color: s.fallback ? AppColors.warn : AppColors.muted)),
                      const SizedBox(height: 6),
                      Wrap(spacing: 8, runSpacing: 6, children: [
                        for (final role in roles)
                          Builder(builder: (context) {
                            final now = current(sf.id, role);
                            final to = s.counts[role];
                            final differs = to != null && to != now;
                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: differs ? AppColors.warnSoft : null,
                                border: Border.all(color: AppColors.divider),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                differs ? '${venue.roleName(role)}  $now → $to' : '${venue.roleName(role)}  $now',
                                style: AppText.meta.copyWith(color: AppColors.text, fontWeight: differs ? FontWeight.w700 : FontWeight.w400),
                              ),
                            );
                          }),
                      ]),
                    ]),
                  ),
                );
              }),
          ],
        );
      },
    );
  }
}
