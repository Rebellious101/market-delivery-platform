import 'package:flutter/material.dart';

class AppConstants {
  // Uygulama Bilgileri
  static const String appName = 'Market App';
  static const String appVersion = '1.0.0';

  // Tema Renkleri
  static const Color primaryColor = Color(0xFF2E7D32); // Koyu Yeşil
  static const Color secondaryColor = Color(0xFFFFA000); // Amber / Turuncu
  static const Color backgroundColor = Color(0xFFF8F9FA);
  static const Color surfaceColor = Colors.white;
  static const Color errorColor = Color(0xFFD32F2F);

  // Metin Renkleri
  static const Color textPrimary = Color(0xFF212529);
  static const Color textSecondary = Color(0xFF6C757D);
  static const Color textLight = Colors.white;

  // Ağ (API) Sabitleri
  // USB ile bağlı gerçek Android cihazında adb reverse tcp:5000 tcp:5000 kullanılır.
  // Bu durumda uygulama localhost:5000 üzerinden PC'deki Flask sunucusuna erişir.
  // Emülatör için: flutter run --dart-define=API_BASE_URL=http://10.0.2.2:5000
  // Gerçek cihaz + LAN için: flutter run --dart-define=API_BASE_URL=http://192.168.1.50:5000
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:5000',
  );
  static const int connectionTimeout =
      30000; // Milisaniye cinsinden (30 saniye)
  static const int receiveTimeout = 30000;

  // Yerel Depolama (Hive / SharedPreferences) Anahtarları
  static const String tokenKey = 'auth_token';
  static const String userKey = 'user_data';
  static const String cartKey = 'local_cart';

  // UI / Tasarım Sabitleri
  static const double defaultPadding = 16.0;
  static const double defaultRadius = 12.0;
  static const double buttonHeight = 50.0;

  // Hata Mesajları
  static const String networkErrorMsg = 'İnternet bağlantınızı kontrol edin.';
  static const String genericErrorMsg =
      'Bir hata oluştu, lütfen tekrar deneyin.';
}
