import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'constants.dart';
import 'localization.dart';

class AgeVerification {
  AgeVerification._();

  /// App Store Guideline 1.4.3 gereği iOS/macOS üzerinde sigara ve tütün
  /// ürünlerinin gizlenip gizlenmeyeceğini belirler.
  static bool get isTobaccoRestrictedPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  static const List<String> _alcoholKeywords = [
    'alkol',
    'alcohol',
    'içki',
    'icki',
    'bira',
    'şarap',
    'sarap',
    'rakı',
    'raki',
    'votka',
    'vodka',
    'viski',
    'whisky',
    'whiskey',
    'likör',
    'likor',
    'tekila',
    'tequila',
    '+18',
    '18+',
  ];

  static const List<String> _tobaccoKeywords = [
    'sigara',
    'tütün',
    'tutun',
    'tobacco',
    'cigarette',
    'puro',
    'nargile',
    'hookah',
    'vape',
    'e-cigarette',
    'iqos',
    'heets',
    'terea',
  ];

  /// Metnin alkol (+18) kapsamında olup olmadığını kontrol eder.
  static bool isAlcoholText(String text) {
    final lower = text.toLowerCase();
    for (final keyword in _alcoholKeywords) {
      if (lower.contains(keyword)) return true;
    }
    return false;
  }

  /// Metnin sigara / tütün (+18) kapsamında olup olmadığını kontrol eder.
  static bool isTobaccoText(String text) {
    final lower = text.toLowerCase();
    for (final keyword in _tobaccoKeywords) {
      if (lower.contains(keyword)) return true;
    }
    return false;
  }

  /// Metnin +18 (alkol veya sigara/tütün) kapsamında olup olmadığını kontrol eder.
  static bool is18PlusText(String text) {
    return isAlcoholText(text) || isTobaccoText(text);
  }

  /// +18 yaş doğrulama penceresini (dialog) gösterir.
  /// [isTobacco] true ise sigara/tütün uyarısı, false ise alkol uyarısı gösterilir.
  /// Kullanıcı "Evet, Onaylıyorum" derse `true`, aksi halde `false` döner.
  static Future<bool> show18PlusDialog(
    BuildContext context, {
    bool isTobacco = false,
  }) async {
    final en = AppStrings.of(context).isEnglish;

    final String message;
    if (isTobacco) {
      message = en
          ? 'Sales of cigarettes and tobacco products to persons under 18 are prohibited. Do you confirm that you are over 18 years old?'
          : '18 yaşından küçüklere sigara ve tütün ürünleri satışı yasaktır. 18 yaşından büyük olduğunuzu onaylıyor musunuz?';
    } else {
      message = en
          ? 'Alcohol sales to persons under 18 are prohibited. Do you confirm that you are over 18 years old?'
          : '18 yaşından küçüklere alkol satışı yasaktır. 18 yaşından büyük olduğunuzu onaylıyor musunuz?';
    }

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        icon: Container(
          width: 64,
          height: 64,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.12),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.redAccent, width: 2),
          ),
          child: const Text(
            '+18',
            style: TextStyle(
              color: Colors.red,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        title: Text(
          en ? '18+ Age Verification' : '+18 Yaş Sınırı Uyarısı',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 18,
            color: Color(0xFF1E2022),
          ),
        ),
        content: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14.5,
            height: 1.45,
            color: Color(0xFF495057),
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.grey.shade700,
                    side: BorderSide(color: Colors.grey.shade300),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    en ? 'No' : 'Hayır',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppConstants.primaryColor,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    en ? 'Yes, I am 18+' : 'Evet, Onaylıyorum',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return confirmed == true;
  }
}
