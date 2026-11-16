import '../core/age_verification.dart';
import '../core/constants.dart';
import 'category_model.dart';

class Product {
  final int id;
  final String title;
  final String description;
  final double price;
  final String imageUrl;
  final int stock;
  final bool minimumOrderExempt;
  final int? categoryId;
  final int? subcategoryId;
  final String category;
  final String subcategory;
  final List<String> variants;

  Product({
    required this.id,
    required this.title,
    required this.description,
    required this.price,
    required this.imageUrl,
    required this.stock,
    this.minimumOrderExempt = false,
    this.categoryId,
    this.subcategoryId,
    this.category = '',
    this.subcategory = '',
    this.variants = const ['Standart'],
  });

  bool get isAlcohol =>
      AgeVerification.isAlcoholText(category) ||
      AgeVerification.isAlcoholText(title) ||
      AgeVerification.isAlcoholText(description);

  bool get isTobacco =>
      minimumOrderExempt ||
      AgeVerification.isTobaccoText(category) ||
      AgeVerification.isTobaccoText(title) ||
      AgeVerification.isTobaccoText(description);

  bool get is18Plus => isAlcohol || isTobacco;

  bool matchesSubcategory(Subcategory sub) {
    if (subcategoryId != null && sub.id > 0) {
      return subcategoryId == sub.id;
    }
    if (subcategory.isNotEmpty) {
      return subcategory.toLowerCase() == sub.name.toLowerCase();
    }
    final lowerTitle = title.toLowerCase();
    final subLower = sub.name.toLowerCase();
    if (subLower.contains('maden suyu')) {
      return lowerTitle.contains('maden suyu') ||
          lowerTitle.contains('avşar') ||
          lowerTitle.contains('frutti elmalı') ||
          lowerTitle.contains('frutti limonlu');
    }
    if (subLower.contains('soğuk çay') || subLower.contains('kahve')) {
      return lowerTitle.contains('iced coffee') ||
          lowerTitle.contains('mr. brown') ||
          lowerTitle.contains('kahve') ||
          lowerTitle.contains('ice tea');
    }
    if (subLower.contains('meyve suyu')) {
      return lowerTitle.contains('nektar') ||
          lowerTitle.contains('meyve') ||
          lowerTitle.contains('elma suyu') ||
          lowerTitle.contains('vişne') ||
          lowerTitle.contains('limonata');
    }
    if (subLower.contains('gazlı')) {
      return lowerTitle.contains('cola') ||
          lowerTitle.contains('fanta') ||
          lowerTitle.contains('sprite') ||
          lowerTitle.contains('gazoz') ||
          lowerTitle.contains('frutti extra');
    }
    if (subLower.contains('cips') || subLower.contains('kraker')) {
      return lowerTitle.contains('cips') ||
          lowerTitle.contains('lays') ||
          lowerTitle.contains('kraker') ||
          lowerTitle.contains('crax') ||
          lowerTitle.contains('gong') ||
          lowerTitle.contains('patlağı');
    }
    if (subLower.contains('bisküvi') || subLower.contains('kek')) {
      return lowerTitle.contains('bisküvi') ||
          lowerTitle.contains('burçak') ||
          lowerTitle.contains('tutku') ||
          lowerTitle.contains('negro') ||
          lowerTitle.contains('benimo') ||
          lowerTitle.contains('kek') ||
          lowerTitle.contains('paykek') ||
          lowerTitle.contains('browni') ||
          lowerTitle.contains('topkek') ||
          lowerTitle.contains('popkek');
    }
    if (subLower.contains('çikolata') || subLower.contains('gofret')) {
      return lowerTitle.contains('çikolata') ||
          lowerTitle.contains('karam') ||
          lowerTitle.contains('canga') ||
          lowerTitle.contains('hoşbeş') ||
          lowerTitle.contains('bar');
    }
    if (subLower.contains('yulaf') || subLower.contains('gevreği')) {
      return lowerTitle.contains('yulaf') || lowerTitle.contains('lifalif');
    }
    if (subLower.contains('ekmek')) {
      return lowerTitle.contains('ekmek');
    }
    if (subLower == 'süt') {
      return lowerTitle.contains('süt');
    }
    if (subLower == 'bira') {
      return isAlcohol;
    }
    if (subLower == 'sigara') {
      return isTobacco;
    }
    return false;
  }

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
      minimumOrderExempt:
          json['minimum_order_exempt'] == true ||
          json['minimum_order_exempt'] == 1,
      categoryId: (json['category_id'] as num?)?.toInt(),
      subcategoryId: (json['subcategory_id'] as num?)?.toInt(),
      category: json['category']?.toString() ?? '',
      subcategory: json['subcategory']?.toString() ?? '',
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
    'minimum_order_exempt': minimumOrderExempt,
    'category_id': categoryId,
    'subcategory_id': subcategoryId,
    'category': category,
    'subcategory': subcategory,
    'variants': variants,
  };
}
