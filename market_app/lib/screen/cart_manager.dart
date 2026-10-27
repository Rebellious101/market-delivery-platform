import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/local_storage.dart';
import '../models/product_model.dart';

class CartItem {
  Product product;
  int quantity;

  CartItem({required this.product, this.quantity = 1});

  factory CartItem.fromJson(Map<String, dynamic> json) {
    return CartItem(
      product: Product.fromJson(
        Map<String, dynamic>.from(json['product'] as Map? ?? {}),
      ),
      quantity: (json['quantity'] as num?)?.toInt() ?? 1,
    );
  }

  Map<String, dynamic> toJson() => {
    'product': product.toJson(),
    'quantity': quantity,
  };
}

class CartManager extends ChangeNotifier {
  // Singleton tasarımı (Uygulama genelinde tek bir sepet örneği olmasını sağlar)
  static final CartManager _instance = CartManager._internal();
  factory CartManager() => _instance;
  CartManager._internal();

  static const String _storageKey = 'shopping_cart_items';

  final List<CartItem> _items = [];

  List<CartItem> get items => _items;

  void restoreCart() {
    final raw = LocalStorage.instance.read(_storageKey);
    if (raw is List) {
      _items.clear();
      for (final entry in raw) {
        if (entry is Map) {
          final item = CartItem.fromJson(Map<String, dynamic>.from(entry));
          if (item.product.id > 0 && item.quantity > 0) {
            _items.add(item);
          }
        }
      }
    }
  }

  void _persistCart() {
    unawaited(
      LocalStorage.instance.write(
        _storageKey,
        _items.map((item) => item.toJson()).toList(),
      ),
    );
  }

  /// Sunucudan güncel ürün listesi geldiğinde sepetteki ürünlerin fiyat/stok bilgilerini günceller.
  void syncWithProducts(List<Product> latestProducts) {
    if (_items.isEmpty || latestProducts.isEmpty) return;

    final byId = {for (final p in latestProducts) p.id: p};
    bool changed = false;

    for (int i = _items.length - 1; i >= 0; i--) {
      final current = _items[i];
      final updatedProduct = byId[current.product.id];
      if (updatedProduct != null) {
        if (updatedProduct.stock <= 0) {
          _items.removeAt(i);
          changed = true;
        } else {
          final clampedQty = current.quantity > updatedProduct.stock
              ? updatedProduct.stock
              : current.quantity;
          if (current.product.price != updatedProduct.price ||
              current.product.stock != updatedProduct.stock ||
              current.product.title != updatedProduct.title ||
              current.product.imageUrl != updatedProduct.imageUrl ||
              current.quantity != clampedQty) {
            current.product = updatedProduct;
            current.quantity = clampedQty;
            changed = true;
          }
        }
      }
    }

    if (changed) {
      _persistCart();
      notifyListeners();
    }
  }

  int quantityFor(int productId) {
    final itemIndex = _items.indexWhere((item) => item.product.id == productId);
    return itemIndex >= 0 ? _items[itemIndex].quantity : 0;
  }

  // Sepete ürün ekleme
  void addItem(Product product) {
    if (product.stock <= 0) return;

    final existingIndex = _items.indexWhere(
      (item) => item.product.id == product.id,
    );
    if (existingIndex >= 0) {
      increaseQuantity(product.id);
    } else {
      _items.add(CartItem(product: product));
      _persistCart();
      notifyListeners();
    }
  }

  bool increaseQuantity(int productId) {
    final itemIndex = _items.indexWhere((item) => item.product.id == productId);
    if (itemIndex < 0) return false;

    final item = _items[itemIndex];
    if (item.quantity >= item.product.stock) return false;

    item.quantity += 1;
    _persistCart();
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
    _persistCart();
    notifyListeners();
  }

  // Sepetten ürün çıkarma
  void removeItem(int productId) {
    _items.removeWhere((item) => item.product.id == productId);
    _persistCart();
    notifyListeners();
  }

  // Sepeti tamamen temizleme
  void clear() {
    _items.clear();
    _persistCart();
    notifyListeners();
  }

  // Toplam tutarı hesaplama
  double get totalPrice {
    double total = 0;
    for (final item in _items) {
      total += item.product.price * item.quantity;
    }
    return total;
  }
}
