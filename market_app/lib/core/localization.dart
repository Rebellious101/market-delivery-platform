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
  String get campaignsSoon =>
      isEnglish ? 'Campaigns are coming soon' : 'Kampanyalar yakında burada';
  String get campaignsDescription => isEnglish
      ? 'Follow special offers and discounts here.'
      : 'Avantajlı fırsatları ve özel indirimleri bu alandan takip edebileceksiniz.';
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
}
