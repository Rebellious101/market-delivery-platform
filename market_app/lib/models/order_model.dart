import 'address_model.dart';

class OrderItemModel {
  final int productId;
  final String title;
  final int quantity;
  final double price;

  OrderItemModel({
    required this.productId,
    required this.title,
    required this.quantity,
    required this.price,
  });

  Map<String, dynamic> toJson() => {
    'product_id': productId,
    'quantity': quantity,
    'price': price,
  };
}

class OrderModel {
  final AddressModel address;
  final List<OrderItemModel> items;
  final double totalPrice;
  final String paymentMethod; // 'Nakit' veya 'Banka / Kredi Kartı'

  OrderModel({
    required this.address,
    required this.items,
    required this.totalPrice,
    required this.paymentMethod,
  });

  Map<String, dynamic> toJson() => {
    'address_id': address.id,
    'shipping_address': address.fullAddress,
    'full_address': address.fullAddress,
    'items': items.map((item) => item.toJson()).toList(),
    'total_price': totalPrice,
    'payment_method': paymentMethod,
  };
}
