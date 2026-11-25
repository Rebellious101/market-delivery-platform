import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/age_verification.dart';
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
  static const int maxTobaccoQuantity = 2;

  final List<CartItem> _items = [];

  List<CartItem> get items => _items;

  int get totalTobaccoQuantity {
    int total = 0;
    for (final item in _items) {
      if (item.product.isTobacco) {
        total += item.quantity;
      }
    }
    return total;
  }

  void restoreCart() {
    final raw = LocalStorage.instance.read(_storageKey);
    if (raw is List) {
      _items.clear();
      for (final entry in raw) {
        if (entry is Map) {
          final item = CartItem.fromJson(Map<String, dynamic>.from(entry));
          if (item.product.id > 0 &&
              item.quantity > 0 &&
              !(AgeVerification.isTobaccoRestrictedPlatform &&
                  item.product.isTobacco)) {
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
      if (AgeVerification.isTobaccoRestrictedPlatform &&
          current.product.isTobacco) {
        _items.removeAt(i);
        changed = true;
        continue;
      }
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
              current.product.minimumOrderExempt !=
                  updatedProduct.minimumOrderExempt ||
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
  bool addItem(Product product) {
    if (product.stock <= 0) return false;
    if (AgeVerification.isTobaccoRestrictedPlatform && product.isTobacco) {
      return false;
    }
    if (product.isTobacco && totalTobaccoQuantity >= maxTobaccoQuantity) {
      return false;
    }

    final existingIndex = _items.indexWhere(
      (item) => item.product.id == product.id,
    );
    if (existingIndex >= 0) {
      return increaseQuantity(product.id);
    } else {
      _items.add(CartItem(product: product));
      _persistCart();
      notifyListeners();
      return true;
    }
  }

  bool increaseQuantity(int productId) {
    final itemIndex = _items.indexWhere((item) => item.product.id == productId);
    if (itemIndex < 0) return false;

    final item = _items[itemIndex];
    if (item.quantity >= item.product.stock) return false;
    if (item.product.isTobacco && totalTobaccoQuantity >= maxTobaccoQuantity) {
      return false;
    }

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

  // Toplam ürün adedi
  int get totalQuantity {
    int total = 0;
    for (final item in _items) {
      total += item.quantity;
    }
    return total;
  }

  // Toplam tutarı hesaplama
  double get totalPrice {
    double total = 0;
    for (final item in _items) {
      total += item.product.price * item.quantity;
    }
    return total;
  }

  /// Subtotal used to validate the minimum order amount, excluding exempt items.
  double get minimumOrderTotal {
    double total = 0;
    for (final item in _items) {
      if (!item.product.minimumOrderExempt) {
        total += item.product.price * item.quantity;
      }
    }
    return total;
  }
}
