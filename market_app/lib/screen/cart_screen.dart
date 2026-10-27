import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/localization.dart';
import '../core/session_manager.dart';
import '../models/address_model.dart';
import '../models/order_model.dart';
import 'address_book.dart';
import 'auth_screen.dart';
import 'cart_manager.dart';
import 'checkout_screen.dart';
import 'delivery_address_screen.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  @override
  void initState() {
    super.initState();
    AddressBook.instance.addListener(_onAddressChanged);
  }

  @override
  void dispose() {
    AddressBook.instance.removeListener(_onAddressChanged);
    super.dispose();
  }

  void _onAddressChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _proceedToCheckout() async {
    final cart = CartManager();
    final cartItems = cart.items;
    if (cartItems.isEmpty) return;

    final selectedAddress = AddressBook.instance.selectedAddress;
    if (selectedAddress == null) {
      _showErrorSnackBar('Siparişi tamamlamak için teslimat adresi seçin.');
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

    final addressModel = AddressModel(
      id: int.tryParse(selectedAddress.id),
      title: selectedAddress.title,
      fullAddress: selectedAddress.fullText,
      city: selectedAddress.city.isNotEmpty
          ? selectedAddress.city
          : 'Gazimağusa',
      district: selectedAddress.district.isNotEmpty
          ? selectedAddress.district
          : 'Gazimağusa',
      latitude: selectedAddress.latitude,
      longitude: selectedAddress.longitude,
    );

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

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CheckoutScreen(
          selectedAddress: addressModel,
          cartItems: orderItems,
          totalPrice: cart.totalPrice,
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
      appBar: AppBar(
        title: Text(strings.myCart),
        backgroundColor: AppConstants.primaryColor,
        foregroundColor: AppConstants.textLight,
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
                _buildAddressSelector(),
                Expanded(
                  child: ListView.builder(
                    itemCount: cart.items.length,
                    itemBuilder: (context, index) {
                      final item = cart.items[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  item.product.imageUrl,
                                  width: 72,
                                  height: 72,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) =>
                                      const SizedBox(
                                        width: 72,
                                        height: 72,
                                        child: Icon(Icons.image_not_supported),
                                      ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.product.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      '${item.product.price.toStringAsFixed(2)} TL',
                                      style: const TextStyle(
                                        color: AppConstants.primaryColor,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Stok: ${item.product.stock}',
                                      style: const TextStyle(
                                        color: AppConstants.textSecondary,
                                        fontSize: 12,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        _QuantityButton(
                                          icon: Icons.remove,
                                          tooltip: 'Miktarı azalt',
                                          onPressed: () {
                                            setState(() {
                                              cart.decreaseQuantity(
                                                item.product.id,
                                              );
                                            });
                                          },
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                          ),
                                          child: Text(
                                            '${item.quantity}',
                                            style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        _QuantityButton(
                                          icon: Icons.add,
                                          tooltip: 'Miktarı artır',
                                          onPressed:
                                              item.quantity >=
                                                  item.product.stock
                                              ? null
                                              : () {
                                                  setState(() {
                                                    cart.increaseQuantity(
                                                      item.product.id,
                                                    );
                                                  });
                                                },
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline),
                                color: AppConstants.errorColor,
                                tooltip: 'Ürünü kaldır',
                                onPressed: () {
                                  setState(() {
                                    cart.removeItem(item.product.id);
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.grey.withValues(alpha: 0.2),
                        spreadRadius: 1,
                        blurRadius: 5,
                        offset: const Offset(0, -3),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            strings.total,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            '${cart.totalPrice.toStringAsFixed(2)} TL',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: AppConstants.primaryColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 15),
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
                          onPressed: _proceedToCheckout,
                          child: Text(
                            strings.completeOrder,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildAddressSelector() {
    final addressBook = AddressBook.instance;
    final selectedAddress = addressBook.selectedAddress;
    final strings = AppStrings.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    strings.delivery,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  TextButton.icon(
                    onPressed: _addNewAddress,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(strings.newAddress),
                  ),
                ],
              ),
              if (addressBook.addresses.isEmpty)
                Text(
                  strings.selectAddress,
                  style: const TextStyle(color: AppConstants.textSecondary),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(selectedAddress?.id),
                        initialValue: selectedAddress?.id,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.location_on_outlined),
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: addressBook.addresses
                            .map(
                              (address) => DropdownMenuItem<String>(
                                value: address.id,
                                child: Text(
                                  '${address.title} - ${address.fullText}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (id) {
                          if (id != null) addressBook.select(id);
                        },
                      ),
                    ),
                    if (selectedAddress != null) ...[
                      const SizedBox(width: 6),
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        color: AppConstants.errorColor,
                        tooltip: 'Seçili adresi sil',
                        onPressed: () => _confirmDeleteAddress(selectedAddress),
                      ),
                    ],
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteAddress(Address address) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Adresi Sil'),
        content: Text(
          '"${address.title}" başlıklı kayıtlı adresi silmek istediğinize emin misiniz?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppConstants.errorColor,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await AddressBook.instance.deleteAddress(context, address.id);
    }
  }

  Future<void> _addNewAddress() async {
    final address = await Navigator.push<Address>(
      context,
      MaterialPageRoute(builder: (_) => const DeliveryAddressScreen()),
    );
    if (address != null) AddressBook.instance.add(address);
  }
}

class _QuantityButton extends StatelessWidget {
  const _QuantityButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: IconButton.filledTonal(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
