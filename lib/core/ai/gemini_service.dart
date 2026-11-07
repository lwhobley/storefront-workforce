import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workforce_core/workforce_core.dart';

const _prefGeminiKey = 'sw.gemini_api_key.v1';
const _envGeminiKey = String.fromEnvironment('GEMINI_API_KEY');

/// Manages the Google Gemini API key in local storage and environment.
final geminiApiKeyProvider = NotifierProvider<GeminiApiKeyNotifier, String>(GeminiApiKeyNotifier.new);

class GeminiApiKeyNotifier extends Notifier<String> {
  @override
  String build() {
    _loadFromStorage();
    return _envGeminiKey;
  }

  Future<void> _loadFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefGeminiKey);
      if (saved != null && saved.isNotEmpty) {
        state = saved;
      }
    } catch (_) {}
  }

  Future<void> setKey(String key) async {
    state = key.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (state.isEmpty) {
        await prefs.remove(_prefGeminiKey);
      } else {
        await prefs.setString(_prefGeminiKey, state);
      }
    } catch (_) {}
  }
}

/// Provides the active [GeminiService] instance configured with the current key.
final geminiServiceProvider = Provider<GeminiService>((ref) {
  final key = ref.watch(geminiApiKeyProvider);
  return GeminiService(apiKey: key);
});

/// Client service for Google Gemini 1.5 Flash.
///
/// Supports free-tier usage (15 RPM, 1,500 requests/day at zero cost).
/// Supports zero-rebuild runtime API key configuration or build-time `--dart-define=GEMINI_API_KEY=...`.
class GeminiService {
  GeminiService({required this.apiKey});

  final String apiKey;

  bool get isConfigured => apiKey.trim().isNotEmpty;

  GenerativeModel _createModel({String? systemInstruction, bool jsonMode = false}) {
    return GenerativeModel(
      model: 'gemini-1.5-flash',
      apiKey: apiKey,
      systemInstruction: systemInstruction != null ? Content.system(systemInstruction) : null,
      generationConfig: jsonMode
          ? GenerationConfig(
              responseMimeType: 'application/json',
              temperature: 0.1,
            )
          : GenerationConfig(
              temperature: 0.25,
              maxOutputTokens: 800,
            ),
    );
  }

  /// Queries Gemini 1.5 Flash with live arena concessions workforce context.
  Future<CopilotResponse?> askCopilot({
    required String query,
    required Event? liveEvent,
    required List<Shift> shifts,
    required List<Worker> workers,
    required List<Punch> punches,
    required Map<String, Storefront> storefronts,
    required Map<String, JobRole> jobRoles,
  }) async {
    if (!isConfigured) return null;

    try {
      final now = DateTime.now().toUtc();
      final workersById = {for (final w in workers) w.id: w};

      // Calculate live status for context grounding
      final clockedInIds = <String>{};
      final onBreakIds = <String>{};
      for (final p in punches) {
        if (p.kind == PunchKind.clockIn) clockedInIds.add(p.workerId);
        if (p.kind == PunchKind.clockOut) clockedInIds.remove(p.workerId);
        if (p.kind == PunchKind.breakStart) onBreakIds.add(p.workerId);
        if (p.kind == PunchKind.breakEnd) onBreakIds.remove(p.workerId);
      }

      final openPositions = shifts.where((s) => s.workerId == null).toList();
      final expiringCerts = workers
          .where((w) => w.certifications.any((c) => c.expiresOn != null && c.expiresOn!.difference(now).inDays <= 30))
          .toList();

      final contextBuffer = StringBuffer()
        ..writeln('CURRENT VENUE STATE & CONTEXT:')
        ..writeln('- Current Time: ${now.toIso8601String()}')
        ..writeln('- Active Event: ${liveEvent?.name ?? "None currently in progress"}')
        ..writeln('- Event Status: ${liveEvent?.status.name ?? "N/A"}')
        ..writeln('- Total Shifts Scheduled: ${shifts.length}')
        ..writeln('- Currently Clocked In: ${clockedInIds.length} staff')
        ..writeln('- Currently On Break: ${onBreakIds.length} staff')
        ..writeln('- Unfilled Open Shifts: ${openPositions.length} positions')
        ..writeln('- Workers with Expiring Certifications: ${expiringCerts.length}')
        ..writeln('- Storefront Locations: ${storefronts.values.map((s) => s.name).join(", ")}')
        ..writeln('- Concessions Job Roles: ${jobRoles.values.map((r) => r.name).join(", ")}');

      if (onBreakIds.isNotEmpty) {
        contextBuffer.writeln('- Names of staff currently on break: '
            '${onBreakIds.take(10).map((id) => workersById[id]?.displayName ?? id).join(", ")}');
      }

      if (openPositions.isNotEmpty) {
        final openBySf = <String, int>{};
        for (final s in openPositions) {
          final sfName = storefronts[s.storefrontId]?.name ?? s.storefrontId;
          openBySf[sfName] = (openBySf[sfName] ?? 0) + 1;
        }
        contextBuffer.writeln('- Open positions by stand: ${openBySf.entries.map((e) => "${e.key}: ${e.value}").join(", ")}');
      }

      const systemPrompt = '''
You are the Storefront Workforce Manager Copilot, an AI assistant for arena concessions operations managers.
Use the provided real-time venue context to give accurate, actionable, concise operational advice.
Format your response with GitHub-flavored markdown.
Highlight stand names, worker names, and numbers in bold.
If recommending an action, keep it practical and arena-specific.
''';

      final model = _createModel(systemInstruction: systemPrompt);
      final prompt = '''
$contextBuffer

MANAGER QUESTION:
$query
''';

      final response = await model.generateContent([Content.text(prompt)]);
      final text = response.text;
      if (text == null || text.trim().isEmpty) return null;

      // Extract context-appropriate navigation action pills
      final pills = <CopilotActionPill>[];
      final lower = query.toLowerCase();
      if (lower.contains('break') || lower.contains('live') || lower.contains('concourse')) {
        pills.add(const CopilotActionPill(label: 'Live Concourse', route: '/live', iconName: 'sensors'));
      }
      if (lower.contains('cert') || lower.contains('tabc') || lower.contains('card') || lower.contains('onboarding')) {
        pills.add(const CopilotActionPill(label: 'Onboarding & Cards', route: '/onboarding', iconName: 'task_alt'));
      }
      if (lower.contains('shift') || lower.contains('sched') || lower.contains('open') || lower.contains('fill')) {
        pills.add(const CopilotActionPill(label: 'Event Schedule', route: '/events', iconName: 'event'));
      }
      if (lower.contains('budget') || lower.contains('cost') || lower.contains('labor')) {
        pills.add(const CopilotActionPill(label: 'Reports & Labor', route: '/reports', iconName: 'bar_chart'));
      }
      if (pills.isEmpty) {
        pills.add(const CopilotActionPill(label: 'Live Concourse', route: '/live', iconName: 'sensors'));
      }

      return CopilotResponse(
        query: query,
        answer: text.trim(),
        actionPills: pills,
        suggestedFollowUps: const [
          'Who is on break right now?',
          'Are any certifications expiring this month?',
          'How can we optimize open shifts?',
          'What is our live concourse balance?',
        ],
        isGeminiPowered: true,
      );
    } catch (e) {
      debugPrint('Gemini Copilot query failed, falling back to local engine: $e');
      return null;
    }
  }

  /// Analyzes a certification card using Gemini 1.5 Flash multimodal vision or raw text.
  Future<CardVerificationResult?> analyzeCardWithGemini({
    required Worker worker,
    required String certTypeCode,
    required String certName,
    String? rawOcrText,
    Uint8List? imageBytes,
    required DateTime onDate,
  }) async {
    if (!isConfigured) return null;

    try {
      const systemPrompt = '''
You are an expert OCR and credential verification assistant for arena concessions certifications (such as Texas TABC Seller-Server and ANSI Food Handler).
Analyze the card image or text and output strict JSON matching this structure:
{
  "extracted_number": "string",
  "expiration_date": "YYYY-MM-DD",
  "extracted_name": "string",
  "name_matches": true,
  "is_expired": false,
  "confidence": 0.95,
  "is_auto_approved": true,
  "reasons": ["list of reasons"],
  "flags": ["list of flags or warnings"]
}
Only output valid JSON.
''';

      final model = _createModel(systemInstruction: systemPrompt, jsonMode: true);
      final parts = <Part>[];

      if (imageBytes != null && imageBytes.isNotEmpty) {
        parts.add(DataPart('image/jpeg', imageBytes));
      }

      final promptText = '''
Worker Name: ${worker.displayName} (${worker.firstName} ${worker.lastName})
Expected Certification: $certName (Code: $certTypeCode)
Current Date: ${onDate.toIso8601String().split('T').first}

Raw Card Content:
${rawOcrText ?? "Inspect the attached image carefully."}
''';
      parts.add(TextPart(promptText));

      final response = await model.generateContent([Content.multi(parts)]);
      final jsonText = response.text;
      if (jsonText == null) return null;

      final data = jsonDecode(jsonText) as Map<String, dynamic>;
      final expString = data['expiration_date'] as String?;
      DateTime? expDate;
      if (expString != null && expString.isNotEmpty) {
        expDate = DateTime.tryParse(expString);
      }

      final isExpired = expDate != null ? expDate.isBefore(onDate) : false;
      final nameMatches = (data['name_matches'] as bool?) ?? false;
      final confidence = (data['confidence'] as num?)?.toDouble() ?? 0.85;
      final isAutoApproved = (!isExpired && nameMatches && confidence >= 0.80);

      return CardVerificationResult(
        certTypeCode: certTypeCode,
        certName: certName,
        extractedNumber: (data['extracted_number'] as String?) ?? '',
        extractedExpiresOn: expDate,
        extractedName: (data['extracted_name'] as String?) ?? worker.displayName,
        confidence: confidence,
        isAutoApproved: isAutoApproved,
        nameMatches: nameMatches,
        isExpired: isExpired,
        reasons: [for (final r in (data['reasons'] as List?) ?? const []) r.toString()],
        flags: [for (final f in (data['flags'] as List?) ?? const []) f.toString()],
      );
    } catch (e) {
      debugPrint('Gemini Card Vision failed, falling back to local engine: $e');
      return null;
    }
  }

  /// Translates operational concourse messages with Gemini.
  Future<String?> translateConcourseText(String text, {bool toSpanish = true}) async {
    if (!isConfigured || text.trim().isEmpty) return null;

    try {
      final targetLang = toSpanish ? 'Spanish' : 'English';
      final model = _createModel(
        systemInstruction: 'You are a professional bilingual translator for sports arena concessions staff. '
            'Translate the message accurately into natural, idiomatic $targetLang suitable for fast-paced event concourse communication. '
            'Output only the translated text.',
      );
      final response = await model.generateContent([Content.text(text)]);
      return response.text?.trim();
    } catch (e) {
      debugPrint('Gemini translation failed: $e');
      return null;
    }
  }
}
