import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../core/constants.dart';
import '../core/localization.dart';
import '../models/address_model.dart';
import 'address_book.dart';

class DeliveryAddressScreen extends StatefulWidget {
  const DeliveryAddressScreen({super.key, this.initialAddress});

  final Address? initialAddress;

  @override
  State<DeliveryAddressScreen> createState() => _DeliveryAddressScreenState();
}

class _DeliveryAddressScreenState extends State<DeliveryAddressScreen>
    with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();
  final MapController _mapController = MapController();
  final _geocoding = Geocoding();

  late final TextEditingController _titleController;
  late final TextEditingController _districtController;
  late final TextEditingController _neighborhoodController;
  late final TextEditingController _streetController;
  late final TextEditingController _buildingController;
  late final TextEditingController _apartmentController;
  late final TextEditingController _noteController;

  bool _isSaving = false;
  bool _isLocating = false;
  bool _waitingForLocationService = false;
  LatLng? _userLocation;
  StreamSubscription<ServiceStatus>? _serviceStatusSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final initial = widget.initialAddress;
    _titleController = TextEditingController(text: initial?.title ?? 'Ev');
    _districtController = TextEditingController(
      text: (initial?.district.isNotEmpty ?? false)
          ? initial!.district
          : 'Gazimağusa',
    );
    _neighborhoodController = TextEditingController();
    _streetController = TextEditingController();
    _buildingController = TextEditingController();
    _apartmentController = TextEditingController();
    _noteController = TextEditingController();

    if (initial?.latitude != null && initial?.longitude != null) {
      _userLocation = LatLng(initial!.latitude!, initial.longitude!);
    }

    // Kullanıcı bildirim panelinden veya ayarlardan konumu açtığında otomatik algıla
    _serviceStatusSub = Geolocator.getServiceStatusStream().listen((status) {
      if (status == ServiceStatus.enabled && mounted) {
        _waitingForLocationService = false;
        _fetchAndShowUserLocation(askToEnableIfOff: false);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waitingForLocationService) {
      _waitingForLocationService = false;
      _fetchAndShowUserLocation(askToEnableIfOff: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _serviceStatusSub?.cancel();
    _mapController.dispose();
    _titleController.dispose();
    _districtController.dispose();
    _neighborhoodController.dispose();
    _streetController.dispose();
    _buildingController.dispose();
    _apartmentController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _onLocationCardTapped() async {
    await _fetchAndShowUserLocation(askToEnableIfOff: true);
  }

  Future<void> _fetchAndShowUserLocation({
    required bool askToEnableIfOff,
  }) async {
    if (_isLocating) return;
    setState(() => _isLocating = true);

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
              const SnackBar(
                content: Text(
                  'Konumunuzu göstermek için konum izni gereklidir.',
                ),
              ),
            );
          }
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        if (mounted) {
          final openSettings = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('Konum İzni Gerekli'),
              content: const Text(
                'Konum izni kalıcı olarak kapatılmış. Uygulama ayarlarından konum iznini açmak ister misiniz?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('İptal'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Ayarları Aç'),
                ),
              ],
            ),
          );
          if (openSettings == true) {
            _waitingForLocationService = true;
            await Geolocator.openAppSettings();
          }
        }
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      final currentLatLng = LatLng(position.latitude, position.longitude);
      if (!mounted) return;

      final hadMapAlready = _userLocation != null;
      setState(() {
        _userLocation = currentLatLng;
      });

      if (hadMapAlready) {
        _mapController.move(currentLatLng, 16);
      }

      await _fillAddressFromCoordinates(currentLatLng);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Konum alınamadı, lütfen tekrar deneyin.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLocating = false);
      }
    }
  }

  /// Plus Code (örn: 4WG8+7X), posta kodu veya salt sayısal koordinat dizelerini eler.
  bool _isRealAddressText(String? text) {
    if (text == null) return false;
    final value = text.trim();
    if (value.length < 2) return false;
    // Plus Code kontrolü ('+' içeriyorsa)
    if (value.contains('+')) return false;
    // Sadece sayı, nokta, virgül, tire veya boşluktan oluşuyorsa (örn: 99450, 35.125)
    if (RegExp(r'^[0-9\s.,\-/#]+$').hasMatch(value)) return false;
    // "Unnamed Road" gibi anlamsız ifadeleri ele
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

  Future<void> _fillAddressFromCoordinates(LatLng pos) async {
    String neighborhood = '';
    String street = '';
    String buildingNo = '';

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

          final rawHouseNumber = (addr['house_number'] ?? '').toString().trim();
          if (rawHouseNumber.isNotEmpty) {
            buildingNo = rawHouseNumber;
          }

          // Eğer hala sokak boşsa display_name içindeki ilk anlamlı metin parçasını al
          if (street.isEmpty && data['display_name'] != null) {
            final parts = data['display_name']
                .toString()
                .split(',')
                .map((s) => s.trim())
                .where(_isRealAddressText)
                .toList();
            for (final part in parts) {
              if (part != neighborhood &&
                  !part.toLowerCase().contains('gazimağusa') &&
                  !part.toLowerCase().contains('mağusa') &&
                  !part.toLowerCase().contains('kıbrıs')) {
                street = part;
                break;
              }
            }
          }
        }
      }
    } catch (_) {}

    // 2. Eksik kalan alan varsa cihazın yerel Geocoder sonuçlarındaki tüm kayıtları tara (Plus Code'ları atla)
    if (neighborhood.isEmpty || street.isEmpty) {
      try {
        final placemarks = await _geocoding.placemarkFromCoordinates(
          pos.latitude,
          pos.longitude,
        );
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
          if (buildingNo.isEmpty) {
            final subThoroughfare = (place.subThoroughfare ?? '').trim();
            if (subThoroughfare.isNotEmpty && !subThoroughfare.contains('+')) {
              buildingNo = subThoroughfare;
            }
          }
        }
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      if (neighborhood.isNotEmpty) {
        _neighborhoodController.text = neighborhood;
      }
      if (street.isNotEmpty) {
        _streetController.text = street;
      }
      if (buildingNo.isNotEmpty && _buildingController.text.isEmpty) {
        _buildingController.text = buildingNo;
      }
    });
  }

  Future<void> _saveAddress() async {
    if (!_formKey.currentState!.validate() || _isSaving) return;

    setState(() => _isSaving = true);

    final fullAddress = [
      _neighborhoodController.text.trim(),
      _streetController.text.trim(),
      'Bina No: ${_buildingController.text.trim()}',
      if (_apartmentController.text.trim().isNotEmpty)
        'Daire: ${_apartmentController.text.trim()}',
      if (_noteController.text.trim().isNotEmpty) _noteController.text.trim(),
    ].join(', ');

    final district = _districtController.text.trim();
    final model = AddressModel(
      title: _titleController.text.trim(),
      fullAddress: fullAddress,
      city: district,
      district: district,
      latitude: _userLocation?.latitude,
      longitude: _userLocation?.longitude,
    );

    final savedAddress = await AddressBook.instance.saveAddressModel(
      context,
      model,
    );

    if (!mounted) return;
    setState(() => _isSaving = false);

    if (savedAddress != null) {
      Navigator.pop(context, savedAddress);
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(strings.addressPageTitle),
        backgroundColor: AppConstants.primaryColor,
        foregroundColor: AppConstants.textLight,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          children: [
            _buildSavedAddressesSection(),
            _buildUserLocationSection(),
            const SizedBox(height: 20),
            Text(
              strings.addressPrompt,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              'Adres bilgilerini eksiksiz girerek teslimatını kolaylaştır.',
              style: TextStyle(color: AppConstants.textSecondary),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Adres başlığı',
                hintText: 'Ev, İş, Diğer',
                prefixIcon: Icon(Icons.bookmark_border),
              ),
              validator: (value) => value == null || value.trim().length < 2
                  ? 'En az 2 karakterli bir adres başlığı girin.'
                  : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _districtController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'İlçe',
                prefixIcon: Icon(Icons.place_outlined),
              ),
              validator: _requiredMin2,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _neighborhoodController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Mahalle',
                prefixIcon: Icon(Icons.location_city_outlined),
              ),
              validator: _required,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _streetController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Sokak / Cadde',
                prefixIcon: Icon(Icons.signpost_outlined),
              ),
              validator: _required,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _buildingController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Bina no',
                      prefixIcon: Icon(Icons.home_work_outlined),
                    ),
                    validator: _required,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _apartmentController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Daire no'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _noteController,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Tarif / teslimat notu (isteğe bağlı)',
                hintText: 'Güvenlik, kat veya kapı bilgisi',
                prefixIcon: Icon(Icons.notes_outlined),
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              height: AppConstants.buttonHeight,
              child: FilledButton.icon(
                onPressed: _isSaving ? null : _saveAddress,
                icon: _isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check),
                label: Text(strings.saveAddress),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSavedAddressesSection() {
    return ListenableBuilder(
      listenable: AddressBook.instance,
      builder: (context, _) {
        final addresses = AddressBook.instance.addresses;
        final selectedId = AddressBook.instance.selectedAddress?.id;
        if (addresses.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Kayıtlı Adreslerim',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  for (int i = 0; i < addresses.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    ListTile(
                      onTap: () {
                        AddressBook.instance.select(addresses[i].id);
                        Navigator.pop(context, addresses[i]);
                      },
                      leading: Icon(
                        addresses[i].id == selectedId
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: AppConstants.primaryColor,
                      ),
                      title: Text(
                        addresses[i].title,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        addresses[i].fullText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.delete_outline,
                          color: AppConstants.errorColor,
                        ),
                        tooltip: 'Adresi sil',
                        onPressed: () => _confirmDeleteAddress(addresses[i]),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
        );
      },
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

  Widget _buildUserLocationSection() {
    if (_userLocation == null) {
      return InkWell(
        onTap: _isLocating ? null : _onLocationCardTapped,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          decoration: BoxDecoration(
            color: AppConstants.primaryColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: AppConstants.primaryColor.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                  color: AppConstants.primaryColor,
                  shape: BoxShape.circle,
                ),
                child: _isLocating
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(
                        Icons.my_location,
                        color: Colors.white,
                        size: 22,
                      ),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Mevcut Konumumu Kullan',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: AppConstants.primaryColor,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Dokunarak konumu açın ve bulunduğunuz yeri görün',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppConstants.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: AppConstants.primaryColor),
            ],
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 210,
        child: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _userLocation!,
                initialZoom: 16,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
                ),
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
                        size: 36,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            Positioned(
              top: 10,
              left: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.check_circle,
                      color: AppConstants.primaryColor,
                      size: 16,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'Mevcut Konumunuz',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              bottom: 10,
              right: 10,
              child: FloatingActionButton.small(
                heroTag: 'refresh_user_location',
                backgroundColor: Colors.white,
                foregroundColor: AppConstants.primaryColor,
                tooltip: 'Konumumu Yenile',
                onPressed: _isLocating ? null : _onLocationCardTapped,
                child: _isLocating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.my_location),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _required(String? value) {
    return value == null || value.trim().isEmpty ? 'Bu alan zorunludur.' : null;
  }

  String? _requiredMin2(String? value) {
    return value == null || value.trim().length < 2
        ? 'En az 2 karakter girin.'
        : null;
  }
}
