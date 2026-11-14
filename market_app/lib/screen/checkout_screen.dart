import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../core/localization.dart';
import '../core/session_manager.dart';
import '../models/address_model.dart';
import '../models/order_model.dart';
import 'address_book.dart';
import 'cart_manager.dart';
import 'delivery_address_screen.dart';

class CheckoutScreen extends StatefulWidget {
  final AddressModel? selectedAddress;
  final List<OrderItemModel> cartItems;
  final double totalPrice;
  final double? deliveryFee;

  const CheckoutScreen({
    super.key,
    this.selectedAddress,
    required this.cartItems,
    required this.totalPrice,
    this.deliveryFee,
  });

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  String _selectedPaymentMethod = 'Nakit';
  bool _isSubmitting = false;

  double get _subtotal => widget.cartItems.fold(
        0.0,
        (sum, item) => sum + (item.price * item.quantity),
      );

  double get _deliveryFee =>
      widget.deliveryFee ?? AppConstants.deliveryFeeFor(_subtotal);

  double get _finalTotal => _subtotal + _deliveryFee;

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

  AddressModel? _resolveCurrentAddress() {
    final selected = AddressBook.instance.selectedAddress;
    if (selected != null) {
      return AddressModel(
        id: int.tryParse(selected.id),
        title: selected.title,
        fullAddress: selected.fullText,
        city: selected.city.isNotEmpty ? selected.city : 'Gazimağusa',
        district: selected.district.isNotEmpty
            ? selected.district
            : 'Gazimağusa',
        latitude: selected.latitude,
        longitude: selected.longitude,
      );
    }
    return widget.selectedAddress;
  }

  Future<void> _addNewAddress() async {
    final address = await Navigator.push<Address>(
      context,
      MaterialPageRoute(builder: (_) => const DeliveryAddressScreen()),
    );
    if (address != null) {
      AddressBook.instance.add(address);
    }
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

    final addressModel = _resolveCurrentAddress();
    if (addressModel == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Siparişi tamamlamak için lütfen bir teslimat adresi seçin veya yeni adres ekleyin.',
          ),
          backgroundColor: AppConstants.errorColor,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    final url = Uri.parse('${AppConstants.baseUrl}/api/orders');

    final orderData = OrderModel(
      address: addressModel,
      items: widget.cartItems,
      totalPrice: _finalTotal,
      paymentMethod: _selectedPaymentMethod,
      phone: SessionManager.instance.userPhone,
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
              'Siparişiniz başarıyla oluşturuldu.\nToplam Tutar: ${_finalTotal.toStringAsFixed(2)} TL\nÖdeme Yöntemi: $_selectedPaymentMethod',
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

  Widget _buildAddressSelectionCard() {
    final addressBook = AddressBook.instance;
    final selectedAddress = addressBook.selectedAddress;
    final strings = AppStrings.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  strings.delivery,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextButton.icon(
                  onPressed: _isSubmitting ? null : _addNewAddress,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(strings.newAddress),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (addressBook.addresses.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppConstants.errorColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppConstants.errorColor.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: AppConstants.errorColor,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        strings.selectAddress,
                        style: const TextStyle(
                          color: AppConstants.errorColor,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      key: ValueKey(selectedAddress?.id),
                      initialValue: selectedAddress?.id,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(
                          Icons.location_on_outlined,
                          color: AppConstants.primaryColor,
                        ),
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
                      onChanged: _isSubmitting
                          ? null
                          : (id) {
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
                      onPressed: _isSubmitting
                          ? null
                          : () => _confirmDeleteAddress(selectedAddress),
                    ),
                  ],
                ],
              ),
              if (selectedAddress != null) ...[
                const SizedBox(height: 10),
                Text(
                  selectedAddress.fullText,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppConstants.textSecondary,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
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
          // 1. Teslimat Adresi Seçimi ve Kontrolü
          const Text(
            'Teslimat Adresi',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          _buildAddressSelectionCard(),
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
                        'Ara Toplam:',
                        style: TextStyle(color: AppConstants.textSecondary),
                      ),
                      Text(
                        '${_subtotal.toStringAsFixed(2)} TL',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Teslimat Ücreti:',
                        style: TextStyle(color: AppConstants.textSecondary),
                      ),
                      Text(
                        _deliveryFee == 0
                            ? 'Ücretsiz'
                            : '${_deliveryFee.toStringAsFixed(2)} TL',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: _deliveryFee == 0
                              ? AppConstants.primaryColor
                              : null,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 18),
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
                        '${_finalTotal.toStringAsFixed(2)} TL',
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
