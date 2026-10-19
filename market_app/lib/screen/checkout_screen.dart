import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import '../models/address_model.dart';
import '../models/order_model.dart';

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
  String _selectedPaymentMethod = 'Kapıda Ödeme';
  bool _isSubmitting = false;

  Future<void> _submitOrder(String jwtToken) async {
    setState(() => _isSubmitting = true);

    final url = Uri.parse('${AppConstants.baseUrl}/api/orders');

    final orderData = OrderModel(
      address: widget.selectedAddress,
      items: widget.cartItems,
      totalPrice: widget.totalPrice,
      paymentMethod: _selectedPaymentMethod,
    );

    try {
      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $jwtToken',
        },
        body: jsonEncode(orderData.toJson()),
      );

      if (response.statusCode == 201 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🎉 Siparişiniz başarıyla oluşturuldu!'),
            backgroundColor: Colors.green,
          ),
        );
        // Sipariş başarılıysa ana sayfaya veya sipariş geçmişine yönlendir
        Navigator.popUntil(context, (route) => route.isFirst);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Sipariş verilemedi: ${response.body}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Bağlantı hatası: $e'),
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
          const Text('Teslimat Adresi', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.location_on, color: AppConstants.primaryColor),
              title: Text(widget.selectedAddress.title, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                '${widget.selectedAddress.fullAddress}\n${widget.selectedAddress.district}/${widget.selectedAddress.city}',
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 2. Ödeme Yöntemi Seçimi (RadioGroup Kullanımı)
          const Text('Ödeme Yöntemi', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Card(
            child: RadioGroup<String>(
              groupValue: _selectedPaymentMethod,
              onChanged: (String? val) {
                if (val != null) {
                  setState(() => _selectedPaymentMethod = val);
                }
              },
              child: Column(
                children: const [
                  RadioListTile<String>(
                    title: Text('Kapıda Ödeme (Nakit/Kredi Kartı)'),
                    value: 'Kapıda Ödeme',
                  ),
                  RadioListTile<String>(
                    title: Text('Online Kredi Kartı'),
                    value: 'Kredi Kartı',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 3. Tutar ve Onay
          Card(
            color: Colors.grey.shade100,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Toplam Tutar:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  Text(
                    '${widget.totalPrice.toStringAsFixed(2)} ₺',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppConstants.primaryColor),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // 4. Siparişi Onayla Butonu
          SizedBox(
            height: AppConstants.buttonHeight,
            child: ElevatedButton(
              onPressed: _isSubmitting ? null : () => _submitOrder("MEVCUT_JWT_TOKEN"),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppConstants.primaryColor,
                foregroundColor: Colors.white,
              ),
              child: _isSubmitting
                  ? const CircularProgressIndicator(color: Colors.white)
                  : const Text('Siparişi Onayla ve Bitir', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}