import '../core/constants.dart';

class Campaign {
  const Campaign({
    required this.id,
    required this.title,
    required this.description,
    this.badgeText = '',
    this.imageUrl,
  });

  final int id;
  final String title;
  final String description;
  final String badgeText;
  final String? imageUrl;

  factory Campaign.fromJson(Map<String, dynamic> json) {
    final rawImage = json['image']?.toString().trim() ?? '';
    return Campaign(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      badgeText: json['badge_text']?.toString() ?? '',
      imageUrl: rawImage.isNotEmpty
          ? '${AppConstants.baseUrl}/static/uploads/$rawImage'
          : null,
    );
  }
}

