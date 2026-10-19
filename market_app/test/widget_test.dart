// MarketApp widget testleri.
//
// Bu testler, uygulamanın başlangıç ekranının (AuthScreen) doğru şekilde
// render edildiğini ve temel UI bileşenlerinin mevcut olduğunu doğrular.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:market_app/core/session_manager.dart';
import 'package:market_app/main.dart';

void main() {
  setUp(() => SessionManager.instance.clearSession());

  testWidgets('AuthScreen — giriş formu doğru render edilir', (
    WidgetTester tester,
  ) async {
    // Uygulamayı başlat ve ilk frame'i oluştur.
    await tester.pumpWidget(const MarketApp());
    await tester.pump();

    // Uygulama logo ikonunun göründüğünü doğrula.
    expect(find.byIcon(Icons.shopping_basket_outlined), findsOneWidget);

    // E-posta ve şifre alanlarının mevcut olduğunu doğrula.
    expect(find.byIcon(Icons.email_outlined), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);

    // Giriş yap butonunun göründüğünü doğrula.
    expect(find.text('Giriş yap'), findsWidgets);

    // Kayıt ol geçiş bağlantısının göründüğünü doğrula.
    expect(find.text('Hesabın yok mu? Kayıt ol'), findsOneWidget);

    // Misafir olarak devam et butonunun göründüğünü doğrula.
    expect(find.text('Misafir olarak devam et'), findsOneWidget);
  });

  testWidgets('AuthScreen — kayıt formuna geçiş çalışır', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MarketApp());
    await tester.pump();

    // Başlangıçta kayıt ol geçiş butonu görünür olmalı.
    expect(find.text('Hesabın yok mu? Kayıt ol'), findsOneWidget);

    // Kayıt ol butonuna tıkla.
    await tester.tap(find.text('Hesabın yok mu? Kayıt ol'));
    await tester.pump();

    // Kayıt formuna geçildiğini doğrula: giriş yap geçiş bağlantısı görünmeli.
    expect(find.text('Zaten hesabın var mı? Giriş yap'), findsOneWidget);
  });

  testWidgets('Misafir olarak devam et ana sayfayı açar', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MarketApp());
    await tester.ensureVisible(find.text('Misafir olarak devam et'));
    await tester.tap(find.text('Misafir olarak devam et'));
    await tester.pump();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byTooltip('Giriş Yap'), findsOneWidget);
  });

  testWidgets('Aktif oturum ana sayfayı açar ve çıkış misafir modunda kalır', (
    WidgetTester tester,
  ) async {
    SessionManager.instance.setSession(
      token: 'test-token',
      user: {'name': 'Test Kullanıcı'},
    );

    await tester.pumpWidget(const MarketApp());
    await tester.pump();

    expect(find.byTooltip('Hesabım (Test Kullanıcı)'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.tap(find.byTooltip('Hesabım (Test Kullanıcı)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Çıkış Yap'));
    await tester.pump();

    expect(SessionManager.instance.isAuthenticated, isFalse);
    expect(find.byTooltip('Giriş Yap'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
