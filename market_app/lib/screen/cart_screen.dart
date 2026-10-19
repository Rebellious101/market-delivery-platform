import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../core/localization.dart';
import '../core/session_manager.dart';
import 'cart_manager.dart';
import 'address_book.dart';
import 'delivery_address_screen.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  bool _isLoading = false;

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

  // Flask API'ye sipariş gönderme fonksiyonu
  Future<void> _sendOrder() async {
    final cartItems = CartManager().items;
    if (cartItems.isEmpty) return;
    if (AddressBook.instance.selectedAddress == null) {
      _showErrorSnackBar('Siparişi tamamlamak için teslimat adresi seçin.');
      return;
    }

    if (!SessionManager.instance.isAuthenticated) {
      _showErrorSnackBar('Siparişi tamamlamak için lütfen önce giriş yapın.');
      return;
    }

    setState(() {
      _isLoading = true;
    });

    final selectedAddress = AddressBook.instance.selectedAddress?.fullText;
    final orderPayload = {
      'items': cartItems
          .map(
            (item) => {'product_id': item.product.id, 'quantity': item.quantity},
          )
          .toList(),
      if (selectedAddress != null && selectedAddress.isNotEmpty)
        'shipping_address': selectedAddress,
    };

    try {
      final response = await http
          .post(
            Uri.parse('${AppConstants.baseUrl}/api/orders'),
            headers: SessionManager.instance.authHeaders(),
            body: json.encode(orderPayload),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 201) {
        CartManager().clear();
        if (!mounted) return;

        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Sipariş alındı'),
            content: const Text('Siparişiniz başarıyla oluşturuldu.'),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.pop(context);
                },
                child: const Text('Tamam'),
              ),
            ],
          ),
        );
      } else if (response.statusCode == 401) {
        _showErrorSnackBar('Oturum süreniz doldu. Lütfen tekrar giriş yapın.');
      } else {
        String message = 'Sipariş oluşturulamadı.';
        try {
          final errorData = json.decode(response.body);
          if (errorData is Map<String, dynamic> && errorData['error'] != null) {
            message = errorData['error'].toString();
          }
        } on FormatException {
          message = 'Sunucudan geçersiz bir yanıt alındı.';
        }
        throw Exception(message);
      }
    } on TimeoutException {
      _showErrorSnackBar(
        'Sipariş gönderilemedi. Sunucu yanıt vermedi, lütfen tekrar deneyin.',
      );
    } catch (e) {
      _showErrorSnackBar('Sipariş gönderilemedi: ${_cleanErrorMessage(e)}');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
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

  String _cleanErrorMessage(Object error) {
    final message = error.toString();
    return message.startsWith('Exception: ')
        ? message.substring('Exception: '.length)
        : message;
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
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: AppConstants.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        strings.emptyCartDescription,
                        textAlign: TextAlign.center,
                        style: TextStyle(
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
                                          tooltip: 'Miktari azalt',
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
                                          tooltip: 'Miktari artir',
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
                                tooltip: 'Urunu kaldir',
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
                            style: TextStyle(
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
                          onPressed: _isLoading ? null : _sendOrder,
                          child: _isLoading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2.5,
                                    semanticsLabel: 'Sipariş gönderiliyor',
                                  ),
                                )
                              : Text(
                                  strings.completeOrder,
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
                    style: TextStyle(fontWeight: FontWeight.bold),
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
                  style: TextStyle(color: AppConstants.textSecondary),
                )
              else
                DropdownButtonFormField<String>(
                  initialValue: selectedAddress?.id,
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
            ],
          ),
        ),
      ),
    );
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
