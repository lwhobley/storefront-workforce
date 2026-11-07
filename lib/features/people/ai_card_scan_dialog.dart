import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:workforce_core/workforce_core.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/common.dart';

/// Modal dialog providing interactive AI OCR verification for employee certification cards.
class AiCardScanDialog extends StatefulWidget {
  const AiCardScanDialog({
    super.key,
    required this.worker,
    required this.certTypeCode,
    required this.certName,
    this.initialNumber = '',
    this.initialExpiresOn,
    this.onApproved,
  });

  final Worker worker;
  final String certTypeCode;
  final String certName;
  final String initialNumber;
  final DateTime? initialExpiresOn;
  final VoidCallback? onApproved;

  @override
  State<AiCardScanDialog> createState() => _AiCardScanDialogState();
}

class _AiCardScanDialogState extends State<AiCardScanDialog> {
  late final TextEditingController _ocrController;
  CardVerificationResult? _result;

  @override
  void initState() {
    super.initState();
    final defaultExpiry = widget.initialExpiresOn != null
        ? DateFormat('yyyy-MM-dd').format(widget.initialExpiresOn!)
        : '2027-08-31';
    final defaultNum = widget.initialNumber.isNotEmpty
        ? widget.initialNumber
        : 'TX-${widget.worker.employeeNumber.replaceAll(RegExp(r'[^0-9]'), '')}849';

    final sampleOcr = '''
TEXAS OFFICIAL CERTIFICATION
${widget.certName.toUpperCase()}
Holder Name: ${widget.worker.firstName} ${widget.worker.lastName}
License / Cert #: $defaultNum
Issue Date: 2025-09-01
Expiration Date: $defaultExpiry
Status: ACTIVE & VERIFIED
''';

    _ocrController = TextEditingController(text: sampleOcr.trim());
    _analyze();
  }

  @override
  void dispose() {
    _ocrController.dispose();
    super.dispose();
  }

  void _analyze() {
    final text = _ocrController.text;
    final res = CardVisionAI.analyzeCard(
      rawOcrText: text,
      worker: widget.worker,
      certTypeCode: widget.certTypeCode,
      certName: widget.certName,
      onDate: DateTime.now().toUtc(),
    );
    setState(() => _result = res);
  }

  @override
  Widget build(BuildContext context) {
    final res = _result;
    final shortDate = DateFormat('MMM d, yyyy');

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.auto_awesome, color: AppColors.good, size: 24),
          const SizedBox(width: 8),
          Expanded(child: Text('AI Card Vision: ${widget.certName}')),
        ],
      ),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Worker: ${widget.worker.displayName} (${widget.worker.employeeNumber})',
                style: AppText.meta.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _ocrController,
                maxLines: 5,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: InputDecoration(
                  labelText: 'Raw Document OCR Text',
                  hintText: 'Paste card OCR scan text here...',
                  suffixIcon: IconButton(
                    tooltip: 'Re-scan with AI',
                    icon: const Icon(Icons.refresh),
                    onPressed: _analyze,
                  ),
                ),
                onChanged: (_) => _analyze(),
              ),
              const SizedBox(height: 16),
              if (res != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: res.isAutoApproved ? AppColors.goodSoft : AppColors.warnSoft,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: res.isAutoApproved ? AppColors.good : AppColors.warn,
                      width: 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(
                                res.isAutoApproved ? Icons.verified : Icons.help_outline,
                                color: res.isAutoApproved ? AppColors.good : AppColors.warn,
                                size: 20,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                res.isAutoApproved ? 'Eligible for Auto-Approval' : 'Requires Manual Review',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: res.isAutoApproved ? AppColors.good : AppColors.warn,
                                ),
                              ),
                            ],
                          ),
                          StatusTag(
                            '${(res.confidence * 100).round()}% Confidence',
                            res.confidence >= 0.85 ? Tone.good : Tone.warn,
                          ),
                        ],
                      ),
                      const Divider(height: 16),
                      Text.rich(
                        TextSpan(children: [
                          const TextSpan(text: 'Extracted License #: ', style: TextStyle(fontWeight: FontWeight.w600)),
                          TextSpan(text: res.extractedNumber),
                        ]),
                      ),
                      const SizedBox(height: 4),
                      Text.rich(
                        TextSpan(children: [
                          const TextSpan(text: 'Expiration Date: ', style: TextStyle(fontWeight: FontWeight.w600)),
                          TextSpan(
                            text: res.extractedExpiresOn != null
                                ? shortDate.format(res.extractedExpiresOn!)
                                : 'Not detected',
                            style: TextStyle(
                              color: res.isExpired ? AppColors.bad : null,
                              fontWeight: res.isExpired ? FontWeight.bold : null,
                            ),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 4),
                      Text.rich(
                        TextSpan(children: [
                          const TextSpan(text: 'Name Match: ', style: TextStyle(fontWeight: FontWeight.w600)),
                          TextSpan(
                            text: res.nameMatches ? 'Verified (${res.extractedName})' : 'Mismatch (${res.extractedName})',
                            style: TextStyle(color: res.nameMatches ? AppColors.good : AppColors.bad),
                          ),
                        ]),
                      ),
                      if (res.flags.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        for (final f in res.flags)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.warning_amber, size: 14, color: AppColors.warn),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(f, style: const TextStyle(fontSize: 12, color: AppColors.warn)),
                              ),
                            ],
                          ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (res != null && res.isAutoApproved)
          FilledButton.icon(
            icon: const Icon(Icons.check_circle_outline),
            label: const Text('1-Click Auto-Approve'),
            onPressed: () {
              Navigator.pop(context);
              widget.onApproved?.call();
            },
          ),
      ],
    );
  }
}
