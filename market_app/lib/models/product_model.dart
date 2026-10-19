import '../core/constants.dart';

class Product {
  final int id;
  final String title;
  final String description;
  final double price;
  final String imageUrl;
  final int stock;
  final List<String> variants;

  Product({
    required this.id,
    required this.title,
    required this.description,
    required this.price,
    required this.imageUrl,
    required this.stock,
    this.variants = const ['Standart'],
  });

  factory Product.fromJson(Map<String, dynamic> json) {
    return Product(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      price: double.tryParse(json['price']?.toString() ?? '') ?? 0.0,
      // Flask'ta resim adı tutulduğu için tam URL'yi veya yerel yolu ayarlıyoruz:
      imageUrl: json['image'] != null && json['image'].toString().isNotEmpty
          ? '${AppConstants.baseUrl}/static/uploads/${json['image']}'
          : 'https://picsum.photos/200',
      stock: (json['stock'] as num?)?.toInt() ?? 0,
      variants:
          (json['variants'] as List<dynamic>?)
              ?.map((variant) => variant.toString())
              .where((variant) => variant.isNotEmpty)
              .toList() ??
          const ['Standart'],
    );
  }
}
