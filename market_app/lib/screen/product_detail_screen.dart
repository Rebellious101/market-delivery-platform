import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/local_storage.dart';
import '../core/localization.dart';
import '../models/product_model.dart';
import 'cart_manager.dart';

class ProductDetailScreen extends StatefulWidget {
  final Product product;

  const ProductDetailScreen({super.key, required this.product});

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  late String _selectedVariant;
  bool _isFavorite = false;

  Product get product => widget.product;

  @override
  void initState() {
    super.initState();
    _selectedVariant = product.variants.first;
    _checkFavorite();
  }

  void _checkFavorite() {
    try {
      final raw = LocalStorage.instance.read('favorite_product_ids');
      if (raw is List) {
        _isFavorite = raw.map((e) => int.tryParse(e.toString()) ?? 0).contains(product.id);
      }
    } catch (_) {}
  }

  Future<void> _toggleFavorite() async {
    setState(() => _isFavorite = !_isFavorite);
    try {
      final raw = LocalStorage.instance.read('favorite_product_ids');
      final list = (raw is List)
          ? raw.map((e) => int.tryParse(e.toString()) ?? 0).where((id) => id > 0).toSet()
          : <int>{};
      if (_isFavorite) {
        list.add(product.id);
      } else {
        list.remove(product.id);
      }
      await LocalStorage.instance.write('favorite_product_ids', list.toList());
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(product.title),
        backgroundColor: AppConstants.primaryColor,
        foregroundColor: AppConstants.textLight,
        actions: [
          IconButton(
            icon: Icon(
              _isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              color: _isFavorite ? Colors.redAccent : Colors.white,
            ),
            onPressed: _toggleFavorite,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 250,
            width: double.infinity,
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              panEnabled: true,
              child: Image.network(
                product.imageUrl,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    const Center(child: Icon(Icons.image_not_supported)),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(AppConstants.defaultPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          product.title,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: AppConstants.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${product.price.toStringAsFixed(2)} TL',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: AppConstants.primaryColor,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    strings.productDescription,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppConstants.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    product.description,
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppConstants.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    strings.selectVariant,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppConstants.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: product.variants
                        .map(
                          (variant) => ChoiceChip(
                            label: Text(variant),
                            selected: _selectedVariant == variant,
                            onSelected: (_) {
                              setState(() {
                                _selectedVariant = variant;
                              });
                            },
                          ),
                        )
                        .toList(),
                  ),
                  const Spacer(),
                  SizedBox(
                    width: double.infinity,
                    height: AppConstants.buttonHeight,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppConstants.primaryColor,
                        foregroundColor: AppConstants.textLight,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppConstants.defaultRadius,
                          ),
                        ),
                      ),
                      onPressed: () {
                        CartManager().addItem(product);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              '${product.title} ($_selectedVariant) sepete eklendi!',
                            ),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                      child: Text(
                        strings.addToCart,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
