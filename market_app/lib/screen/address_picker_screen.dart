import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geocoding/geocoding.dart';
import '../models/address_model.dart';

class AddressPickerScreen extends StatefulWidget {
  const AddressPickerScreen({super.key});

  @override
  State<AddressPickerScreen> createState() => _AddressPickerScreenState();
}

class _AddressPickerScreenState extends State<AddressPickerScreen> {
  LatLng _selectedLocation = const LatLng(41.0082, 28.9784); // Varsayılan: İstanbul

  final _geocoding = Geocoding();
  final _titleController = TextEditingController(text: 'Ev');
  final _addressDetailController = TextEditingController();
  final _cityController = TextEditingController();
  final _districtController = TextEditingController();

  bool _isLoadingAddress = false;

  Future<void> _decodeAddress(LatLng pos) async {
    setState(() => _isLoadingAddress = true);
    try {
      List<Placemark> placemarks = await _geocoding.placemarkFromCoordinates(
        pos.latitude,
        pos.longitude,
      );

      if (placemarks.isNotEmpty) {
        Placemark place = placemarks.first;
        setState(() {
          _cityController.text = place.administrativeArea ?? '';
          _districtController.text = place.subAdministrativeArea ?? place.locality ?? '';
          _addressDetailController.text = 
              '${place.street ?? ''} ${place.thoroughfare ?? ''} ${place.subThoroughfare ?? ''}'.trim();
        });
      }
    } catch (_) {
      // Çözümleme başarısız olursa manuel girişe izin verilir
    } finally {
      setState(() => _isLoadingAddress = false);
    }
  }

  void _onSaveAddress() {
    if (_titleController.text.trim().isEmpty ||
        _addressDetailController.text.trim().isEmpty ||
        _cityController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Lütfen tüm zorunlu alanları doldurun.')),
      );
      return;
    }

    final newAddress = AddressModel(
      title: _titleController.text.trim(),
      fullAddress: _addressDetailController.text.trim(),
      city: _cityController.text.trim(),
      district: _districtController.text.trim(),
      latitude: _selectedLocation.latitude,
      longitude: _selectedLocation.longitude,
    );

    Navigator.pop(context, newAddress);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Haritadan Adres Seç'),
        backgroundColor: const Color(0xFF2E7D32),
      ),
      body: Column(
        children: [
          Expanded(
            flex: 5,
            child: Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: _selectedLocation,
                    zoom: 15,
                  ),
                  onCameraMove: (position) {
                    _selectedLocation = position.target;
                  },
                  onCameraIdle: () {
                    _decodeAddress(_selectedLocation);
                  },
                ),
                const Center(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 35.0),
                    child: Icon(
                      Icons.location_on,
                      size: 45,
                      color: Colors.redAccent,
                    ),
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
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _cityController,
                          decoration: const InputDecoration(
                            labelText: 'İl',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _districtController,
                          decoration: const InputDecoration(
                            labelText: 'İlçe',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
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
                      backgroundColor: const Color(0xFF2E7D32),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text(
                      'ADRESİ SEÇ VE KAYDET',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
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