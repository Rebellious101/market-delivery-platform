import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/constants.dart';
import '../core/localization.dart';
import '../models/product_model.dart';
import 'cart_manager.dart';

/// Ürün görselinin alt kısmına yerleşen etkileşimli sepet kontrolü.
///
/// Adet 0 iken sağ altta küçük köşeli bir "+" butonu görünür.
/// Ürün eklenince buton animasyonla kartın tüm genişliğine yayılıp
/// "−  adet  +" şeklinde bir hap (pill) kontrolüne dönüşür.
///
/// Bir `Stack` içinde `Positioned(left:, right:, bottom:)` ile kullanılmalıdır.
class AddToCartControl extends StatelessWidget {
  const AddToCartControl({
    super.key,
    required this.product,
    this.compact = false,
  });

  final Product product;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 30.0 : 38.0;

    return ListenableBuilder(
      listenable: CartManager(),
      builder: (context, _) {
        final qty = CartManager().quantityFor(product.id);
        final outOfStock = product.stock <= 0;
        final tobaccoLimitReached =
            product.isTobacco &&
            CartManager().totalTobaccoQuantity >=
                CartManager.maxTobaccoQuantity;
        final canAdd = !outOfStock && qty < product.stock;
        final expanded = qty > 0;

        void showTobaccoLimitSnack() {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(AppStrings.of(context).tobaccoLimitMessage),
                backgroundColor: Colors.red.shade600,
                duration: const Duration(seconds: 2),
              ),
            );
        }

        return LayoutBuilder(
          builder: (context, constraints) {
            final fullWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : size * 3.2;

            return Align(
              alignment: Alignment.centerRight,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                height: size,
                width: expanded ? fullWidth : size,
                decoration: BoxDecoration(
                  color: outOfStock
                      ? Colors.grey.shade400
                      : AppConstants.primaryColor,
                  borderRadius: BorderRadius.circular(
                    expanded ? size / 2 : size * 0.3,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: OverflowBox(
                  minWidth: 0,
                  maxWidth: fullWidth,
                  minHeight: size,
                  maxHeight: size,
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: expanded ? fullWidth : size,
                    height: size,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      transitionBuilder: (child, animation) =>
                          FadeTransition(opacity: animation, child: child),
                      child: expanded
                          ? Row(
                              key: const ValueKey('stepper'),
                              children: [
                                _TapIcon(
                                  icon: Icons.remove_rounded,
                                  size: size,
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    CartManager().decreaseQuantity(product.id);
                                  },
                                ),
                                Expanded(
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 160),
                                    transitionBuilder: (child, animation) =>
                                        ScaleTransition(
                                          scale: animation,
                                          child: child,
                                        ),
                                    child: Text(
                                      '$qty',
                                      key: ValueKey(qty),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                        fontSize: compact ? 14 : 17,
                                      ),
                                    ),
                                  ),
                                ),
                                _TapIcon(
                                  icon: Icons.add_rounded,
                                  size: size,
                                  enabled: canAdd,
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    if (tobaccoLimitReached) {
                                      showTobaccoLimitSnack();
                                      return;
                                    }
                                    CartManager().increaseQuantity(product.id);
                                  },
                                ),
                              ],
                            )
                          : _TapIcon(
                              key: const ValueKey('add'),
                              icon: Icons.add_rounded,
                              size: size,
                              enabled: canAdd,
                              onTap: () {
                                HapticFeedback.lightImpact();
                                if (tobaccoLimitReached) {
                                  showTobaccoLimitSnack();
                                  return;
                                }
                                CartManager().addItem(product);
                              },
                            ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _TapIcon extends StatelessWidget {
  const _TapIcon({
    super.key,
    required this.icon,
    required this.size,
    required this.onTap,
    this.enabled = true,
  });

  final IconData icon;
  final double size;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: enabled ? onTap : null,
      radius: size / 2,
      child: SizedBox(
        width: size,
        height: size,
        child: Icon(
          icon,
          size: size * 0.58,
          color: Colors.white.withValues(alpha: enabled ? 1 : 0.4),
        ),
      ),
    );
  }
}
