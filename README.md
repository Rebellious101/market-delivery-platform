# Prestij Market

**Prestij Market**, çevrimiçi market siparişi ve hızlı teslimat için geliştirilmiş tam kapsamlı bir **Flutter** mobil uygulaması (Android & iOS) ve **Flask / MySQL** tabanlı yönetim/API sunucusudur.

---

## Proje Yapısı

```text
prestij_market/
├── market_app/                  # Flutter mobil uygulaması (Android & iOS)
│   ├── lib/
│   │   ├── core/                # Sabitler, yerelleştirme (TR/EN), oturum, +18 yaş doğrulama
│   │   ├── models/              # Kategori, alt kategori, ürün ve sipariş modelleri
│   │   └── screen/              # Giriş, ürün detay, sepet, adres/harita ve sipariş ekranları
│   ├── android/                 # Android yapılandırması (com.prestijmarket.app)
│   └── ios/                     # iOS yapılandırması (com.prestijmarket.app)
├── Backend/                     # Flask REST API, Admin Paneli ve Kurye Paneli
│   ├── app.py                   # Ana uygulama, MySQL şeması ve API uç noktaları
│   ├── templates/               # Admin ve Kurye web arayüzleri
│   └── static/                  # Yüklenen ürün görselleri ve CSS
└── .github/workflows/
    └── ios-release.yml          # GitHub Actions macOS iOS TestFlight derleme ve yükleme hattı
```

---

## Temel Özellikler

### Mobil Uygulama (`market_app`)
- **Telefon Numarası ile Giriş:** Firebase Phone Authentication (6 haneli SMS OTP doğrulama) ve misafir olarak gezinme desteği.
- **Kategoriler & Alt Kategoriler:** Ana kategorilere tıklandığında üstte yatay kaydırmalı kategori ve alt kategori filtre çubuğu.
- **Akıllı Arama:** Türkçe karakter duyarsız (`İ/I/ı/i`, `Ş/ş`, `Ç/ç`, `Ö/ö`, `Ü/ü`, `Ğ/ğ`) ürün, kategori ve alt kategori araması.
- **Sepet & Sipariş Kuralları:**
  - Minimum sepet tutarı kontrolü (sigara/tütün ürünleri muaf tutulur).
  - Bir siparişte en fazla **2 paket** sigara/tütün kısıtlaması (istemci ve sunucu tarafında).
  - **Alkol & Sigara/Tütün** kategorilerine girişte **+18 yaş onay penceresi**.
- **Harita Tabanlı Teslimat Adresi:** OpenStreetMap (`flutter_map`) ve `geolocator` ile haritadan konum seçme ve kayıtlı adres yönetimi.
- **Favoriler, Ürün Talebi & Hesap Yönetimi:** Favori ürünler, Profil sekmesinde 30 karakter sınırlı ürün talebi gönderme ve güvenli hesap silme (`DELETE /api/auth/account`).
- **Çoklu Dil Desteği:** Türkçe (`TR`) ve İngilizce (`EN`).

### Backend, Admin & Kurye Paneli (`Backend`)
- **REST API:** Ürünler, haftanın indirimleri, kategoriler/alt kategoriler, kampanyalar, sipariş oluşturma (yarış durumuna karşı atomik stok düşümü), adres yönetimi ve ürün talepleri.
- **Admin Paneli (`/admin`):** Ürün, kategori/alt kategori, kampanya, haftanın indirimleri, sipariş takibi, minimum sepet tutarı ve müşteri ürün talepleri yönetimi.
- **Kurye Paneli (`/kurye`):** Aktif siparişlerin takibi, Google Maps yol tarifi ve teslimat tamamlama.

---

## Kurulum

### 1. Backend (Flask + MySQL)
```bash
cd Backend
python -m venv venv
# Windows: venv\Scripts\activate | Linux/macOS: source venv/bin/activate
pip install -r requirements.txt
```

`Backend/.env` dosyasında veritabanı ve uygulama ortam değişkenlerini tanımlayın (`DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `JWT_SECRET_KEY`, `ADMIN_USERNAME`, `ADMIN_PASSWORD`), ardından sunucuyu başlatın:

```bash
python app.py
```

### 2. Mobil Uygulama (Flutter)
```bash
cd market_app
flutter pub get
flutter analyze
flutter run
```

#### Android Release (`.aab`) Derleme
```bash
cd market_app
flutter build appbundle --release
```

#### iOS TestFlight Derleme (GitHub Actions)
`.github/workflows/ios-release.yml` dosyası üzerinden **Actions > iOS Release (TestFlight) > Run workflow** ile `macos-15-intel` üzerinde otomatik olarak `.xcarchive` ve imzalı `.ipa` oluşturularak App Store Connect (TestFlight)'e yüklenir.

---

## Güvenlik Notu
- İmzalama anahtarları (`*.jks`, `key.properties`, `*.p8`, `*.p12`) ve sunucu ortam değişkenleri (`.env`) `.gitignore` ile korunmakta olup depoya dahil edilmez.
