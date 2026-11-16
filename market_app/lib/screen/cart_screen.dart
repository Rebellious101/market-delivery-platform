import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../core/localization.dart';
import '../core/session_manager.dart';
import '../models/order_model.dart';
import 'auth_screen.dart';
import 'cart_manager.dart';
import 'checkout_screen.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  double _minimumOrderAmount = 450;
  bool _isMinimumOrderSettingsLoaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMinimumOrderAmount());
  }

  Future<void> _loadMinimumOrderAmount() async {
    try {
      final response = await http
          .get(Uri.parse('${AppConstants.baseUrl}/api/store-settings'))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw Exception(
          'Minimum sepet ayarı yüklenemedi (${response.statusCode}).',
        );
      }

      final data = jsonDecode(response.body);
      final amount = data is Map ? data['minimum_order_amount'] : null;
      if (amount is! num || !amount.isFinite || amount < 0) {
        throw const FormatException(
          'Sunucu geçersiz minimum sepet tutarı döndürdü.',
        );
      }

      if (!mounted) return;
      setState(() {
        _minimumOrderAmount = amount.toDouble();
        _isMinimumOrderSettingsLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isMinimumOrderSettingsLoaded = false;
      });
    }
  }

  Future<void> _proceedToCheckout() async {
    final cart = CartManager();
    final cartItems = cart.items;
    if (cartItems.isEmpty) return;

    if (!_isMinimumOrderSettingsLoaded) {
      _showErrorSnackBar(
        AppStrings.of(context).minimumOrderSettingsUnavailable,
      );
      return;
    }
    if (cart.minimumOrderTotal < _minimumOrderAmount) {
      final remaining = _minimumOrderAmount - cart.minimumOrderTotal;
      _showErrorSnackBar(
        AppStrings.of(context)
            .minimumOrderRemaining(remaining.toStringAsFixed(2)),
      );
      return;
    }

    if (!SessionManager.instance.isAuthenticated) {
      _showErrorSnackBar('Siparişi tamamlamak için lütfen önce giriş yapın.');
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const AuthScreen()),
      );
      if (!mounted || !SessionManager.instance.isAuthenticated) {
        return;
      }
    }

    final orderItems = cartItems
        .map(
          (item) => OrderItemModel(
            productId: item.product.id,
            title: item.product.title,
            quantity: item.quantity,
            price: item.product.price,
          ),
        )
        .toList();

    final deliveryFee = AppConstants.deliveryFeeFor(cart.totalPrice);
    final finalTotal = cart.totalPrice + deliveryFee;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CheckoutScreen(
          cartItems: orderItems,
          totalPrice: finalTotal,
          deliveryFee: deliveryFee,
        ),
      ),
    );

    if (mounted) {
      setState(() {});
    }
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: AppConstants.errorColor,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final cart = CartManager();
    final strings = AppStrings.of(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7F6),
      appBar: AppBar(
        title: Text(
          strings.myCart,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        backgroundColor: AppConstants.primaryColor,
        foregroundColor: AppConstants.textLight,
        elevation: 0,
        actions: [
          if (cart.items.isNotEmpty) ...[
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz),
              tooltip: 'Diğer',
              onSelected: (value) {
                if (value == 'continue') Navigator.pop(context);
                if (value == 'clear') _confirmClearCart();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'continue',
                  child: Text('Alışverişe devam et'),
                ),
                PopupMenuItem(value: 'clear', child: Text('Sepeti boşalt')),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Sepeti boşalt',
              onPressed: _confirmClearCart,
            ),
          ],
        ],
      ),
      body: cart.items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 132,
                        height: 132,
                        decoration: BoxDecoration(
                          color: AppConstants.primaryColor.withValues(
                            alpha: 0.1,
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: 92,
                              height: 92,
                              decoration: BoxDecoration(
                                color: AppConstants.primaryColor.withValues(
                                  alpha: 0.14,
                                ),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const Icon(
                              Icons.shopping_bag_outlined,
                              size: 54,
                              color: AppConstants.primaryColor,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 28),
                      Text(
                        strings.emptyCartTitle,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: AppConstants.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        strings.emptyCartDescription,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: AppConstants.textSecondary,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: FilledButton.icon(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.explore_outlined),
                          label: Text(strings.discoverProducts),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppConstants.primaryColor,
                            foregroundColor: AppConstants.textLight,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                AppConstants.defaultRadius,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 4, bottom: 12),
                        child: Text(
                          '${cart.items.length} Ürün',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppConstants.textSecondary,
                          ),
                        ),
                      ),
                      for (final item in cart.items)
                        _CartItemCard(
                          item: item,
                          exemptLabel: strings.minimumOrderExcludedProduct,
                          onDecrease: () => setState(
                            () => cart.decreaseQuantity(item.product.id),
                          ),
                          onIncrease: (item.quantity >= item.product.stock ||
                                  (item.product.isTobacco &&
                                      cart.totalTobaccoQuantity >=
                                          CartManager.maxTobaccoQuantity))
                              ? null
                              : () => setState(
                                  () => cart.increaseQuantity(item.product.id),
                                ),
                          onRemove: () => setState(
                            () => cart.removeItem(item.product.id),
                          ),
                        ),
                    ],
                  ),
                ),
                _buildSummarySheet(strings, cart),
              ],
            ),
    );
  }

  Future<void> _confirmClearCart() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sepeti boşalt'),
        content: const Text(
          'Sepetinizdeki tüm ürünler kaldırılacak. Emin misiniz?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppConstants.errorColor,
            ),
            child: const Text('Boşalt'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      setState(() => CartManager().clear());
    }
  }

  Widget _buildSummarySheet(AppStrings strings, CartManager cart) {
    final subtotal = cart.totalPrice;
    final fee = AppConstants.deliveryFeeFor(subtotal);

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            _buildPriceRow(
              strings.subtotal,
              '${subtotal.toStringAsFixed(2)} TL',
            ),
            const SizedBox(height: 10),
            _buildPriceRow(
              strings.deliveryFeeLabel,
              fee == 0 ? strings.free : '${fee.toStringAsFixed(2)} TL',
              valueColor: fee == 0 ? AppConstants.primaryColor : null,
              info:
                  '${AppConstants.freeDeliveryThreshold.toStringAsFixed(0)} TL '
                  've üzeri siparişlerde gönderim ücretsizdir.',
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: _DashedDivider(),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  strings.total,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: AppConstants.textPrimary,
                  ),
                ),
                Text(
                  '${(subtotal + fee).toStringAsFixed(2)} TL',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: AppConstants.primaryColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: FilledButton(
                onPressed: _proceedToCheckout,
                style: FilledButton.styleFrom(
                  backgroundColor: AppConstants.primaryColor,
                  foregroundColor: AppConstants.textLight,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  strings.completeOrder,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPriceRow(
    String label,
    String value, {
    Color? valueColor,
    String? info,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: AppConstants.textSecondary,
                fontSize: 14,
              ),
            ),
            if (info != null) ...[
              const SizedBox(width: 4),
              Tooltip(
                message: info,
                triggerMode: TooltipTriggerMode.tap,
                child: const Icon(
                  Icons.info_outline,
                  size: 14,
                  color: AppConstants.textSecondary,
                ),
              ),
            ],
          ],
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: valueColor ?? AppConstants.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _CartItemCard extends StatelessWidget {
  const _CartItemCard({
    required this.item,
    required this.exemptLabel,
    required this.onDecrease,
    required this.onIncrease,
    required this.onRemove,
  });

  final CartItem item;
  final String exemptLabel;
  final VoidCallback onDecrease;
  final VoidCallback? onIncrease;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final product = item.product;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFECEFF1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 82,
            height: 82,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFEDF1EE), width: 1.2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                product.imageUrl,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) => const Icon(
                  Icons.image_not_supported_outlined,
                  color: AppConstants.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        product.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: AppConstants.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: onRemove,
                      borderRadius: BorderRadius.circular(8),
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(
                          Icons.delete_outline,
                          size: 20,
                          color: Color(0xFFE53935),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  product.stock > 0
                      ? 'Stokta var (${product.stock} adet)'
                      : 'Stokta yok',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF78909C),
                  ),
                ),
                if (product.minimumOrderExempt) ...[
                  const SizedBox(height: 2),
                  Text(
                    exemptLabel,
                    style: const TextStyle(
                      color: AppConstants.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${product.price.toStringAsFixed(2)} TL',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        color: AppConstants.primaryColor,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF3F6F4),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: const Color(0xFFE3E9E5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _PillCircleButton(
                            icon: Icons.remove,
                            backgroundColor: Colors.white,
                            iconColor: AppConstants.textPrimary,
                            onTap: onDecrease,
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              '${item.quantity}',
                              style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                                color: AppConstants.textPrimary,
                              ),
                            ),
                          ),
                          _PillCircleButton(
                            icon: Icons.add,
                            backgroundColor: const Color(0xFFDDF2E3),
                            iconColor: AppConstants.primaryColor,
                            onTap: onIncrease,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PillCircleButton extends StatelessWidget {
  const _PillCircleButton({
    required this.icon,
    required this.backgroundColor,
    required this.iconColor,
    required this.onTap,
  });

  final IconData icon;
  final Color backgroundColor;
  final Color iconColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Material(
      color: disabled ? Colors.grey.shade200 : backgroundColor,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(
            icon,
            size: 16,
            color: disabled ? Colors.grey.shade400 : iconColor,
          ),
        ),
      ),
    );
  }
}

class _DashedDivider extends StatelessWidget {
  const _DashedDivider();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final dashCount = (constraints.constrainWidth() / 8).floor();
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(
            dashCount,
            (_) => Container(
              width: 4,
              height: 1,
              color: const Color(0xFFD5DCE0),
            ),
          ),
        );
      },
    );
  }
}
