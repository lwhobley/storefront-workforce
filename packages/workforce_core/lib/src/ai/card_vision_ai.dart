/// Card Vision AI: Automated OCR analysis and verification for state alcohol (TABC)
/// and food handler certification cards.
///
/// In arena concessions, onboarding requires every worker to submit state licenses.
/// This engine extracts the license number, expiration date, student name, and checks
/// for validity and name matching against the worker profile, auto-approving clean cards
/// and flagging expired or mismatched documents.
library;

import '../model/entities.dart';

class CardVerificationResult {
  const CardVerificationResult({
    required this.certTypeCode,
    required this.certName,
    required this.extractedNumber,
    required this.extractedExpiresOn,
    required this.extractedName,
    required this.confidence,
    required this.isAutoApproved,
    required this.nameMatches,
    required this.isExpired,
    required this.reasons,
    required this.flags,
  });

  final String certTypeCode;
  final String certName;
  final String extractedNumber;
  final DateTime? extractedExpiresOn;
  final String extractedName;

  /// Confidence score from 0.0 to 1.0.
  final double confidence;

  /// Whether the card qualifies for automatic verification without manual manager review.
  final bool isAutoApproved;

  final bool nameMatches;
  final bool isExpired;
  final List<String> reasons;
  final List<String> flags;

  Map<String, dynamic> toJson() => {
        'cert_type_code': certTypeCode,
        'cert_name': certName,
        'extracted_number': extractedNumber,
        'extracted_expires_on': extractedExpiresOn?.toIso8601String(),
        'extracted_name': extractedName,
        'confidence': confidence,
        'is_auto_approved': isAutoApproved,
        'name_matches': nameMatches,
        'is_expired': isExpired,
        'reasons': reasons,
        'flags': flags,
      };
}

abstract final class CardVisionAI {
  /// Analyzes raw document/card text (simulating OCR output or multimodal vision tokens)
  /// and compares it with the worker's official profile.
  static CardVerificationResult analyzeCard({
    required String rawOcrText,
    required Worker worker,
    required String certTypeCode,
    required String certName,
    DateTime? onDate,
  }) {
    final now = onDate ?? DateTime.now().toUtc();
    final text = rawOcrText.toLowerCase();
    final flags = <String>[];
    final reasons = <String>[];
    double confidence = 0.95;

    // 1. Extract Certificate Number
    // Standard formats: TX-1234567, TABC# 9876543, or 6-10 digit numbers
    var number = '';
    final labeledMatch = RegExp(
      r'(?:license\s*(?:number|#|no\.?)?|cert(?:ificate)?\s*(?:number|#|no\.?)?|tabc\s*#?|#)\s*[:\s-]*([A-Za-z0-9-]{4,16})',
      caseSensitive: false,
    ).firstMatch(rawOcrText);

    if (labeledMatch != null && RegExp(r'\d').hasMatch(labeledMatch.group(1)!)) {
      number = labeledMatch.group(1)!.trim().toUpperCase();
      reasons.add('Extracted license #$number');
    } else {
      // Fallback: search for standard alphanumeric cert codes like TX-123456 or 6+ digit numbers
      final genericMatch = RegExp(r'\b([A-Za-z]{1,4}-\d{4,10}|\d{6,10})\b').firstMatch(rawOcrText);
      if (genericMatch != null) {
        number = genericMatch.group(1)!.trim().toUpperCase();
        reasons.add('Extracted license #$number');
      } else {
        confidence -= 0.3;
        flags.add('License number not detected');
      }
    }

    // 2. Extract Expiration Date
    DateTime? expiresOn;
    final expMatchIso = RegExp(
      r'(?:exp(?:ir(?:es|ation)?)?|valid|thru|until)[^0-9\n]*(\d{4})[-/](\d{1,2})[-/](\d{1,2})',
      caseSensitive: false,
    ).firstMatch(rawOcrText);
    final expMatchUs = RegExp(
      r'(?:exp(?:ir(?:es|ation)?)?|valid|thru|until)[^0-9\n]*(\d{1,2})[-/](\d{1,2})[-/](\d{4})',
      caseSensitive: false,
    ).firstMatch(rawOcrText);

    if (expMatchIso != null) {
      final y = int.parse(expMatchIso.group(1)!);
      final m = int.parse(expMatchIso.group(2)!);
      final d = int.parse(expMatchIso.group(3)!);
      expiresOn = DateTime.utc(y, m, d);
    } else if (expMatchUs != null) {
      final m = int.parse(expMatchUs.group(1)!);
      final d = int.parse(expMatchUs.group(2)!);
      final y = int.parse(expMatchUs.group(3)!);
      expiresOn = DateTime.utc(y, m, d);
    } else {
      final allIso = RegExp(r'\b(\d{4})[-/](\d{1,2})[-/](\d{1,2})\b').allMatches(text);
      final allUs = RegExp(r'\b(\d{1,2})[-/](\d{1,2})[-/](\d{4})\b').allMatches(text);
      final dates = <DateTime>[];
      for (final m in allIso) {
        dates.add(DateTime.utc(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!)));
      }
      for (final m in allUs) {
        dates.add(DateTime.utc(int.parse(m.group(3)!), int.parse(m.group(1)!), int.parse(m.group(2)!)));
      }
      if (dates.isNotEmpty) {
        dates.sort();
        expiresOn = dates.last;
      }
    }

    bool expired = false;
    if (expiresOn != null) {
      if (expiresOn.isBefore(now)) {
        expired = true;
        flags.add('Card is expired (expired on ${expiresOn.year}-${expiresOn.month.toString().padLeft(2, '0')}-${expiresOn.day.toString().padLeft(2, '0')})');
        confidence -= 0.2;
      } else {
        reasons.add('Valid through ${expiresOn.year}-${expiresOn.month.toString().padLeft(2, '0')}-${expiresOn.day.toString().padLeft(2, '0')}');
      }
    } else {
      flags.add('Expiration date not detected');
      confidence -= 0.25;
    }

    // 3. Name Verification
    final firstName = worker.firstName.toLowerCase();
    final lastName = worker.lastName.toLowerCase();
    final preferred = worker.preferredName.toLowerCase();

    final hasLastName = text.contains(lastName);
    final hasFirstName = text.contains(firstName) || (preferred.isNotEmpty && text.contains(preferred));
    final nameMatches = hasLastName && hasFirstName;

    var extractedName = '${worker.firstName} ${worker.lastName}';
    if (nameMatches) {
      reasons.add('Name matches worker profile');
    } else if (hasLastName) {
      flags.add('Last name matches, but first name was not confirmed');
      confidence -= 0.2;
    } else {
      flags.add('Name on card does not match worker profile');
      confidence -= 0.4;
      extractedName = 'Unknown';
    }

    // 4. Issuing Body / Keyword Verification
    if (certTypeCode == 'tabc' && !text.contains('tabc') && !text.contains('alcoholic') && !text.contains('beverage')) {
      flags.add('Missing expected TABC state certification stamps');
      confidence -= 0.2;
    } else if (certTypeCode == 'food_handler' && !text.contains('food') && !text.contains('handler') && !text.contains('servsafe') && !text.contains('health')) {
      flags.add('Missing expected Food Handler accreditation stamps');
      confidence -= 0.2;
    }

    confidence = confidence.clamp(0.0, 1.0);
    final autoApproved = confidence >= 0.85 && !expired && nameMatches && number.isNotEmpty && expiresOn != null;

    if (autoApproved) {
      reasons.add('All checks passed: eligible for instant auto-approval');
    }

    return CardVerificationResult(
      certTypeCode: certTypeCode,
      certName: certName,
      extractedNumber: number.isEmpty ? 'PENDING-VERIFY' : number,
      extractedExpiresOn: expiresOn,
      extractedName: extractedName,
      confidence: (confidence * 100).round() / 100.0,
      isAutoApproved: autoApproved,
      nameMatches: nameMatches,
      isExpired: expired,
      reasons: reasons,
      flags: flags,
    );
  }
}
