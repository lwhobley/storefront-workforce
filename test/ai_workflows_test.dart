import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:storefront_workforce/app/providers.dart';
import 'package:storefront_workforce/core/ai/gemini_service.dart';
import 'package:storefront_workforce/data/demo_repository.dart';
import 'package:storefront_workforce/features/copilot/manager_copilot_sheet.dart';
import 'package:storefront_workforce/features/people/ai_card_scan_dialog.dart';
import 'package:workforce_core/workforce_core.dart';

void main() {
  final now = DateTime.utc(2026, 11, 7, 20, 0);

  final testWorker = Worker(
    id: 'w_test_1',
    venueId: 'v1',
    type: WorkerType.regular,
    employeeNumber: 'E9001',
    firstName: 'Jordan',
    lastName: 'Bell',
    jobRoles: ['cashier', 'bartender'],
  );

  testWidgets('AiCardScanDialog extracts valid card data and auto-approves', (tester) async {
    bool approved = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiCardScanDialog(
            worker: testWorker,
            certTypeCode: 'tabc',
            certName: 'TABC Seller-Server',
            initialNumber: 'TX-9001849',
            initialExpiresOn: DateTime.utc(2027, 8, 31),
            onApproved: () => approved = true,
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify dialog header and components
    expect(find.text('AI Card Vision: TABC Seller-Server'), findsOneWidget);
    expect(find.text('Eligible for Auto-Approval'), findsOneWidget);
    expect(find.text('1-Click Auto-Approve'), findsOneWidget);

    // Tap Auto-Approve
    await tester.tap(find.text('1-Click Auto-Approve'));
    await tester.pumpAndSettle();

    expect(approved, isTrue);
  });

  testWidgets('ManagerCopilotSheet responds to natural language queries', (tester) async {
    final repo = DemoWorkforceRepository(now: now);
    final container = ProviderContainer(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() => container.read(sessionProvider.notifier).signIn('200002')); // concessions manager PIN

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: ManagerCopilotSheet(),
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 300));

    // Initial greeting and pill chips
    expect(find.text('Manager AI Copilot'), findsOneWidget);
    expect(find.text('Who is on break right now?'), findsWidgets);

    // Tap a follow-up chip
    await tester.tap(find.text('Who is on break right now?').first);
    await tester.pump(const Duration(milliseconds: 300));

    // Verify Copilot answered
    expect(find.textContaining('break'), findsWidgets);

    // Type a cert query
    await tester.enterText(find.byType(TextField), 'Check TABC certifications');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('TABC'), findsWidgets);
  });

  test('IncidentAssistantAI and bilingual concourse translation perform correctly', () {
    // English -> Spanish
    final es = IncidentAssistantAI.translateConcourseMessage('Please close stand 101 early');
    expect(es.toLowerCase(), contains('cierre'));

    // Spanish -> English
    final en = IncidentAssistantAI.translateConcourseMessage('Necesitamos cajero en seccion 105');
    expect(en.toLowerCase(), contains('cashier'));

    // OSHA Analysis
    final osha = IncidentAssistantAI.analyzeIncidentNotes(
      'Worker dropped knife and suffered deep laceration with heavy bleeding on left index finger, sent to urgent care for 4 sutures',
    );

    expect(osha.isOshaRecordable, isTrue);
    expect(osha.category.toLowerCase(), contains('laceration'));
    expect(osha.actions, isNotEmpty);
  });

  test('GeminiService and key notifier configure and fall back safely', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final initialKey = container.read(geminiApiKeyProvider);
    expect(initialKey, isEmpty);

    final service = container.read(geminiServiceProvider);
    expect(service.isConfigured, isFalse);

    // Setting a key updates state
    await container.read(geminiApiKeyProvider.notifier).setKey('AIzaSyTestKey123');
    expect(container.read(geminiApiKeyProvider), 'AIzaSyTestKey123');
    expect(container.read(geminiServiceProvider).isConfigured, isTrue);

    // Clearing key restores fallback
    await container.read(geminiApiKeyProvider.notifier).setKey('');
    expect(container.read(geminiApiKeyProvider), isEmpty);
    expect(container.read(geminiServiceProvider).isConfigured, isFalse);
  });
}
