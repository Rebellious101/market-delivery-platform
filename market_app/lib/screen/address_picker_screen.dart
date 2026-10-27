import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../core/constants.dart';
import '../models/address_model.dart';

class AddressPickerScreen extends StatefulWidget {
  const AddressPickerScreen({super.key});

  @override
  State<AddressPickerScreen> createState() => _AddressPickerScreenState();
}

class _AddressPickerScreenState extends State<AddressPickerScreen>
    with WidgetsBindingObserver {
  LatLng? _userLocation;
  final MapController _mapController = MapController();
  StreamSubscription<ServiceStatus>? _serviceStatusSub;
  bool _waitingForLocationService = false;

  final _geocoding = Geocoding();
  final _titleController = TextEditingController(text: 'Ev');
  final _addressDetailController = TextEditingController();
  final _districtController = TextEditingController(text: 'Gazimağusa');

  bool _isLoadingAddress = false;
  bool _isLocatingUser = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _serviceStatusSub = Geolocator.getServiceStatusStream().listen((status) {
      if (status == ServiceStatus.enabled && mounted) {
        _waitingForLocationService = false;
        _goToCurrentUserLocation(askToEnableIfOff: false);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _goToCurrentUserLocation(askToEnableIfOff: true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForLocationService) {
      _waitingForLocationService = false;
      _goToCurrentUserLocation(askToEnableIfOff: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _serviceStatusSub?.cancel();
    _mapController.dispose();
    _titleController.dispose();
    _addressDetailController.dispose();
    _districtController.dispose();
    super.dispose();
  }

  Future<void> _goToCurrentUserLocation({
    required bool askToEnableIfOff,
  }) async {
    if (_isLocatingUser) return;
    setState(() => _isLocatingUser = true);

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (askToEnableIfOff && mounted) {
          final shouldOpen = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('Konum Servisi Kapalı'),
              content: const Text(
                'Kendi konumunuzu görmek için telefonunuzun konum (GPS) özelliğini açmanız gerekmektedir. Şimdi açmak ister misiniz?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('İptal'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Konumu Aç'),
                ),
              ],
            ),
          );

          if (shouldOpen == true) {
            _waitingForLocationService = true;
            await Geolocator.openLocationSettings();
          }
        }
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Konum izni reddedildi.')),
            );
          }
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Konum izni kalıcı olarak reddedilmiş. Uygulama ayarlarından izin verin.',
              ),
            ),
          );
        }
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      final userLatLng = LatLng(position.latitude, position.longitude);
      if (!mounted) return;

      final hadMap = _userLocation != null;
      setState(() {
        _userLocation = userLatLng;
      });

      if (hadMap) {
        _mapController.move(userLatLng, 16);
      }
      await _decodeAddress(userLatLng);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mevcut konum alınamadı, lütfen tekrar deneyin.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLocatingUser = false);
      }
    }
  }

  bool _isRealAddressText(String? text) {
    if (text == null) return false;
    final value = text.trim();
    if (value.length < 2) return false;
    if (value.contains('+')) return false;
    if (RegExp(r'^[0-9\s.,\-/#]+$').hasMatch(value)) return false;
    final lower = value.toLowerCase();
    if (lower == 'unnamed road' || lower == 'isimsiz yol') return false;
    return true;
  }

  String _firstValidText(Iterable<dynamic> candidates) {
    for (final candidate in candidates) {
      final str = candidate?.toString().trim();
      if (_isRealAddressText(str)) {
        return str!;
      }
    }
    return '';
  }

  Future<void> _decodeAddress(LatLng pos) async {
    if (!mounted) return;
    setState(() => _isLoadingAddress = true);

    String neighborhood = '';
    String street = '';
    String houseNo = '';

    // 1. Önce OpenStreetMap Nominatim servisinden gerçek sokak/cadde ve mahalle adını al
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'format': 'jsonv2',
        'lat': pos.latitude.toString(),
        'lon': pos.longitude.toString(),
        'zoom': '18',
        'addressdetails': '1',
        'accept-language': 'tr',
      });
      final response = await http
          .get(uri, headers: {'User-Agent': 'PrestijMarketApp/1.0'})
          .timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic> && data['address'] is Map) {
          final addr = data['address'] as Map<String, dynamic>;
          neighborhood = _firstValidText([
            addr['suburb'],
            addr['neighbourhood'],
            addr['quarter'],
            addr['residential'],
            addr['city_district'],
            addr['village'],
            addr['hamlet'],
          ]);
          street = _firstValidText([
            addr['road'],
            addr['pedestrian'],
            addr['street'],
            addr['living_street'],
            addr['footway'],
            addr['square'],
            addr['place'],
            addr['amenity'],
            addr['building'],
            addr['shop'],
            addr['tourism'],
            addr['leisure'],
            data['name'],
          ]);
          houseNo = (addr['house_number'] ?? '').toString().trim();
        }
      }
    } catch (_) {}

    // 2. Eksik kalan alan varsa cihaz Geocoder kayıtlarını tara (Plus Code ve sayısal kodları filtrele)
    if (neighborhood.isEmpty || street.isEmpty) {
      try {
        final List<Placemark> placemarks = await _geocoding
            .placemarkFromCoordinates(pos.latitude, pos.longitude);
        for (final place in placemarks) {
          if (neighborhood.isEmpty) {
            neighborhood = _firstValidText([place.subLocality, place.locality]);
          }
          if (street.isEmpty) {
            street = _firstValidText([
              place.thoroughfare,
              place.street,
              place.name,
            ]);
          }
          if (houseNo.isEmpty) {
            final sub = (place.subThoroughfare ?? '').trim();
            if (sub.isNotEmpty && !sub.contains('+')) {
              houseNo = sub;
            }
          }
        }
      } catch (_) {}
    }

    if (mounted) {
      final detailParts = <String>[
        if (neighborhood.isNotEmpty) neighborhood,
        if (street.isNotEmpty && street != neighborhood) street,
        if (houseNo.isNotEmpty) 'No: $houseNo',
      ];
      setState(() {
        if (detailParts.isNotEmpty) {
          _addressDetailController.text = detailParts.join(', ');
        }
        _isLoadingAddress = false;
      });
    }
  }

  void _onSaveAddress() {
    final title = _titleController.text.trim();
    final district = _districtController.text.trim();
    final fullAddress = _addressDetailController.text.trim();

    if (title.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Adres başlığı en az 2 karakter olmalıdır.'),
        ),
      );
      return;
    }
    if (district.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Lütfen İlçe alanını eksiksiz doldurun.')),
      );
      return;
    }
    if (fullAddress.length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Açık adres en az 10 karakter olmalıdır (Mahalle, Sokak, No).',
          ),
        ),
      );
      return;
    }

    final newAddress = AddressModel(
      title: title,
      fullAddress: fullAddress,
      city: district,
      district: district,
      latitude: _userLocation?.latitude,
      longitude: _userLocation?.longitude,
    );

    Navigator.pop(context, newAddress);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mevcut Konumum'),
        backgroundColor: AppConstants.primaryColor,
        foregroundColor: AppConstants.textLight,
      ),
      body: Column(
        children: [
          Expanded(
            flex: 5,
            child: _userLocation == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.location_searching,
                            size: 48,
                            color: AppConstants.primaryColor,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Konumunuzu görüntülemek için konum servisini açın.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            onPressed: _isLocatingUser
                                ? null
                                : () => _goToCurrentUserLocation(
                                    askToEnableIfOff: true,
                                  ),
                            icon: const Icon(Icons.my_location),
                            label: const Text('Konumu Aç ve Göster'),
                          ),
                        ],
                      ),
                    ),
                  )
                : Stack(
                    children: [
                      FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: _userLocation!,
                          initialZoom: 16,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.prestij.market_app',
                          ),
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: _userLocation!,
                                width: 56,
                                height: 56,
                                child: const Icon(
                                  Icons.my_location,
                                  color: AppConstants.primaryColor,
                                  size: 38,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      Positioned(
                        bottom: 16,
                        right: 16,
                        child: FloatingActionButton.small(
                          heroTag: 'gps_locate_btn',
                          backgroundColor: Colors.white,
                          foregroundColor: AppConstants.primaryColor,
                          tooltip: 'Konumumu Yenile',
                          onPressed: _isLocatingUser
                              ? null
                              : () => _goToCurrentUserLocation(
                                  askToEnableIfOff: true,
                                ),
                          child: _isLocatingUser
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.my_location),
                        ),
                      ),
                      if (_isLoadingAddress)
                        const Positioned(
                          top: 16,
                          right: 16,
                          child: CircularProgressIndicator(),
                        ),
                    ],
                  ),
          ),
          Expanded(
            flex: 6,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: 'Adres Başlığı (Örn: Ev, İş)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _districtController,
                    decoration: const InputDecoration(
                      labelText: 'İlçe',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _addressDetailController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Açık Adres (Sokak, Bina No, Daire)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _onSaveAddress,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppConstants.primaryColor,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text(
                      'ADRESİ KAYDET',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
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
