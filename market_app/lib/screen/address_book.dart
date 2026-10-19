import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import '../models/address_model.dart';
import 'address_picker_screen.dart';

class Address {
  const Address({
    required this.id,
    required this.title,
    required this.fullText,
  });

  final String id;
  final String title;
  final String fullText;
}

class AddressBook extends ChangeNotifier {
  AddressBook._();

  static final AddressBook instance = AddressBook._();

  final List<Address> _addresses = [];
  String? _selectedAddressId;

  List<Address> get addresses => List.unmodifiable(_addresses);
  Address? get selectedAddress {
    for (final address in _addresses) {
      if (address.id == _selectedAddressId) return address;
    }
    return _addresses.isEmpty ? null : _addresses.first;
  }

  void add(Address address) {
    _addresses.removeWhere((item) => item.id == address.id);
    _addresses.add(address);
    _selectedAddressId = address.id;
    notifyListeners();
  }

  void select(String id) {
    if (_addresses.any((address) => address.id == id)) {
      _selectedAddressId = id;
      notifyListeners();
    }
  }

  /// Haritayı açar, seçilen adresi alır ve Flask API'ye kaydeder.
  Future<void> openMapAndSaveAddress(BuildContext context, String jwtToken) async {
    // 1. Harita ekranını aç ve kullanıcının seçtiği adresi bekle
    final AddressModel? selectedAddress = await Navigator.push<AddressModel>(
      context,
      MaterialPageRoute(
        builder: (context) => const AddressPickerScreen(),
      ),
    );

    // 2. Kullanıcı adres seçip kaydettiyse Flask API'ye Gönder
    if (selectedAddress != null) {
      final url = Uri.parse('${AppConstants.baseUrl}/api/addresses');

      try {
        final response = await http.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $jwtToken',
          },
          body: jsonEncode(selectedAddress.toJson()),
        );

        if (response.statusCode == 201) {
          // API'ye başarılı kaydedildiyse yerel listeye de ekle
          final newAddr = Address(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            title: selectedAddress.title,
            fullText: '${selectedAddress.fullAddress}, ${selectedAddress.district}/${selectedAddress.city}',
          );
          add(newAddr);

          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('✅ Adres başarıyla kaydedildi!'),
                backgroundColor: Colors.green,
              ),
            );
          }
        } else {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('❌ Adres kaydedilemedi: ${response.body}'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('❌ Sunucuya bağlanılamadı: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }
}