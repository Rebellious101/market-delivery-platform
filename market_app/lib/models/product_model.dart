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
    final storedImageUrl = (json['image_url']?.toString() ?? '').replaceFirst(
      'http://localhost:5000',
      AppConstants.baseUrl,
    );
    final imageField = json['image']?.toString() ?? '';
    final resolvedImageUrl = storedImageUrl.isNotEmpty
        ? storedImageUrl
        : (imageField.isNotEmpty
              ? '${AppConstants.baseUrl}/static/uploads/$imageField'
              : 'https://picsum.photos/200');

    return Product(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: json['name']?.toString() ?? json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      price: double.tryParse(json['price']?.toString() ?? '') ?? 0.0,
      imageUrl: resolvedImageUrl,
      stock: (json['stock'] as num?)?.toInt() ?? 0,
      variants:
          (json['variants'] as List<dynamic>?)
              ?.map((variant) => variant.toString())
              .where((variant) => variant.isNotEmpty)
              .toList() ??
          const ['Standart'],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': title,
    'description': description,
    'price': price,
    'image_url': imageUrl,
    'stock': stock,
    'variants': variants,
  };
}
