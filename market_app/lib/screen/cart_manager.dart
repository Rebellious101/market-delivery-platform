import 'package:flutter/foundation.dart';
import '../models/product_model.dart';

class CartItem {
  final Product product;
  int quantity;

  CartItem({required this.product, this.quantity = 1});
}

class CartManager extends ChangeNotifier {
  // Singleton tasarımı (Uygulama genelinde tek bir sepet örneği olmasını sağlar)
  static final CartManager _instance = CartManager._internal();
  factory CartManager() => _instance;
  CartManager._internal();

  final List<CartItem> _items = [];

  List<CartItem> get items => _items;

  int quantityFor(int productId) {
    final itemIndex = _items.indexWhere((item) => item.product.id == productId);
    return itemIndex >= 0 ? _items[itemIndex].quantity : 0;
  }

  // Sepete ürün ekleme
  void addItem(Product product) {
    if (product.stock <= 0) return;

    var existingIndex = _items.indexWhere(
      (item) => item.product.id == product.id,
    );
    if (existingIndex >= 0) {
      increaseQuantity(product.id);
    } else {
      _items.add(CartItem(product: product));
      notifyListeners();
    }
  }

  bool increaseQuantity(int productId) {
    final itemIndex = _items.indexWhere((item) => item.product.id == productId);
    if (itemIndex < 0) return false;

    final item = _items[itemIndex];
    if (item.quantity >= item.product.stock) return false;

    item.quantity += 1;
    notifyListeners();
    return true;
  }

  void decreaseQuantity(int productId) {
    final itemIndex = _items.indexWhere((item) => item.product.id == productId);
    if (itemIndex < 0) return;

    final item = _items[itemIndex];
    if (item.quantity > 1) {
      item.quantity -= 1;
    } else {
      _items.removeAt(itemIndex);
    }
    notifyListeners();
  }

  // Sepetten ürün çıkarma
  void removeItem(int productId) {
    _items.removeWhere((item) => item.product.id == productId);
    notifyListeners();
  }

  // Sepeti tamamen temizleme
  void clear() {
    _items.clear();
    notifyListeners();
  }

  // Toplam tutarı hesaplama
  double get totalPrice {
    double total = 0;
    for (var item in _items) {
      total += item.product.price * item.quantity;
    }
    return total;
  }
}
