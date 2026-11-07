/// Incident Assistant & Translation AI: Automated OSHA classification, incident
/// summarization, and bilingual English <-> Spanish concourse operational translation.
library;

class StructuredIncidentAnalysis {
  const StructuredIncidentAnalysis({
    required this.incidentCategory,
    required this.severityLevel,
    required this.isOshaRecordable,
    required this.oshaRationale,
    required this.executiveSummary,
    required this.suggestedCorrectiveActions,
  });

  final String incidentCategory;
  final String severityLevel;
  final bool isOshaRecordable;
  final String oshaRationale;
  final String executiveSummary;
  final List<String> suggestedCorrectiveActions;

  String get category => incidentCategory;
  String get severity => severityLevel;
  String get structuredSummary => executiveSummary;
  String get rootCause => oshaRationale;
  List<String> get actions => suggestedCorrectiveActions;

  Map<String, dynamic> toJson() => {
        'incident_category': incidentCategory,
        'severity_level': severityLevel,
        'is_osha_recordable': isOshaRecordable,
        'osha_rationale': oshaRationale,
        'executive_summary': executiveSummary,
        'suggested_corrective_actions': suggestedCorrectiveActions,
      };
}

abstract final class IncidentAssistantAI {
  /// Analyzes raw notes logged by a concessions lead or manager.
  static StructuredIncidentAnalysis analyzeIncidentNotes(String notes) {
    final text = notes.toLowerCase();
    String category = 'General Safety';
    String severity = 'Low';
    bool oshaRecordable = false;
    String oshaReason = 'First-aid only; no prescription medication or restricted duty reported.';
    final actions = <String>[];

    if (text.contains('burn') || text.contains('oil') || text.contains('fryer') || text.contains('grill') || text.contains('steam')) {
      category = 'Burn / Thermal Injury';
      actions.add('Verify fryer splash guard and temperature controls');
      actions.add('Restock first-aid burn gel and sterile dressings');
      if (text.contains('blister') || text.contains('hospital') || text.contains('urgent care') || text.contains('doctor') || text.contains('2nd degree') || text.contains('second degree')) {
        severity = 'High';
        oshaRecordable = true;
        oshaReason = 'OSHA 1904.7: Medical treatment beyond first aid or evaluation at clinical facility.';
      } else {
        severity = 'Medium';
      }
    } else if (text.contains('slip') || text.contains('fall') || text.contains('water') || text.contains('grease') || text.contains('floor')) {
      category = 'Slip, Trip & Fall';
      actions.add('Ensure immediate mop-up and place wet floor caution signs');
      actions.add('Inspect slip-resistant rubber drainage mats behind the counter');
      actions.add('Verify slip-resistant footwear compliance');
      if (text.contains('ambulance') || text.contains('er') || text.contains('fracture') || text.contains('twisted') || text.contains('head')) {
        severity = 'High';
        oshaRecordable = true;
        oshaReason = 'OSHA 1904.7: Serious injury requiring medical treatment.';
      } else {
        severity = 'Medium';
      }
    } else if (text.contains('cut') || text.contains('knife') || text.contains('blade') || text.contains('glass') || text.contains('can')) {
      category = 'Laceration / Puncture';
      actions.add('Inspect cutlery and food prep equipment for safety shields');
      actions.add('Ensure cut-resistant Kevlar glove usage during food prep');
      if (text.contains('stitch') || text.contains('suture') || text.contains('artery') || text.contains('urgent care')) {
        severity = 'High';
        oshaRecordable = true;
        oshaReason = 'OSHA 1904.7: Sutures or medical wound closure constitutes recordable treatment.';
      } else {
        severity = 'Low';
      }
    } else if (text.contains('fight') || text.contains('altercation') || text.contains('guest') || text.contains('intoxicated') || text.contains('threat')) {
      category = 'Guest Conduct / Security';
      severity = 'Medium';
      actions.add('Notify arena security and event operations supervisor');
      actions.add('Preserve CCTV concourse footage for this section');
    }

    // Generate executive summary
    final summary = notes.trim().isEmpty
        ? 'No incident narrative provided.'
        : 'Reported $category ($severity severity). $oshaReason';

    return StructuredIncidentAnalysis(
      incidentCategory: category,
      severityLevel: severity,
      isOshaRecordable: oshaRecordable,
      oshaRationale: oshaReason,
      executiveSummary: summary,
      suggestedCorrectiveActions: actions.isEmpty ? ['Document witness statements and maintain log'] : actions,
    );
  }

  /// Concourse English <-> Spanish translation for operational broadcasts.
  static String translateConcourseMessage(String text, {bool? toSpanish}) {
    if (text.trim().isEmpty) return '';

    final lower = text.toLowerCase();
    final detectedSpanish = lower.contains('puesto') ||
        lower.contains('descanso') ||
        lower.contains('hora') ||
        lower.contains('por favor') ||
        lower.contains('cajero') ||
        lower.contains('marcar') ||
        lower.contains('necesitamos') ||
        lower.contains('seccion');

    final targetToSpanish = toSpanish ?? !detectedSpanish;

    // Specialized concourse operations translation dictionary
    final enToEs = <RegExp, String>{
      RegExp(r'\bcall time\b', caseSensitive: false): 'hora de llegada',
      RegExp(r'\bclock in\b', caseSensitive: false): 'marcar entrada',
      RegExp(r'\bclock out\b', caseSensitive: false): 'marcar salida',
      RegExp(r'\btake your break\b', caseSensitive: false): 'tome su descanso',
      RegExp(r'\bbreak time\b', caseSensitive: false): 'hora de descanso',
      RegExp(r'\bmeal break\b', caseSensitive: false): 'descanso para comer',
      RegExp(r'\bstorefront\b', caseSensitive: false): 'puesto',
      RegExp(r'\bstand\b', caseSensitive: false): 'puesto',
      RegExp(r'\bdoors open\b', caseSensitive: false): 'apertura de puertas',
      RegExp(r'\bintermission\b', caseSensitive: false): 'intermedio',
      RegExp(r'\bspill on floor\b', caseSensitive: false): 'derrame en el piso',
      RegExp(r'\bneed ice\b', caseSensitive: false): 'se necesita hielo',
      RegExp(r'\bneed cups\b', caseSensitive: false): 'se necesitan vasos',
      RegExp(r'\bneed change\b', caseSensitive: false): 'se necesita cambio',
      RegExp(r'\bclean grease trap\b', caseSensitive: false): 'limpiar la trampa de grasa',
      RegExp(r'\bclosing checklist\b', caseSensitive: false): 'lista de cierre',
      RegExp(r'\bopening checklist\b', caseSensitive: false): 'lista de apertura',
      RegExp(r'\bmanager meeting\b', caseSensitive: false): 'reunión de gerentes',
      RegExp(r'\ball staff\b', caseSensitive: false): 'todo el personal',
      RegExp(r'\bclose\b', caseSensitive: false): 'cierre',
      RegExp(r'\bcashier\b', caseSensitive: false): 'cajero',
    };

    final esToEn = <RegExp, String>{
      RegExp(r'\bhora de llegada\b', caseSensitive: false): 'call time',
      RegExp(r'\bmarcar entrada\b', caseSensitive: false): 'clock in',
      RegExp(r'\bmarcar salida\b', caseSensitive: false): 'clock out',
      RegExp(r'\btome su descanso\b', caseSensitive: false): 'take your break',
      RegExp(r'\bdescanso\b', caseSensitive: false): 'break',
      RegExp(r'\bpuesto\b', caseSensitive: false): 'storefront',
      RegExp(r'\bderrame\b', caseSensitive: false): 'spill',
      RegExp(r'\bhielo\b', caseSensitive: false): 'ice',
      RegExp(r'\bvasos\b', caseSensitive: false): 'cups',
      RegExp(r'\bcambio\b', caseSensitive: false): 'change',
      RegExp(r'\bcajero\b', caseSensitive: false): 'cashier',
      RegExp(r'\bcierre\b', caseSensitive: false): 'close',
    };

    var translated = text;
    if (targetToSpanish) {
      enToEs.forEach((pattern, replacement) {
        translated = translated.replaceAllMapped(pattern, (_) => replacement);
      });
    } else {
      esToEn.forEach((pattern, replacement) {
        translated = translated.replaceAllMapped(pattern, (_) => replacement);
      });
    }
    return translated;
  }
}
