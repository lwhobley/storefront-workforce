/// Manager Copilot AI: Conversational natural-language operations assistant for
/// arena concessions managers.
///
/// Interprets plain English and Spanish queries during event night and provides instant
/// answers, live concourse status, compliance audits, and deep-link action shortcuts.
library;

import '../model/entities.dart';
import '../model/enums.dart';

class CopilotActionPill {
  const CopilotActionPill({
    required this.label,
    required this.route,
    this.iconName = 'arrow_forward',
  });

  final String label;
  final String route;
  final String iconName;
}

class CopilotResponse {
  const CopilotResponse({
    required this.query,
    required this.answer,
    this.actionPills = const [],
    this.suggestedFollowUps = const [],
    this.isGeminiPowered = false,
  });

  final String query;
  final String answer;
  final List<CopilotActionPill> actionPills;
  final List<String> suggestedFollowUps;
  final bool isGeminiPowered;
}

abstract final class ManagerCopilotAI {
  /// Processes a natural language manager query against live venue and event data.
  static CopilotResponse ask({
    required String query,
    Event? liveEvent,
    List<Shift> shifts = const [],
    List<Worker> workers = const [],
    List<Punch> punches = const [],
    Map<String, Storefront> storefronts = const {},
    Map<String, JobRole> jobRoles = const {},
    DateTime? onDate,
  }) {
    final q = query.trim().toLowerCase();
    final now = onDate ?? DateTime.now().toUtc();

    // 1. Break Queries
    if (q.contains('break') || q.contains('descanso') || q.contains('meal')) {
      final activeClockedIn = shifts.where((s) => s.workerId != null && s.status == ShiftStatus.assigned).toList();
      final onBreakCount = punches.where((p) => p.kind == PunchKind.breakStart).length -
          punches.where((p) => p.kind == PunchKind.breakEnd).length;

      final count = onBreakCount.clamp(0, activeClockedIn.length);
      final answer = '''
**Break Status Overview**:
* **Currently on break**: $count worker(s)
* **Active on floor**: ${activeClockedIn.length - count} worker(s)

All breaks of 20 minutes or less are recorded as paid rest under venue rules.
''';

      return CopilotResponse(
        query: query,
        answer: answer,
        actionPills: const [
          CopilotActionPill(label: 'View Live Concourse', route: '/live', iconName: 'sensors'),
          CopilotActionPill(label: 'My Shift Clock', route: '/clock', iconName: 'schedule'),
        ],
        suggestedFollowUps: const [
          'Who is late for call time?',
          'Which storefront needs more cashiers?',
        ],
      );
    }

    // 2. Certifications & Compliance
    if (q.contains('tabc') || q.contains('cert') || q.contains('food handler') || q.contains('licencia')) {
      final expiring = <Worker>[];
      final thirtyDays = now.add(const Duration(days: 30));

      for (final w in workers) {
        for (final c in w.certifications) {
          if (c.expiresOn != null && c.expiresOn!.isBefore(thirtyDays)) {
            expiring.add(w);
            break;
          }
        }
      }

      final text = expiring.isEmpty
          ? 'All active staff have valid certifications on file. Zero TABC or Food Handler cards expire in the next 30 days.'
          : '**${expiring.length} worker(s)** have certifications expired or expiring within 30 days:\n${expiring.take(4).map((w) => '• **${w.displayName}** (${w.employeeNumber})').join('\n')}';

      return CopilotResponse(
        query: query,
        answer: text,
        actionPills: const [
          CopilotActionPill(label: 'Open Staff Directory', route: '/staff', iconName: 'badge'),
          CopilotActionPill(label: 'Review Onboarding Cards', route: '/onboarding', iconName: 'task_alt'),
        ],
        suggestedFollowUps: const [
          'Show me all bartenders scheduled tonight',
          'Who is available for shift pickup?',
        ],
      );
    }

    // 3. Overtime & Labor Hours
    if (q.contains('overtime') || q.contains('ot') || q.contains('hours') || q.contains('horas')) {
      return CopilotResponse(
        query: query,
        answer: '''
**Overtime & Workweek Status**:
* **Overtime Rule**: FLSA standard (40.0 hours weekly, Monday start).
* **AI Scheduler Protection**: Active. Strict overtime caps prevent staff from exceeding 40h when scheduling.

To review wage distributions, tip credits, or approved period lines, see the Pay Period view.
''',
        actionPills: [
          CopilotActionPill(label: 'Open Pay Screen', route: '/pay', iconName: 'payments'),
          CopilotActionPill(label: 'View Labor Reports', route: '/reports', iconName: 'insights'),
        ],
        suggestedFollowUps: const [
          'What is the labor budget for this event?',
          'How many shifts are currently open?',
        ],
      );
    }

    // 4. Staffing, Gaps & Open Shifts
    if (q.contains('open') || q.contains('missing') || q.contains('staffing') || q.contains('unfilled') || q.contains('gap')) {
      final openShifts = shifts.where((s) => s.isOpen).toList();
      final totalShifts = shifts.length;

      final answer = openShifts.isEmpty
          ? 'All **$totalShifts** positions are fully staffed for this event.'
          : 'There are **${openShifts.length} open position(s)** out of $totalShifts total scheduled shifts.\n'
              'You can use **AI Auto-Schedule** on the schedule screen to automatically fill these with qualified staff without causing overtime.';

      return CopilotResponse(
        query: query,
        answer: answer,
        actionPills: [
          if (liveEvent != null) CopilotActionPill(label: 'Go to Schedule', route: '/events/${liveEvent.id}', iconName: 'calendar_month'),
          const CopilotActionPill(label: 'Review Shift Requests', route: '/requests', iconName: 'swap_horiz'),
        ],
        suggestedFollowUps: const [
          'Run AI Auto-Schedule',
          'Who is on break right now?',
        ],
      );
    }

    // 5. Labor Cost & Budget
    if (q.contains('budget') || q.contains('cost') || q.contains('labor') || q.contains('presupuesto')) {
      final budget = liveEvent?.laborBudgetCents;
      final budgetFormatted = budget == null ? 'None set' : '\$${(budget / 100).toStringAsFixed(2)}';

      return CopilotResponse(
        query: query,
        answer: '''
**Event Labor Budget**:
* **Event**: ${liveEvent?.name ?? "Current event"}
* **Labor Budget**: **$budgetFormatted**
* **Active Headcount**: ${shifts.where((s) => s.workerId != null).length} workers

Real-time runaway cost tracking projects labor variance against turnstile attendance.
''',
        actionPills: const [
          CopilotActionPill(label: 'View Reports & Targets', route: '/reports', iconName: 'insights'),
          CopilotActionPill(label: 'Pay Screen', route: '/pay', iconName: 'payments'),
        ],
        suggestedFollowUps: const [
          'How many staff are clocked in?',
          'Check TABC certifications',
        ],
      );
    }

    // 6. Fallback / General Assistant
    return CopilotResponse(
      query: query,
      answer: '''
I am your **Storefront Workforce AI Copilot**. I can assist you with:
* **Concourse operations**: Check breaks, missing staff, or live concourse line moves.
* **Compliance & Certifications**: Audit expiring TABC or Food Handler cards.
* **Overtime & Hours**: Track workweek caps and avoid penalty rates.
* **Staffing**: Generate open positions and optimize schedule auto-fills.
''',
      actionPills: const [
        CopilotActionPill(label: 'Live Concourse Map', route: '/live', iconName: 'sensors'),
        CopilotActionPill(label: 'Events Calendar', route: '/events', iconName: 'event'),
        CopilotActionPill(label: 'Staff Directory', route: '/staff', iconName: 'badge'),
      ],
      suggestedFollowUps: const [
        'How many open shifts are there tonight?',
        'Who is on break right now?',
        'Check expiring certifications',
      ],
    );
  }
}
