class AddressModel {
  final int? id;
  final String title;
  final String fullAddress;
  final String city;
  final String district;
  final double? latitude;
  final double? longitude;

  AddressModel({
    this.id,
    required this.title,
    required this.fullAddress,
    required this.city,
    required this.district,
    this.latitude,
    this.longitude,
  });

  factory AddressModel.fromJson(Map<String, dynamic> json) {
    return AddressModel(
      id: json['id'],
      title: json['title'] ?? '',
      fullAddress: json['full_address'] ?? '',
      city: json['city'] ?? '',
      district: json['district'] ?? '',
      latitude: json['latitude'] != null ? (json['latitude'] as num).toDouble() : null,
      longitude: json['longitude'] != null ? (json['longitude'] as num).toDouble() : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'full_address': fullAddress,
      'city': city,
      'district': district,
      'latitude': latitude,
      'longitude': longitude,
    };
  }
}