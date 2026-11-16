import '../core/age_verification.dart';

class Subcategory {
  final int id;
  final int categoryId;
  final String name;

  const Subcategory({
    required this.id,
    required this.categoryId,
    required this.name,
  });

  factory Subcategory.fromJson(Map<String, dynamic> json, {int defaultCategoryId = 0}) {
    return Subcategory(
      id: (json['id'] as num?)?.toInt() ?? 0,
      categoryId: (json['category_id'] as num?)?.toInt() ?? defaultCategoryId,
      name: json['name']?.toString() ?? '',
    );
  }
}

class Category {
  final int id;
  final String name;
  final List<Subcategory> subcategories;

  const Category({
    required this.id,
    required this.name,
    this.subcategories = const [],
  });

  bool get isAlcohol => AgeVerification.isAlcoholText(name);
  bool get isTobacco => AgeVerification.isTobaccoText(name);
  bool get is18Plus => isAlcohol || isTobacco;

  static List<Subcategory> defaultSubcategoriesFor(int categoryId, String categoryName) {
    final lower = categoryName.toLowerCase();
    List<String> names;
    if (AgeVerification.isAlcoholText(lower)) {
      names = const ['Bira', 'Şarap', 'Rakı', 'Viski & Votka', 'Cin & Likör'];
    } else if (AgeVerification.isTobaccoText(lower)) {
      names = const ['Sigara', 'Sarma Tütün', 'Puro & Çakmak'];
    } else if (lower.contains('içecek') || lower.contains('icecek')) {
      names = const [
        'Gazlı İçecek',
        'Su & Maden Suyu',
        'Meyve Suyu',
        'Soğuk Çay & Kahve',
        'Enerji İçeceği',
      ];
    } else if (lower.contains('atıştırmalık') || lower.contains('atistirmalik')) {
      names = const [
        'Cips & Kraker',
        'Çikolata & Gofret',
        'Bisküvi & Kek',
        'Kuruyemiş',
        'Şekerleme & Sakız',
      ];
    } else if (lower.contains('temel')) {
      names = const [
        'Ekmek & Unlu Mamüller',
        'Makarna & Bakliyat',
        'Sıvı Yağ',
        'Un, Şeker & Tuz',
        'Konserve & Salça',
      ];
    } else if (lower.contains('süt') || lower.contains('sut')) {
      names = const ['Süt', 'Yoğurt & Ayran', 'Peynir', 'Tereyağı & Kaymak'];
    } else if (lower.contains('temizlik')) {
      names = const [
        'Çamaşır Yıkama',
        'Bulaşık Yıkama',
        'Yüzey & Genel Temizlik',
        'Kağıt Ürünleri',
      ];
    } else if (lower.contains('kahvaltı') || lower.contains('kahvalti')) {
      names = const [
        'Zeytin',
        'Reçel, Bal & Krem Çikolata',
        'Yumurta',
        'Şarküteri & Sucuk',
        'Mısır Gevreği & Yulaf',
      ];
    } else if (lower.contains('kişisel') || lower.contains('kisisel')) {
      names = const [
        'Şampuan & Duş Jeli',
        'Ağız & Diş Bakımı',
        'Deodorant & Parfüm',
        'Cilt & El Bakımı',
        'Hijyenik Ped & Pamuk',
      ];
    } else {
      names = const ['Genel', 'Popüler', 'Avantajlı Paket'];
    }

    return List<Subcategory>.generate(
      names.length,
      (i) => Subcategory(
        id: -(categoryId * 100 + i + 1),
        categoryId: categoryId,
        name: names[i],
      ),
    );
  }

  factory Category.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as num?)?.toInt() ?? 0;
    final name = json['name']?.toString() ?? '';
    final rawSubs = json['subcategories'] as List<dynamic>?;
    final parsedSubs = rawSubs
            ?.map((item) => Subcategory.fromJson(
                  item as Map<String, dynamic>,
                  defaultCategoryId: id,
                ))
            .where((sub) => sub.name.isNotEmpty)
            .toList() ??
        const <Subcategory>[];

    return Category(
      id: id,
      name: name,
      subcategories: parsedSubs.isNotEmpty
          ? parsedSubs
          : defaultSubcategoriesFor(id, name),
    );
  }
}
