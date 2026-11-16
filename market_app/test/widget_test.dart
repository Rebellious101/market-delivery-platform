// MarketApp widget testleri.
//
// Bu testler, uygulamanın başlangıç ekranının (AuthScreen) doğru şekilde
// render edildiğini ve temel UI bileşenlerinin mevcut olduğunu doğrular.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:prestij_market/core/session_manager.dart';
import 'package:prestij_market/main.dart';
import 'package:prestij_market/models/product_model.dart';
import 'package:prestij_market/screen/cart_manager.dart';

void main() {
  setUp(() => SessionManager.instance.clearSession());

  test('Minimum sepet subtotal ignores exempt tobacco products', () {
    final cart = CartManager();
    cart.items
      ..clear()
      ..add(
        CartItem(
          product: Product(
            id: 1,
            title: 'Market ürünü',
            description: '',
            price: 300,
            imageUrl: '',
            stock: 5,
          ),
        ),
      )
      ..add(
        CartItem(
          product: Product(
            id: 2,
            title: 'Tütün ürünü',
            description: '',
            price: 1000,
            imageUrl: '',
            stock: 5,
            minimumOrderExempt: true,
          ),
        ),
      );

    expect(cart.totalPrice, 1300);
    expect(cart.minimumOrderTotal, 300);
    cart.items.clear();
  });

  testWidgets('AuthScreen — e-posta giriş seçenekleri doğru render edilir', (
    WidgetTester tester,
  ) async {
    // Uygulamayı başlat ve ilk frame'i oluştur.
    await tester.pumpWidget(const MarketApp());
    await tester.pump();

    // Uygulama logo ikonunun göründüğünü doğrula.
    expect(find.byIcon(Icons.shopping_basket_outlined), findsOneWidget);

    // E-posta, şifre ve Google giriş seçeneklerinin mevcut olduğunu doğrula.
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(find.text('Google ile devam et'), findsOneWidget);

    // Giriş yap butonunun göründüğünü doğrula.
    expect(find.text('Giriş yap'), findsWidgets);

    // Kayıt ol geçiş bağlantısının göründüğünü doğrula.
    expect(find.text('Hesabın yok mu? Kayıt ol'), findsOneWidget);

    // Misafir olarak devam et butonunun göründüğünü doğrula.
    expect(find.text('Misafir olarak devam et'), findsOneWidget);
  });

  testWidgets('AuthScreen — e-posta kayıt formuna geçiş çalışır', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MarketApp());
    await tester.pump();

    // Başlangıçta kayıt ol geçiş butonu görünür olmalı.
    expect(find.text('Hesabın yok mu? Kayıt ol'), findsOneWidget);

    // Kayıt ol butonuna tıkla.
    await tester.ensureVisible(find.text('Hesabın yok mu? Kayıt ol'));
    await tester.tap(find.text('Hesabın yok mu? Kayıt ol'));
    await tester.pump();

    // Kayıt formuna geçildiğini doğrula: giriş yap geçiş bağlantısı görünmeli.
    expect(find.text('Zaten hesabın var mı? Giriş yap'), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(3));
  });

  testWidgets('AuthScreen — telefon giriş seçeneği korunur', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MarketApp());
    await tester.tap(find.text('Telefon'));
    await tester.pump();

    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(find.text('Doğrulama Kodu Gönder'), findsOneWidget);
  });

  testWidgets('Misafir olarak devam et ana sayfayı açar', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MarketApp());
    await tester.ensureVisible(find.text('Misafir olarak devam et'));
    await tester.tap(find.text('Misafir olarak devam et'));
    await tester.pump();

    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(find.text('Profil'));
    await tester.pump();
    expect(find.text('Giriş Yap'), findsOneWidget);
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

    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.tap(find.text('Profil'));
    await tester.pump();
    expect(find.text('Test Kullanıcı'), findsOneWidget);
    await tester.ensureVisible(find.text('Çıkış Yap'));
    await tester.tap(find.text('Çıkış Yap'));
    await tester.pump();

    expect(SessionManager.instance.isAuthenticated, isFalse);
    expect(find.text('Giriş Yap'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
