import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/localization.dart';
import 'address_book.dart';

class DeliveryAddressScreen extends StatefulWidget {
  const DeliveryAddressScreen({super.key, this.initialAddress});

  final Address? initialAddress;

  @override
  State<DeliveryAddressScreen> createState() => _DeliveryAddressScreenState();
}

class _DeliveryAddressScreenState extends State<DeliveryAddressScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _neighborhoodController;
  late final TextEditingController _streetController;
  late final TextEditingController _buildingController;
  late final TextEditingController _apartmentController;
  late final TextEditingController _noteController;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: 'Ev');
    _neighborhoodController = TextEditingController();
    _streetController = TextEditingController();
    _buildingController = TextEditingController();
    _apartmentController = TextEditingController();
    _noteController = TextEditingController();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _neighborhoodController.dispose();
    _streetController.dispose();
    _buildingController.dispose();
    _apartmentController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _saveAddress() {
    if (!_formKey.currentState!.validate()) return;

    final address = [
      _neighborhoodController.text.trim(),
      _streetController.text.trim(),
      'Bina No: ${_buildingController.text.trim()}',
      if (_apartmentController.text.trim().isNotEmpty)
        'Daire: ${_apartmentController.text.trim()}',
      if (_noteController.text.trim().isNotEmpty) _noteController.text.trim(),
    ].join(', ');

    Navigator.pop(
      context,
      Address(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        title: _titleController.text.trim(),
        fullText: address,
      ),
    );
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
            // --- HARİTADAN ADRES EKLEME BUTONU ---
            ElevatedButton.icon(
              onPressed: () {
                // Uygulamanızdaki mevcut JWT Token değerini buraya geçebilirsiniz
                const String userToken = "Mevcut_User_JWT_Token";
                AddressBook.instance.openMapAndSaveAddress(context, userToken);
              },
              icon: const Icon(Icons.map, color: Colors.white),
              label: const Text(
                'Haritadan Konum Seç',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppConstants.primaryColor,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Row(
              children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8.0),
                  child: Text(
                    'VEYA ELLE GİRİN',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ),
                Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 16),

            Text(
              strings.addressPrompt,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Adres bilgilerini eksiksiz girerek teslimatını kolaylaştır.',
              style: TextStyle(color: AppConstants.textSecondary),
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Adres başlığı',
                hintText: 'Ev, İş, Diğer',
                prefixIcon: Icon(Icons.bookmark_border),
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Adres başlığı girin.'
                  : null,
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
                onPressed: _saveAddress,
                icon: const Icon(Icons.check),
                label: Text(strings.saveAddress),
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
}