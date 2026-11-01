import 'package:flutter/material.dart';

class AppLanguage extends ChangeNotifier {
  AppLanguage._();

  static final AppLanguage instance = AppLanguage._();

  String _code = 'tr';
  String get code => _code;
  Locale get locale => Locale(_code);

  void setCode(String code) {
    if (code != 'tr' && code != 'en' || code == _code) return;
    _code = code;
    notifyListeners();
  }
}

class AppStrings {
  AppStrings(this.locale);

  final Locale locale;
  bool get isEnglish => locale.languageCode == 'en';

  static AppStrings of(BuildContext context) {
    final language = AppLanguage.instance;
    return AppStrings(language.locale);
  }

  String get appName => 'Market App';
  String get home => isEnglish ? 'Home' : 'Ana Sayfa';
  String get categories => isEnglish ? 'Categories' : 'Kategoriler';
  String get cart => isEnglish ? 'Cart' : 'Sepet';
  String get campaigns => isEnglish ? 'Campaigns' : 'Kampanyalar';
  String get deliveryAddress =>
      isEnglish ? 'DELIVERY ADDRESS' : 'TESLİMAT ADRESİ';
  String get addAddress => isEnglish ? 'Add address' : 'Adres ekle';
  String get searchProducts => isEnglish ? 'Search products' : 'Ürünlerde ara';
  String get clearSearch => isEnglish ? 'Clear search' : 'Aramayı temizle';
  String get all => isEnglish ? 'All' : 'Tümü';
  String get productsNotFound =>
      isEnglish ? 'No products found.' : 'Hiç ürün bulunamadı.';
  String get noSearchResults => isEnglish
      ? 'No products match your search.'
      : 'Aramanızla eşleşen ürün bulunamadı.';
  String get campaignsSoon => isEnglish
      ? 'No active campaigns found'
      : 'Henüz aktif bir kampanya bulunmuyor';
  String get campaignsDescription => isEnglish
      ? 'Follow special offers and discounts here.'
      : 'Yeni fırsatlar ve özel indirimler eklendiğinde buradan takip edebilirsiniz.';
  String get language => isEnglish ? 'Language' : 'Dil';
  String get turkish => 'Türkçe';
  String get english => 'English';
  String get addressAdded => isEnglish ? 'Address added' : 'Adres eklendi';
  String get myCart => isEnglish ? 'My cart' : 'Sepetim';
  String get emptyCartTitle =>
      isEnglish ? 'Your cart is empty' : 'Sepetiniz henüz boş';
  String get emptyCartDescription => isEnglish
      ? 'Discover the products you need and add your favorites to the cart.'
      : 'İhtiyacınız olan ürünleri keşfedin ve favorilerinizi sepetinize ekleyin.';
  String get discoverProducts =>
      isEnglish ? 'Discover products' : 'Ürünleri keşfet';
  String get delivery => isEnglish ? 'Delivery address' : 'Teslimat adresi';
  String get newAddress => isEnglish ? 'New address' : 'Yeni adres';
  String get selectAddress => isEnglish
      ? 'Select a delivery address to complete your order.'
      : 'Sipariş vermek için bir teslimat adresi ekleyin.';
  String get completeOrder => isEnglish ? 'Complete order' : 'Siparişi Tamamla';
  String get total => isEnglish ? 'Total:' : 'Toplam Tutar:';
  String get subtotal => isEnglish ? 'Subtotal:' : 'Ara Toplam:';
  String get deliveryFeeLabel => isEnglish ? 'Delivery fee:' : 'Gönderim Ücreti:';
  String get free => isEnglish ? 'Free' : 'Ücretsiz';
  String freeDeliveryRemaining(String amount) => isEnglish
      ? 'Add $amount TL more for free delivery!'
      : 'Ücretsiz gönderim için $amount TL daha ekleyin!';
  String get freeDeliveryUnlocked => isEnglish
      ? 'Free delivery unlocked!'
      : 'Tebrikler, gönderim ücretsiz!';
  String get deliveryInfoTitle =>
      isEnglish ? 'Delivery Information' : 'Gönderim Bilgilendirmesi';
  String deliveryInfoBody(String threshold, String fee) => isEnglish
      ? 'Delivery is free for orders of $threshold TL and above.\n\n'
            'A delivery fee of $fee TL is added to orders below $threshold TL.'
      : '$threshold TL ve üzeri siparişlerde gönderim ücretsizdir.\n\n'
            '$threshold TL altındaki siparişlere $fee TL gönderim ücreti eklenir.';
  String get gotIt => isEnglish ? 'Got it' : 'Anladım';
  String get orderReceived => isEnglish ? 'Order received' : 'Sipariş alındı';
  String get orderCreated => isEnglish
      ? 'Your order was created successfully.'
      : 'Siparişiniz başarıyla oluşturuldu.';
  String get ok => isEnglish ? 'OK' : 'Tamam';
  String get addressPageTitle =>
      isEnglish ? 'Delivery address' : 'Teslimat adresi';
  String get addressPrompt =>
      isEnglish ? 'Where should we deliver?' : 'Siparişin nereye gelsin?';
  String get saveAddress => isEnglish ? 'Save address' : 'Adresi kaydet';
  String get productDescription =>
      isEnglish ? 'Product description' : 'Ürün Açıklaması';
  String get selectVariant => isEnglish ? 'Select a variant' : 'Varyant seçin';
  String get addToCart => isEnglish ? 'Add to cart' : 'Sepete Ekle';
  String get profile => isEnglish ? 'Profile' : 'Profil';
  String get popularProducts =>
      isEnglish ? 'Popular Products' : 'Popüler Ürünler';
  String get viewAll => isEnglish ? 'View All >' : 'Tümünü Gör >';
  String get selectLocation => isEnglish ? 'Select location' : 'Konum seçin';
  String get searchHint =>
      isEnglish ? 'Search products or categories...' : 'Ürün veya kategori ara...';
  String get weeklyDeals => isEnglish ? 'Weekly Deals' : 'Haftanın Fırsatları';
  String get freshDiscounts => isEnglish
      ? 'Special discounts on fresh items!'
      : 'Taze ürünlerde özel indirimler!';
  String get exploreNow => isEnglish ? 'Explore now >' : 'Şimdi keşfet >';
  String get upToDiscount => isEnglish ? 'Up to 50% off' : "%50'ye varan indirim";
  String get myOrders => isEnglish ? 'Order History' : 'Sipariş Geçmişim';
  String get savedAddresses =>
      isEnglish ? 'Saved Addresses' : 'Kayıtlı Adreslerim';
  String get logout => isEnglish ? 'Log Out' : 'Çıkış Yap';
  String get login => isEnglish ? 'Log In' : 'Giriş Yap';
  String get notifications => isEnglish ? 'Notifications' : 'Bildirimler';
  String get noNotifications =>
      isEnglish ? 'No notifications yet' : 'Henüz yeni bildiriminiz yok';
}
