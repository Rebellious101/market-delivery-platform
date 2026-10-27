import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../core/session_manager.dart';
import '../models/address_model.dart';
import '../models/order_model.dart';
import 'cart_manager.dart';

class CheckoutScreen extends StatefulWidget {
  final AddressModel selectedAddress;
  final List<OrderItemModel> cartItems;
  final double totalPrice;

  const CheckoutScreen({
    super.key,
    required this.selectedAddress,
    required this.cartItems,
    required this.totalPrice,
  });

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  String _selectedPaymentMethod = 'Nakit';
  bool _isSubmitting = false;

  Future<void> _submitOrder() async {
    if (!SessionManager.instance.isAuthenticated) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Siparişi tamamlamak için lütfen önce giriş yapın.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    final url = Uri.parse('${AppConstants.baseUrl}/api/orders');

    final orderData = OrderModel(
      address: widget.selectedAddress,
      items: widget.cartItems,
      totalPrice: widget.totalPrice,
      paymentMethod: _selectedPaymentMethod,
    );

    try {
      final response = await http
          .post(
            url,
            headers: SessionManager.instance.authHeaders(),
            body: jsonEncode(orderData.toJson()),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 201 && mounted) {
        CartManager().clear();
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.green),
                SizedBox(width: 8),
                Text('Sipariş Alındı'),
              ],
            ),
            content: Text(
              'Siparişiniz başarıyla oluşturuldu.\nÖdeme Yöntemi: $_selectedPaymentMethod',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                style: FilledButton.styleFrom(
                  backgroundColor: AppConstants.primaryColor,
                ),
                child: const Text('Tamam'),
              ),
            ],
          ),
        );
        if (mounted) {
          Navigator.popUntil(context, (route) => route.isFirst);
        }
      } else if (response.statusCode == 401 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Oturum süreniz doldu. Lütfen tekrar giriş yapın.'),
            backgroundColor: Colors.red,
          ),
        );
      } else if (mounted) {
        String errorMessage = 'Sipariş verilemedi (${response.statusCode}).';
        try {
          final body = jsonDecode(response.body);
          if (body is Map && body['error'] != null) {
            errorMessage = body['error'].toString();
          }
        } catch (_) {}
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMessage), backgroundColor: Colors.red),
        );
      }
    } on TimeoutException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Sipariş gönderilemedi. Sunucu yanıt vermedi, lütfen tekrar deneyin.',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Bağlantı hatası: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final addressSubtitle =
        widget.selectedAddress.district.isNotEmpty &&
            !widget.selectedAddress.fullAddress.contains(
              widget.selectedAddress.district,
            )
        ? '${widget.selectedAddress.fullAddress}\n${widget.selectedAddress.district}'
        : widget.selectedAddress.fullAddress;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Siparişi Tamamla'),
        backgroundColor: AppConstants.primaryColor,
        foregroundColor: AppConstants.textLight,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // 1. Adres Özeti
          const Text(
            'Teslimat Adresi',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(
                Icons.location_on,
                color: AppConstants.primaryColor,
              ),
              title: Text(
                widget.selectedAddress.title,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(addressSubtitle),
            ),
          ),
          const SizedBox(height: 20),

          // 2. Ödeme Yöntemi Seçimi
          const Text(
            'Ödeme Yöntemi',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Card(
            child: RadioGroup<String>(
              groupValue: _selectedPaymentMethod,
              onChanged: (String? val) {
                if (val != null) {
                  setState(() => _selectedPaymentMethod = val);
                }
              },
              child: const Column(
                children: [
                  RadioListTile<String>(
                    value: 'Nakit',
                    title: Text(
                      'Nakit',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text('Teslimatta nakit ödeme'),
                    secondary: Icon(
                      Icons.payments_outlined,
                      color: AppConstants.primaryColor,
                    ),
                  ),
                  Divider(height: 1),
                  RadioListTile<String>(
                    value: 'Banka / Kredi Kartı',
                    title: Text(
                      'Banka / Kredi Kartı',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text('Banka veya kredi kartı ile ödeme'),
                    secondary: Icon(
                      Icons.credit_card_outlined,
                      color: AppConstants.primaryColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 3. Sipariş Özeti
          const Text(
            'Sipariş Özeti',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: widget.cartItems
                    .map(
                      (item) => ListTile(
                        dense: true,
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text('${item.quantity} adet'),
                        trailing: Text(
                          '${(item.price * item.quantity).toStringAsFixed(2)} TL',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 4. Tutar ve Onay
          Card(
            color: Colors.grey.shade100,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Seçilen Ödeme Yöntemi:',
                        style: TextStyle(color: AppConstants.textSecondary),
                      ),
                      Text(
                        _selectedPaymentMethod,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Toplam Tutar:',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '${widget.totalPrice.toStringAsFixed(2)} TL',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: AppConstants.primaryColor,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // 5. Siparişi Onayla Butonu
          SizedBox(
            height: AppConstants.buttonHeight,
            child: ElevatedButton(
              onPressed: _isSubmitting ? null : _submitOrder,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppConstants.primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(
                    AppConstants.defaultRadius,
                  ),
                ),
              ),
              child: _isSubmitting
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : const Text(
                      'Siparişi Onayla ve Bitir',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
