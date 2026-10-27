import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../core/local_storage.dart';
import '../core/session_manager.dart';
import '../models/address_model.dart';
import 'address_picker_screen.dart';

class Address {
  const Address({
    required this.id,
    required this.title,
    required this.fullText,
    this.city = '',
    this.district = '',
    this.latitude,
    this.longitude,
  });

  final String id;
  final String title;
  final String fullText;
  final String city;
  final String district;
  final double? latitude;
  final double? longitude;

  factory Address.fromJson(Map<String, dynamic> json) {
    return Address(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      fullText: json['full_text']?.toString() ?? '',
      city: json['city']?.toString() ?? '',
      district: json['district']?.toString() ?? '',
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'full_text': fullText,
    'city': city,
    'district': district,
    'latitude': latitude,
    'longitude': longitude,
  };

  factory Address.fromAddressModel(AddressModel model, {String? fallbackId}) {
    final hasLocationSuffix =
        model.district.isNotEmpty || model.city.isNotEmpty;
    final locationPart = [
      if (model.district.isNotEmpty) model.district,
      if (model.city.isNotEmpty && model.city != model.district) model.city,
    ].join('/');
    final formattedText =
        hasLocationSuffix && !model.fullAddress.contains(locationPart)
        ? '${model.fullAddress}, $locationPart'
        : model.fullAddress;

    return Address(
      id:
          (model.id?.toString() ??
          fallbackId ??
          DateTime.now().millisecondsSinceEpoch.toString()),
      title: model.title,
      fullText: formattedText,
      city: model.city,
      district: model.district,
      latitude: model.latitude,
      longitude: model.longitude,
    );
  }
}

class AddressBook extends ChangeNotifier {
  AddressBook._();

  static final AddressBook instance = AddressBook._();

  static const String _storageKey = 'saved_addresses';

  final List<Address> _addresses = [];
  String? _selectedAddressId;

  List<Address> get addresses => List.unmodifiable(_addresses);

  Address? get selectedAddress {
    for (final address in _addresses) {
      if (address.id == _selectedAddressId) return address;
    }
    return _addresses.isEmpty ? null : _addresses.first;
  }

  void restoreAddresses() {
    final raw = LocalStorage.instance.read(_storageKey);
    if (raw is Map) {
      final list = raw['addresses'];
      if (list is List) {
        _addresses.clear();
        for (final item in list) {
          if (item is Map) {
            final addr = Address.fromJson(Map<String, dynamic>.from(item));
            if (addr.id.isNotEmpty) {
              _addresses.add(addr);
            }
          }
        }
      }
      _selectedAddressId = raw['selected_id']?.toString();
    }
  }

  void _persistAddresses() {
    unawaited(
      LocalStorage.instance.write(_storageKey, {
        'addresses': _addresses.map((a) => a.toJson()).toList(),
        'selected_id': _selectedAddressId,
      }),
    );
  }

  void add(Address address) {
    _addresses.removeWhere((item) => item.id == address.id);
    _addresses.insert(0, address);
    _selectedAddressId = address.id;
    _persistAddresses();
    notifyListeners();
  }

  void select(String id) {
    if (_addresses.any((address) => address.id == id)) {
      _selectedAddressId = id;
      _persistAddresses();
      notifyListeners();
    }
  }

  Future<bool> deleteAddress(BuildContext context, String id) async {
    final index = _addresses.indexWhere((address) => address.id == id);
    if (index < 0) return false;

    final removed = _addresses.removeAt(index);
    if (_selectedAddressId == id) {
      _selectedAddressId = _addresses.isNotEmpty ? _addresses.first.id : null;
    }
    _persistAddresses();
    notifyListeners();

    final numericId = int.tryParse(id);
    if (SessionManager.instance.isAuthenticated && numericId != null) {
      try {
        final url = Uri.parse(
          '${AppConstants.baseUrl}/api/addresses/$numericId',
        );
        final response = await http
            .delete(
              url,
              headers: SessionManager.instance.authHeaders(isJson: false),
            )
            .timeout(const Duration(seconds: 10));

        if (response.statusCode != 200 && response.statusCode != 404) {
          // Sunucu silmeyi reddettiyse geri ekle
          _addresses.insert(index, removed);
          _selectedAddressId ??= removed.id;
          _persistAddresses();
          notifyListeners();
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Adres sunucudan silinemedi.'),
                backgroundColor: Colors.red,
              ),
            );
          }
          return false;
        }
      } catch (_) {
        // Çevrimdışıysa yerel silmeyi koru
      }
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('"${removed.title}" adresi silindi.'),
          backgroundColor: Colors.green,
        ),
      );
    }
    return true;
  }

  void clear() {
    _addresses.clear();
    _selectedAddressId = null;
    _persistAddresses();
    notifyListeners();
  }

  /// Giriş yapmış kullanıcının kayıtlı adreslerini sunucudan çeker.
  Future<void> fetchUserAddresses() async {
    if (!SessionManager.instance.isAuthenticated) return;

    final url = Uri.parse('${AppConstants.baseUrl}/api/addresses');
    try {
      final response = await http
          .get(url, headers: SessionManager.instance.authHeaders(isJson: false))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic> && decoded['data'] is List) {
          final List<dynamic> rawList = decoded['data'] as List<dynamic>;
          final loaded = rawList
              .whereType<Map<String, dynamic>>()
              .map(
                (json) => Address.fromAddressModel(AddressModel.fromJson(json)),
              )
              .toList();

          _addresses
            ..clear()
            ..addAll(loaded);
          if (_addresses.isNotEmpty &&
              !_addresses.any((a) => a.id == _selectedAddressId)) {
            _selectedAddressId = _addresses.first.id;
          }
          _persistAddresses();
          notifyListeners();
        }
      }
    } catch (_) {
      // Bağlantı hatası durumunda mevcut bellek içi adresleri koru
    }
  }

  /// Adresi oturum açıksa sunucuya ve yerel listeye, misafirse yerel listeye kaydeder.
  Future<Address?> saveAddressModel(
    BuildContext context,
    AddressModel selectedAddress, {
    String? jwtToken,
  }) async {
    final effectiveToken =
        (jwtToken != null &&
            jwtToken.isNotEmpty &&
            jwtToken != 'Mevcut_User_JWT_Token')
        ? jwtToken
        : SessionManager.instance.token;

    // Misafir kullanıcıysa yerel olarak kaydet
    if (effectiveToken == null || effectiveToken.isEmpty) {
      final localAddr = Address.fromAddressModel(selectedAddress);
      add(localAddr);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Adres kaydedildi.'),
            backgroundColor: Colors.green,
          ),
        );
      }
      return localAddr;
    }

    final url = Uri.parse('${AppConstants.baseUrl}/api/addresses');
    try {
      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $effectiveToken',
            },
            body: jsonEncode(selectedAddress.toJson()),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 201) {
        String? serverId;
        try {
          final body = jsonDecode(response.body);
          if (body is Map && body['address_id'] != null) {
            serverId = body['address_id'].toString();
          }
        } catch (_) {}

        final newAddr = Address.fromAddressModel(
          selectedAddress,
          fallbackId: serverId,
        );
        add(newAddr);

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Adres başarıyla kaydedildi!'),
              backgroundColor: Colors.green,
            ),
          );
        }
        return newAddr;
      } else {
        String errorMsg = 'Adres kaydedilemedi (${response.statusCode}).';
        try {
          final body = jsonDecode(response.body);
          if (body is Map && body['error'] != null) {
            errorMsg = body['error'].toString();
          } else if (body is Map && body['message'] != null) {
            errorMsg = body['message'].toString();
          }
        } catch (_) {}

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(errorMsg), backgroundColor: Colors.red),
          );
        }
        return null;
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sunucuya bağlanılamadı: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return null;
    }
  }

  /// Haritayı açar, seçilen adresi alır ve Flask API'ye (veya misafirse yerele) kaydeder.
  Future<Address?> openMapAndSaveAddress(
    BuildContext context, [
    String? jwtToken,
  ]) async {
    final AddressModel? selectedAddress = await Navigator.push<AddressModel>(
      context,
      MaterialPageRoute(builder: (context) => const AddressPickerScreen()),
    );

    if (selectedAddress != null && context.mounted) {
      return saveAddressModel(context, selectedAddress, jwtToken: jwtToken);
    }
    return null;
  }
}
