import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;

import 'core/age_verification.dart';
import 'core/constants.dart';
import 'core/local_storage.dart';
import 'core/localization.dart';
import 'core/session_manager.dart';
import 'firebase_options.dart';
import 'models/category_model.dart';
import 'models/product_model.dart';
import 'screen/add_to_cart_control.dart';
import 'screen/address_book.dart';
import 'screen/auth_screen.dart';
import 'screen/cart_manager.dart';
import 'screen/cart_screen.dart';
import 'screen/delivery_address_screen.dart';
import 'screen/order_history_screen.dart';
import 'screen/product_detail_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    await FirebaseAuth.instance.setLanguageCode('tr');
  } catch (_) {
    // Masaüstü veya desteklenmeyen platformlarda sessizce devam eder.
  }
  await LocalStorage.instance.init();
  SessionManager.instance.restoreSession();
  // Oturum açıksa token'ı arka planda yenile (çıkış yapılmadıkça oturum açık kalır).
  unawaited(SessionManager.instance.refreshToken());
  CartManager().restoreCart();
  AddressBook.instance.restoreAddresses();
  runApp(const MarketApp());
}

class MarketApp extends StatelessWidget {
  const MarketApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppLanguage.instance,
      builder: (context, _) => MaterialApp(
        title: AppConstants.appName,
        locale: AppLanguage.instance.locale,
        supportedLocales: const [Locale('tr'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: Colors.white,
          primaryColor: AppConstants.primaryColor,
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppConstants.primaryColor,
            primary: AppConstants.primaryColor,
            secondary: AppConstants.secondaryColor,
            surface: Colors.white,
          ),
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.white,
            foregroundColor: Color(0xFF1E2022),
            elevation: 0,
            scrolledUnderElevation: 0,
          ),
        ),
        home: const AuthGate(),
      ),
    );
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _isGuest = false;

  void _continueAsGuest() {
    setState(() => _isGuest = true);
  }

  void _logoutToGuest() {
    setState(() => _isGuest = true);
    SessionManager.instance.clearSession();
    AddressBook.instance.clear();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SessionManager.instance,
      builder: (context, _) {
        if (SessionManager.instance.isAuthenticated || _isGuest) {
          return MarketHomePage(onLogout: _logoutToGuest);
        }
        return AuthScreen(onContinueAsGuest: _continueAsGuest);
      },
    );
  }
}

class MarketHomePage extends StatefulWidget {
  const MarketHomePage({super.key, this.onLogout});

  final VoidCallback? onLogout;

  @override
  State<MarketHomePage> createState() => _MarketHomePageState();
}

class _MarketHomePageState extends State<MarketHomePage> {
  late Future<List<Product>> _productsFuture;
  late Future<List<Product>> _weeklyDealsFuture;
  Future<List<Category>> _categoriesFuture = Future.value(const []);
  int? _selectedCategoryId;
  Subcategory? _selectedSubcategory;
  int _selectedTab = 0;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _productRequestController =
      TextEditingController();
  bool _isProductRequestOpen = false;
  bool _isSubmittingRequest = false;
  Timer? _searchDebounce;
  final Set<int> _favoriteProductIds = {};

  static const int favoritesCategoryId = -999;

  void _onAddressBookChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _loadFavorites();
    _productsFuture = _fetchProducts();
    _weeklyDealsFuture = _fetchWeeklyDeals();
    _categoriesFuture = _fetchCategories();
    unawaited(AddressBook.instance.fetchUserAddresses());
    AddressBook.instance.addListener(_onAddressBookChanged);

    // Açılışta 1 kereye mahsus gönderim bilgilendirme pop-up'ı
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showDeliveryInfoOnce();
    });
  }

  void _loadFavorites() {
    try {
      final raw = LocalStorage.instance.read('favorite_product_ids');
      if (raw is List) {
        _favoriteProductIds.addAll(raw.map((e) => int.tryParse(e.toString()) ?? 0).where((id) => id > 0));
      }
    } catch (_) {}
  }

  Future<void> _toggleFavorite(int productId) async {
    setState(() {
      if (_favoriteProductIds.contains(productId)) {
        _favoriteProductIds.remove(productId);
      } else {
        _favoriteProductIds.add(productId);
      }
    });
    try {
      await LocalStorage.instance.write(
        'favorite_product_ids',
        _favoriteProductIds.toList(),
      );
    } catch (_) {}
  }

  Future<void> _showDeliveryInfoOnce() async {
    final alreadyShown =
        LocalStorage.instance.read(AppConstants.deliveryInfoShownKey) == true;
    if (alreadyShown || !mounted) return;

    await LocalStorage.instance.write(AppConstants.deliveryInfoShownKey, true);
    if (!mounted) return;

    final strings = AppStrings.of(context);
    final threshold = AppConstants.freeDeliveryThreshold.toStringAsFixed(0);
    final fee = AppConstants.deliveryFee.toStringAsFixed(0);

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        icon: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppConstants.primaryColor.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.local_shipping_outlined,
            color: AppConstants.primaryColor,
            size: 36,
          ),
        ),
        title: Text(
          strings.deliveryInfoTitle,
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        content: Text(
          strings.deliveryInfoBody(threshold, fee),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, height: 1.4, color: Color(0xFF495057)),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              style: FilledButton.styleFrom(
                backgroundColor: AppConstants.primaryColor,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                strings.gotIt,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _productRequestController.dispose();
    AddressBook.instance.removeListener(_onAddressBookChanged);
    super.dispose();
  }

  Future<List<Product>> _fetchProducts({int? categoryId}) async {
    try {
      final isFavorites = categoryId == favoritesCategoryId;
      final queryParams = <String, String>{'limit': '500'};
      if (categoryId != null && !isFavorites) {
        queryParams['category_id'] = categoryId.toString();
      }
      final uri = Uri.parse('${AppConstants.baseUrl}/api/products').replace(
        queryParameters: queryParams,
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        List<dynamic> body = json.decode(response.body);
        List<Product> products = body
            .map((dynamic item) => Product.fromJson(item))
            .toList();
        if (AgeVerification.isTobaccoRestrictedPlatform) {
          products = products.where((p) => !p.isTobacco).toList();
        }
        if (categoryId == null) {
          CartManager().syncWithProducts(products);
        }
        if (isFavorites) {
          return products
              .where((p) => _favoriteProductIds.contains(p.id))
              .toList();
        }
        return products;
      }

      throw Exception('Sunucu ürünleri yükleyemedi (${response.statusCode}).');
    } on TimeoutException {
      throw Exception(
        'Sunucuya zamanında bağlanılamadı. İnternet bağlantınızı kontrol edin.',
      );
    }
  }

  Future<List<Product>> _fetchWeeklyDeals() async {
    final response = await http
        .get(Uri.parse('${AppConstants.baseUrl}/api/weekly-deals'))
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception(
        'Haftanın indirimleri yüklenemedi (${response.statusCode}).',
      );
    }

    final body = json.decode(response.body);
    if (body is! List) {
      throw const FormatException('Haftanın indirimleri yanıtı geçersiz.');
    }
    var products = body
        .map((item) => Product.fromJson(item as Map<String, dynamic>))
        .toList();
    if (AgeVerification.isTobaccoRestrictedPlatform) {
      products = products.where((p) => !p.isTobacco).toList();
    }
    return products;
  }

  Future<List<Category>> _fetchCategories() async {
    try {
      final response = await http
          .get(Uri.parse('${AppConstants.baseUrl}/api/categories'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        return const <Category>[];
      }

      final body = json.decode(response.body) as List<dynamic>;
      var categories = body
          .map((item) => Category.fromJson(item as Map<String, dynamic>))
          .toList();
      if (AgeVerification.isTobaccoRestrictedPlatform) {
        categories = categories.where((c) => !c.isTobacco).toList();
      }
      return categories;
    } catch (_) {
      return const <Category>[];
    }
  }

  String _normalizeSearchText(String input) {
    return input
        .trim()
        .replaceAll('İ', 'i')
        .replaceAll('I', 'i')
        .replaceAll('ı', 'i')
        .replaceAll('Ş', 's')
        .replaceAll('ş', 's')
        .replaceAll('Ğ', 'g')
        .replaceAll('ğ', 'g')
        .replaceAll('Ü', 'u')
        .replaceAll('ü', 'u')
        .replaceAll('Ö', 'o')
        .replaceAll('ö', 'o')
        .replaceAll('Ç', 'c')
        .replaceAll('ç', 'c')
        .toLowerCase();
  }

  void _selectCategory(int? categoryId) {
    setState(() {
      _selectedCategoryId = categoryId;
      _selectedSubcategory = null;
      _productsFuture = _fetchProducts(categoryId: categoryId);
    });
  }

  Future<void> _openCategoryScreen(
    Category category,
    List<Category> allCategories,
  ) async {
    if (category.is18Plus) {
      final ok = await AgeVerification.show18PlusDialog(
        context,
        isTobacco: category.isTobacco,
      );
      if (!ok || !mounted) return;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (context) => CategoryProductsScreen(
          initialCategory: category,
          categories: allCategories,
          favoriteProductIds: _favoriteProductIds,
          onToggleFavorite: _toggleFavorite,
        ),
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  void _retryLoadingProducts() {
    setState(() {
      _productsFuture = _fetchProducts(categoryId: _selectedCategoryId);
    });
  }

  Future<void> _editDeliveryAddress() async {
    final address = await Navigator.push<Address>(
      context,
      MaterialPageRoute(
        builder: (context) => DeliveryAddressScreen(
          initialAddress: AddressBook.instance.selectedAddress,
        ),
      ),
    );
    if (address != null && mounted) {
      AddressBook.instance.add(address);
    }
  }

  void _showNotificationsSheet(BuildContext context) {
    final strings = AppStrings.of(context);
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    strings.notifications,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppConstants.primaryColor.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.campaign_outlined,
                    color: AppConstants.primaryColor,
                  ),
                ),
                title: const Text(
                  'Prestij Market\'e Hoş Geldiniz! 🌿',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                subtitle: const Text(
                  '1000 TL ve üzeri siparişlerinizde ücretsiz teslimat fırsatını kaçırmayın.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: _buildCurrentPage(strings),
      ),
      bottomNavigationBar: _buildBottomNavigationBar(strings),
    );
  }

  Widget _buildCurrentPage(AppStrings strings) {
    switch (_selectedTab) {
      case 1:
        return _buildCategoriesTab(strings);
      case 3:
        return _buildProfileTab(strings);
      default:
        return _buildHomeTab(strings);
    }
  }

  // ---------------------------------------------------------------------------
  // 1. ANA SAYFA TABI (Görseldeki Yeni Tasarım)
  // ---------------------------------------------------------------------------
  Widget _buildHomeTab(AppStrings strings) {
    return RefreshIndicator(
      color: AppConstants.primaryColor,
      onRefresh: () async {
        final prodFuture = _fetchProducts(categoryId: _selectedCategoryId);
        final weeklyDealsFuture = _fetchWeeklyDeals();
        final catFuture = _fetchCategories();
        setState(() {
          _productsFuture = prodFuture;
          _weeklyDealsFuture = weeklyDealsFuture;
          _categoriesFuture = catFuture;
        });
        await Future.wait([prodFuture, weeklyDealsFuture, catFuture]);
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // 1. Üst Bar: Logo + Konum Seçici + Bildirim Zili
          SliverToBoxAdapter(
            child: _buildTopHeader(strings),
          ),

          // 2. Arama Çubuğu
          SliverToBoxAdapter(
            child: _buildSearchBar(strings),
          ),

          // Arama yapılmıyorsa Fırsat Banner'ı ve Kategorileri göster
          if (_searchQuery.isEmpty) ...[
            // 3. Fırsat / Kampanya Bannerı
            SliverToBoxAdapter(
              child: _buildWeeklyDealsCarousel(strings),
            ),

            // 4. Kategoriler Bölümü (Yatay Liste)
            SliverToBoxAdapter(
              child: _buildCategoriesSection(strings),
            ),
          ],

          // 5. Popüler Ürünler Başlığı
          SliverToBoxAdapter(
            child: _buildProductsHeader(strings),
          ),

          // 6. Ürün Izgarası (2'li Grid)
          _buildProductsGrid(strings),

          const SliverToBoxAdapter(
            child: SizedBox(height: 24),
          ),
        ],
      ),
    );
  }

  // Üst Bar: Logo (AppConstants.appName) + "📍 Konum seçin >" + 🔔 Zili
  Widget _buildTopHeader(AppStrings strings) {
    final currentAddress = AddressBook.instance.selectedAddress;
    final addressText = currentAddress != null
        ? currentAddress.title
        : strings.selectLocation;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Sol: Yaprak ikonu + Başlık + Adres
          InkWell(
            onTap: _editDeliveryAddress,
            borderRadius: BorderRadius.circular(12),
            child: Row(
              children: [
                // Yeşil Yaprak İkonu
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppConstants.primaryColor.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.eco_rounded,
                      color: AppConstants.primaryColor,
                      size: 22,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Prestij Market',
                      style: TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w900,
                        color: AppConstants.primaryColor,
                        letterSpacing: -0.4,
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.location_on_outlined,
                          size: 13,
                          color: Colors.grey.shade600,
                        ),
                        const SizedBox(width: 2),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 160),
                          child: Text(
                            addressText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.chevron_right,
                          size: 15,
                          color: Colors.grey.shade600,
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Sağ: Kırmızı bildirim noktalı zil butonu
          Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(
                icon: const Icon(
                  Icons.notifications_none_rounded,
                  size: 26,
                  color: Color(0xFF1E2022),
                ),
                onPressed: () => _showNotificationsSheet(context),
              ),
              Positioned(
                right: 12,
                top: 10,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Arama Çubuğu (Oval, açık gri zeminli, filtre ikonlu)
  Widget _buildSearchBar(AppStrings strings) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: const Color(0xFFF4F6F8),
          borderRadius: BorderRadius.circular(24),
        ),
        child: TextField(
          controller: _searchController,
          onChanged: (value) {
            _searchDebounce?.cancel();
            _searchDebounce = Timer(const Duration(milliseconds: 300), () {
              if (mounted) {
                setState(() {
                  _searchQuery = value;
                });
              }
            });
          },
          decoration: InputDecoration(
            hintText: strings.searchHint,
            hintStyle: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade500,
              fontWeight: FontWeight.w400,
            ),
            prefixIcon: Icon(
              Icons.search_rounded,
              color: Colors.grey.shade500,
              size: 22,
            ),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_searchQuery.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    color: Colors.grey.shade600,
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                  ),
                IconButton(
                  icon: const Icon(
                    Icons.tune_rounded,
                    color: Color(0xFF1E2022),
                    size: 20,
                  ),
                  onPressed: () {
                    // Kategoriler sekmesine hızlı geçiş
                    setState(() => _selectedTab = 1);
                  },
                ),
              ],
            ),
            border: InputBorder.none,
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
    );
  }

  Widget _buildWeeklyDealsCarousel(AppStrings strings) {
    return FutureBuilder<List<Product>>(
      future: _weeklyDealsFuture,
      builder: (context, snapshot) {
        final products = snapshot.data ?? const <Product>[];
        return Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Row(
                  children: [
                    const Icon(
                      Icons.local_fire_department_rounded,
                      color: AppConstants.primaryColor,
                      size: 21,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      strings.weeklyDiscounts,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1E2022),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 188,
                child: snapshot.connectionState == ConnectionState.waiting
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: AppConstants.primaryColor,
                        ),
                      )
                    : snapshot.hasError
                    ? Center(
                        child: TextButton.icon(
                          onPressed: () {
                            setState(() {
                              _weeklyDealsFuture = _fetchWeeklyDeals();
                            });
                          },
                          icon: const Icon(Icons.refresh),
                          label: Text(strings.weeklyDealsLoadError),
                        ),
                      )
                    : products.isEmpty
                    ? Center(
                        child: Text(
                          strings.noWeeklyDiscounts,
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        scrollDirection: Axis.horizontal,
                        itemCount: products.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 10),
                        itemBuilder: (context, index) =>
                            _buildWeeklyDealProductCard(products[index]),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildWeeklyDealProductCard(Product product) {
    final isFavorite = _favoriteProductIds.contains(product.id);

    return AnimatedBuilder(
      animation: CartManager(),
      builder: (context, _) {

        return Container(
          width: 138,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE9ECEF)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: InkWell(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                ProductDetailScreen(product: product),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 8, 18),
                          child: Image.network(
                            product.imageUrl,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => const Center(
                              child: Icon(
                                Icons.image_not_supported_outlined,
                                color: Colors.grey,
                                size: 28,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: IconButton(
                        onPressed: () => _toggleFavorite(product.id),
                        icon: Icon(
                          isFavorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: isFavorite
                              ? Colors.red
                              : Colors.grey.shade500,
                          size: 17,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 26,
                          minHeight: 26,
                        ),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    Positioned(
                      left: 6,
                      right: 6,
                      bottom: 0,
                      child: AddToCartControl(product: product, compact: true),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      product.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF25282A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '₺${product.price.toStringAsFixed(2)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1E2022),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Kategoriler Bölümü (Dairesel Yeşil Zeminli İkonlar)
  Widget _buildCategoriesSection(AppStrings strings) {
    return FutureBuilder<List<Category>>(
      future: _categoriesFuture,
      builder: (context, snapshot) {
        final categories = snapshot.data ?? <Category>[];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    strings.categories,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1E2022),
                    ),
                  ),
                  InkWell(
                    onTap: () {
                      setState(() => _selectedTab = 1);
                    },
                    child: Text(
                      strings.viewAll,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 104,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                scrollDirection: Axis.horizontal,
                itemCount: categories.length + 2, // +1 "Tümü", +1 "Favoriler" için
                itemBuilder: (context, index) {
                  final isAll = index == 0;
                  final isFavorites = index == 1;
                  final category = (isAll || isFavorites) ? null : categories[index - 2];
                  final isSelected = isAll
                      ? _selectedCategoryId == null
                      : isFavorites
                          ? _selectedCategoryId == favoritesCategoryId
                          : _selectedCategoryId == category?.id;

                  final title = isAll
                      ? strings.all
                      : isFavorites
                          ? strings.favorites
                          : category!.name;
                  final iconData = isFavorites
                      ? Icons.favorite_rounded
                      : _getCategoryIcon(title);
                  final iconColor = isFavorites
                      ? (isSelected ? Colors.red : Colors.redAccent)
                      : AppConstants.primaryColor;

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: InkWell(
                      onTap: () async {
                        if (category != null) {
                          await _openCategoryScreen(category, categories);
                          return;
                        }
                        _selectCategory(isFavorites ? favoritesCategoryId : null);
                      },
                      borderRadius: BorderRadius.circular(35),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? (isFavorites
                                      ? Colors.red.withValues(alpha: 0.15)
                                      : AppConstants.primaryColor
                                          .withValues(alpha: 0.18))
                                  : (isFavorites
                                      ? const Color(0xFFFFECEF)
                                      : const Color(0xFFE8F6ED)),
                              shape: BoxShape.circle,
                              border: isSelected
                                  ? Border.all(
                                      color: isFavorites
                                          ? Colors.red
                                          : AppConstants.primaryColor,
                                      width: 2,
                                    )
                                  : null,
                            ),
                            child: Icon(
                              iconData,
                              size: 28,
                              color: iconColor,
                            ),
                          ),
                          const SizedBox(height: 6),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 72),
                            child: Text(
                              title,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isSelected
                                    ? FontWeight.bold
                                    : FontWeight.w500,
                                color: isSelected
                                    ? (isFavorites
                                        ? Colors.red
                                        : AppConstants.primaryColor)
                                    : const Color(0xFF2B2D42),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_selectedCategoryId != null &&
                _selectedCategoryId != favoritesCategoryId)
              Builder(
                builder: (context) {
                  final activeCat = categories
                      .where((c) => c.id == _selectedCategoryId)
                      .firstOrNull;
                  if (activeCat == null || activeCat.subcategories.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: SizedBox(
                      height: 38,
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        scrollDirection: Axis.horizontal,
                        itemCount: activeCat.subcategories.length + 1,
                        separatorBuilder: (_, _) => const SizedBox(width: 8),
                        itemBuilder: (context, idx) {
                          final sub = idx == 0
                              ? null
                              : activeCat.subcategories[idx - 1];
                          final selected = _selectedSubcategory?.id == sub?.id;
                          return ChoiceChip(
                            label: Text(sub == null ? strings.all : sub.name),
                            selected: selected,
                            showCheckmark: false,
                            selectedColor: AppConstants.primaryColor,
                            backgroundColor: const Color(0xFFF4F6F8),
                            labelStyle: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: selected
                                  ? Colors.white
                                  : const Color(0xFF1E2022),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                              side: BorderSide(
                                color: selected
                                    ? AppConstants.primaryColor
                                    : const Color(0xFFE2E6EA),
                              ),
                            ),
                            onSelected: (_) {
                              setState(() => _selectedSubcategory = sub);
                            },
                          );
                        },
                      ),
                    ),
                  );
                },
              ),
          ],
        );
      },
    );
  }

  IconData _getCategoryIcon(String categoryName) {
    final lower = categoryName.toLowerCase();
    if (AgeVerification.isTobaccoText(lower)) return Icons.smoking_rooms_rounded;
    if (AgeVerification.isAlcoholText(lower)) return Icons.wine_bar_rounded;
    if (lower.contains('meyve')) return Icons.apple_rounded;
    if (lower.contains('sebze')) return Icons.eco_rounded;
    if (lower.contains('içecek') || lower.contains('icecek')) {
      return Icons.local_drink_rounded;
    }
    if (lower.contains('süt') || lower.contains('sut')) {
      return Icons.icecream_rounded;
    }
    if (lower.contains('atıştırmalık') || lower.contains('atistirmalik')) {
      return Icons.cookie_rounded;
    }
    if (lower.contains('kahvaltı') || lower.contains('kahvalti')) {
      return Icons.egg_alt_rounded;
    }
    if (lower.contains('fırın') || lower.contains('firin') || lower.contains('ekmek') || lower.contains('temel')) {
      return Icons.bakery_dining_rounded;
    }
    if (lower.contains('temizlik')) return Icons.cleaning_services_rounded;
    if (lower.contains('kişisel') || lower.contains('kisisel')) {
      return Icons.spa_rounded;
    }
    if (lower.contains('tümü') || lower.contains('all')) {
      return Icons.grid_view_rounded;
    }
    return Icons.shopping_basket_rounded;
  }

  // Popüler Ürünler Başlık Satırı
  Widget _buildProductsHeader(AppStrings strings) {
    final title = _selectedCategoryId == favoritesCategoryId
        ? strings.favorites
        : _selectedCategoryId != null
            ? strings.categories
            : strings.popularProducts;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1E2022),
            ),
          ),
          if (_selectedCategoryId != null)
            InkWell(
              onTap: () => _selectCategory(null),
              child: Text(
                strings.all,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppConstants.primaryColor,
                ),
              ),
            )
          else
            Text(
              strings.viewAll,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600,
              ),
            ),
        ],
      ),
    );
  }

  // 2'li Izgara (Modern Kartlar: Kalp İkonu, Görsel, İsim, Birim, Fiyat ve Sepet Butonu)
  Widget _buildProductsGrid(AppStrings strings) {
    return FutureBuilder<List<Product>>(
      future: _productsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(40),
              child: Center(
                child: CircularProgressIndicator(
                  color: AppConstants.primaryColor,
                ),
              ),
            ),
          );
        }
        if (snapshot.hasError) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  const Icon(
                    Icons.cloud_off,
                    size: 48,
                    color: AppConstants.textSecondary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Ürünler yüklenemedi.\n${snapshot.error}',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _retryLoadingProducts,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Tekrar dene'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppConstants.primaryColor,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        final products = snapshot.data ?? <Product>[];
        final query = _normalizeSearchText(_searchQuery);
        final subFilter = _selectedSubcategory;
        final filtered = products.where((p) {
          if (subFilter != null && !p.matchesSubcategory(subFilter)) {
            return false;
          }
          if (query.isNotEmpty) {
            return _normalizeSearchText(p.title).contains(query) ||
                _normalizeSearchText(p.description).contains(query) ||
                _normalizeSearchText(p.category).contains(query) ||
                _normalizeSearchText(p.subcategory).contains(query);
          }
          return true;
        }).toList();

        if (filtered.isEmpty) {
          final isFavorites = _selectedCategoryId == favoritesCategoryId;
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(48),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isFavorites) ...[
                      const Icon(
                        Icons.favorite_border_rounded,
                        size: 48,
                        color: Colors.grey,
                      ),
                      const SizedBox(height: 12),
                    ],
                    Text(
                      isFavorites ? strings.noFavorites : strings.noSearchResults,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 14,
              childAspectRatio: 0.72,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final product = filtered[index];
                return _buildModernProductCard(product);
              },
              childCount: filtered.length,
            ),
          ),
        );
      },
    );
  }

  Widget _buildModernProductCard(Product product) {
    final isFavorite = _favoriteProductIds.contains(product.id);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFF0F1F3), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.025),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.topRight,
            child: IconButton(
              iconSize: 20,
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(),
              icon: Icon(
                isFavorite
                    ? Icons.favorite_rounded
                    : Icons.favorite_border_rounded,
                color: isFavorite ? Colors.red : Colors.grey.shade400,
              ),
              onPressed: () => _toggleFavorite(product.id),
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: InkWell(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            ProductDetailScreen(product: product),
                      ),
                    ).then((_) => setState(() {})),
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 22),
                        child: Image.network(
                          product.imageUrl,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.image_not_supported_outlined,
                            size: 40,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 0,
                  child: AddToCartControl(product: product),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  product.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1E2022),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  product.description.isNotEmpty
                      ? product.description
                      : '1 adet',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: Colors.grey.shade500,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '₺${product.price.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    color: AppConstants.primaryColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 2. KATEGORİLER TABI
  // ---------------------------------------------------------------------------
  Widget _buildCategoriesTab(AppStrings strings) {
    return FutureBuilder<List<Category>>(
      future: _categoriesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppConstants.primaryColor),
          );
        }
        final categories = snapshot.data ?? <Category>[];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                strings.categories,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF1E2022),
                ),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                color: AppConstants.primaryColor,
                onRefresh: () async {
                  final future = _fetchCategories();
                  setState(() => _categoriesFuture = future);
                  await future;
                },
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: categories.length + 2, // +1 "Tümü", +1 "Favoriler"
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final isAll = index == 0;
                    final isFavorites = index == 1;
                    final category = (isAll || isFavorites) ? null : categories[index - 2];
                    final title = isAll
                        ? strings.all
                        : isFavorites
                            ? strings.favorites
                            : category!.name;
                    final isSelected = isAll
                        ? _selectedCategoryId == null
                        : isFavorites
                            ? _selectedCategoryId == favoritesCategoryId
                            : _selectedCategoryId == category?.id;

                    final iconData = isFavorites
                        ? Icons.favorite_rounded
                        : _getCategoryIcon(title);
                    final iconColor = isFavorites
                        ? Colors.red
                        : AppConstants.primaryColor;

                    return Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: isSelected
                              ? (isFavorites ? Colors.red : AppConstants.primaryColor)
                              : const Color(0xFFEEF0F2),
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      color: isSelected
                          ? (isFavorites
                              ? Colors.red.withValues(alpha: 0.08)
                              : AppConstants.primaryColor.withValues(alpha: 0.08))
                          : Colors.white,
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: isFavorites
                              ? const Color(0xFFFFECEF)
                              : const Color(0xFFE8F6ED),
                          child: Icon(
                            iconData,
                            color: iconColor,
                            size: 22,
                          ),
                        ),
                        title: Text(
                          title,
                          style: TextStyle(
                            fontWeight: isSelected
                                ? FontWeight.bold
                                : FontWeight.w600,
                            color: isSelected
                                ? (isFavorites ? Colors.red : AppConstants.primaryColor)
                                : const Color(0xFF1E2022),
                          ),
                        ),
                        subtitle: (category != null && category.subcategories.isNotEmpty)
                            ? Text(
                                category.subcategories.map((s) => s.name).join(' • '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600,
                                ),
                              )
                            : null,
                        trailing: const Icon(
                          Icons.chevron_right,
                          color: Colors.grey,
                        ),
                        onTap: () async {
                          if (category != null) {
                            await _openCategoryScreen(category, categories);
                            return;
                          }
                          _selectCategory(isFavorites ? favoritesCategoryId : null);
                          setState(() => _selectedTab = 0);
                        },
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 3. PROFİL TABI
  // ---------------------------------------------------------------------------
  Widget _buildProfileTab(AppStrings strings) {
    return ListenableBuilder(
      listenable: SessionManager.instance,
      builder: (context, _) {
        final isAuthenticated = SessionManager.instance.isAuthenticated;
        final userName = SessionManager.instance.userName;
        final userEmail = SessionManager.instance.userEmail;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                strings.profile,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF1E2022),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Kullanıcı Kartı
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF7FAF8),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE3EDE6)),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: AppConstants.primaryColor,
                    child: Text(
                      userName.isNotEmpty ? userName[0].toUpperCase() : '👤',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isAuthenticated ? userName : 'Misafir Kullanıcı',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1E2022),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          isAuthenticated ? userEmail : 'Giriş yapılmadı',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!isAuthenticated)
                    FilledButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const AuthScreen()),
                        );
                      },
                      style: FilledButton.styleFrom(
                        backgroundColor: AppConstants.primaryColor,
                      ),
                      child: Text(strings.login),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Profil Seçenekleri
            _buildProfileMenuItem(
              icon: Icons.receipt_long_rounded,
              title: strings.myOrders,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const OrderHistoryScreen(),
                  ),
                );
              },
            ),
            _buildProfileMenuItem(
              icon: Icons.location_on_rounded,
              title: strings.savedAddresses,
              onTap: _editDeliveryAddress,
            ),
            _buildProfileMenuItem(
              icon: Icons.language_rounded,
              title: '${strings.language} (${AppLanguage.instance.code.toUpperCase()})',
              onTap: () {
                final newCode =
                    AppLanguage.instance.code == 'tr' ? 'en' : 'tr';
                AppLanguage.instance.setCode(newCode);
              },
            ),
            _buildProfileMenuItem(
              icon: Icons.notifications_none_rounded,
              title: strings.notifications,
              onTap: () => _showNotificationsSheet(context),
            ),
            _buildProductRequestSection(strings),

            if (isAuthenticated) ...[
              _buildProfileMenuItem(
                icon: Icons.manage_accounts_outlined,
                title: strings.accountSettings,
                onTap: () => _showAccountSettingsSheet(strings),
              ),
              const SizedBox(height: 12),
              _buildProfileMenuItem(
                icon: Icons.logout_rounded,
                title: strings.logout,
                color: Colors.red,
                onTap: () {
                  if (widget.onLogout != null) {
                    widget.onLogout!();
                  } else {
                    SessionManager.instance.clearSession();
                    AddressBook.instance.clear();
                  }
                },
              ),
            ],
          ],
        );
      },
    );
  }

  void _showAccountSettingsSheet(AppStrings strings) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    strings.accountSettings,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: Colors.red.withValues(alpha: 0.1),
                  child: const Icon(
                    Icons.delete_forever_rounded,
                    color: Colors.red,
                  ),
                ),
                title: Text(
                  strings.deleteAccount,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.red,
                  ),
                ),
                subtitle: Text(
                  strings.deleteAccountConfirmBody,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _confirmDeleteAccount(strings);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteAccount(AppStrings strings) async {
    final confirmController = TextEditingController();
    final confirmWord = strings.deleteAccountConfirmWord;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final isMatch =
              confirmController.text.trim().toUpperCase() == confirmWord;
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Text(
              strings.deleteAccountConfirmTitle,
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.deleteAccountConfirmBody,
                  style: const TextStyle(fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: confirmController,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: InputDecoration(
                    hintText: strings.deleteAccountTypeHint,
                    hintStyle: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade500,
                    ),
                    filled: true,
                    fillColor: const Color(0xFFF7FAF8),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFDDE2E6)),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(strings.cancel),
              ),
              FilledButton(
                onPressed: isMatch ? () => Navigator.pop(ctx, true) : null,
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                child: Text(strings.delete),
              ),
            ],
          );
        },
      ),
    );
    confirmController.dispose();
    if (confirmed != true || !mounted) return;

    final token = SessionManager.instance.token;
    if (token == null || token.isEmpty) return;

    try {
      final response = await http
          .delete(
            Uri.parse('${AppConstants.baseUrl}/api/auth/account'),
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      if (response.statusCode == 200) {
        try {
          await FirebaseAuth.instance.currentUser?.delete();
        } catch (_) {
          try {
            await FirebaseAuth.instance.signOut();
          } catch (_) {}
        }
        if (widget.onLogout != null) {
          widget.onLogout!();
        } else {
          SessionManager.instance.clearSession();
          AddressBook.instance.clear();
        }
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(strings.deleteAccountSuccess),
            backgroundColor: AppConstants.primaryColor,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Hesap silinemedi. Lütfen tekrar deneyin.'),
            backgroundColor: Colors.red.shade600,
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Sunucuya bağlanılamadı.'),
          backgroundColor: Colors.red.shade600,
        ),
      );
    }
  }

  Future<void> _submitProductRequest(AppStrings strings) async {
    final text = _productRequestController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(strings.productRequestEmpty),
          backgroundColor: Colors.red.shade600,
        ),
      );
      return;
    }
    final trimmed = text.length > 30 ? text.substring(0, 30) : text;

    setState(() => _isSubmittingRequest = true);
    try {
      final headers = <String, String>{
        'Content-Type': 'application/json',
      };
      final token = SessionManager.instance.token;
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }

      final response = await http
          .post(
            Uri.parse('${AppConstants.baseUrl}/api/product-requests'),
            headers: headers,
            body: json.encode({
              'product_name': trimmed,
              'user_name': SessionManager.instance.userName,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      if (response.statusCode == 201 || response.statusCode == 200) {
        _productRequestController.clear();
        FocusScope.of(context).unfocus();
        setState(() => _isProductRequestOpen = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(strings.productRequestSuccess),
            backgroundColor: AppConstants.primaryColor,
          ),
        );
      } else {
        final body = json.decode(response.body);
        final err = body['error']?.toString() ?? 'Bir hata oluştu.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(err),
            backgroundColor: Colors.red.shade600,
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Sunucuya bağlanılamadı. Lütfen tekrar deneyin.'),
          backgroundColor: Colors.red.shade600,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmittingRequest = false);
      }
    }
  }

  Widget _buildProductRequestSection(AppStrings strings) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: _isProductRequestOpen
              ? AppConstants.primaryColor.withValues(alpha: 0.4)
              : const Color(0xFFF0F1F3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(
              Icons.add_shopping_cart_rounded,
              color: AppConstants.primaryColor,
            ),
            title: Text(
              strings.productRequestTitle,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: Color(0xFF1E2022),
              ),
            ),
            trailing: Icon(
              _isProductRequestOpen
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.chevron_right,
              color: Colors.grey,
              size: 20,
            ),
            onTap: () {
              setState(() {
                _isProductRequestOpen = !_isProductRequestOpen;
              });
            },
          ),
          if (_isProductRequestOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    strings.productRequestSubtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _productRequestController,
                    autofocus: true,
                    maxLength: 30,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) {
                      if (!_isSubmittingRequest) {
                        _submitProductRequest(strings);
                      }
                    },
                    decoration: InputDecoration(
                      hintText: strings.productRequestHint,
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade500,
                      ),
                      filled: true,
                      fillColor: const Color(0xFFF7FAF8),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFFDDE2E6)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFFDDE2E6)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: AppConstants.primaryColor,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _isSubmittingRequest
                          ? null
                          : () => _submitProductRequest(strings),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppConstants.primaryColor,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: _isSubmittingRequest
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send_rounded, size: 18),
                      label: Text(
                        strings.productRequestSubmit,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProfileMenuItem({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    Color? color,
  }) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Color(0xFFF0F1F3)),
      ),
      child: ListTile(
        leading: Icon(icon, color: color ?? AppConstants.primaryColor),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: color ?? const Color(0xFF1E2022),
          ),
        ),
        trailing: const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
        onTap: onTap,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 4. ALT GEZİNME ÇUBUĞU (Bottom Navigation Bar - Görselle Birebir)
  // ---------------------------------------------------------------------------
  Widget _buildBottomNavigationBar(AppStrings strings) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: Color(0xFFF0F1F3), width: 1.2),
        ),
      ),
      child: NavigationBar(
        height: 64,
        elevation: 0,
        backgroundColor: Colors.white,
        indicatorColor: AppConstants.primaryColor.withValues(alpha: 0.12),
        selectedIndex: _selectedTab,
        onDestinationSelected: (index) {
          if (index == 2) {
            // Sepet tıklandığında sepet ekranını aç
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const CartScreen()),
            ).then((_) => _retryLoadingProducts());
            return;
          }
          setState(() {
            _selectedTab = index;
            if (index == 0) {
              _productsFuture = _fetchProducts(categoryId: _selectedCategoryId);
            } else if (index == 1) {
              _categoriesFuture = _fetchCategories();
            }
          });
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(
              Icons.home_rounded,
              color: AppConstants.primaryColor,
            ),
            label: strings.home,
          ),
          NavigationDestination(
            icon: const Icon(Icons.grid_view_rounded),
            selectedIcon: const Icon(
              Icons.grid_view_rounded,
              color: AppConstants.primaryColor,
            ),
            label: strings.categories,
          ),
          NavigationDestination(
            icon: _buildCartNavIcon(Icons.shopping_cart_outlined),
            selectedIcon: _buildCartNavIcon(Icons.shopping_cart_rounded),
            label: strings.cart,
          ),
          NavigationDestination(
            icon: const Icon(Icons.person_outline_rounded),
            selectedIcon: const Icon(
              Icons.person_rounded,
              color: AppConstants.primaryColor,
            ),
            label: strings.profile,
          ),
        ],
      ),
    );
  }

  Widget _buildCartNavIcon(IconData icon) {
    return ListenableBuilder(
      listenable: CartManager(),
      builder: (context, _) {
        final totalCount = CartManager().totalQuantity;
        return Badge(
          isLabelVisible: totalCount > 0,
          label: Text(
            '$totalCount',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10),
          ),
          backgroundColor: AppConstants.primaryColor,
          alignment: AlignmentDirectional.topEnd,
          offset: const Offset(6, -4),
          child: Icon(icon),
        );
      },
    );
  }
}

class CategoryProductsScreen extends StatefulWidget {
  const CategoryProductsScreen({
    super.key,
    required this.initialCategory,
    required this.categories,
    required this.favoriteProductIds,
    required this.onToggleFavorite,
  });

  final Category initialCategory;
  final List<Category> categories;
  final Set<int> favoriteProductIds;
  final Future<void> Function(int productId) onToggleFavorite;

  @override
  State<CategoryProductsScreen> createState() => _CategoryProductsScreenState();
}

class _CategoryProductsScreenState extends State<CategoryProductsScreen> {
  late Category _selectedCategory;
  Subcategory? _selectedSubcategory;
  late Future<List<Product>> _productsFuture;

  @override
  void initState() {
    super.initState();
    _selectedCategory = widget.initialCategory;
    _productsFuture = _fetchCategoryProducts(_selectedCategory.id);
  }

  Future<List<Product>> _fetchCategoryProducts(int categoryId) async {
    final uri = Uri.parse('${AppConstants.baseUrl}/api/products').replace(
      queryParameters: {'category_id': categoryId.toString()},
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 10));
    if (response.statusCode == 200) {
      final List<dynamic> body = json.decode(response.body);
      var products = body.map((item) => Product.fromJson(item)).toList();
      if (AgeVerification.isTobaccoRestrictedPlatform) {
        products = products.where((p) => !p.isTobacco).toList();
      }
      return products;
    }
    throw Exception('Ürünler yüklenemedi (${response.statusCode}).');
  }

  Future<void> _switchCategory(Category category) async {
    if (category.id == _selectedCategory.id) return;
    if (category.is18Plus) {
      final ok = await AgeVerification.show18PlusDialog(
        context,
        isTobacco: category.isTobacco,
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _selectedCategory = category;
      _selectedSubcategory = null;
      _productsFuture = _fetchCategoryProducts(category.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    final subcategories = _selectedCategory.subcategories;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(
          _selectedCategory.name,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        centerTitle: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ListenableBuilder(
              listenable: CartManager(),
              builder: (context, _) {
                final totalCount = CartManager().totalQuantity;
                return IconButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const CartScreen()),
                    ).then((_) {
                      if (mounted) setState(() {});
                    });
                  },
                  icon: Badge(
                    isLabelVisible: totalCount > 0,
                    label: Text(
                      '$totalCount',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 10,
                      ),
                    ),
                    backgroundColor: AppConstants.primaryColor,
                    child: const Icon(Icons.shopping_cart_outlined),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Üst Kaydırmalı Ana Kategoriler Çubuğu
          if (widget.categories.isNotEmpty)
            Container(
              height: 46,
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(
                  bottom: BorderSide(color: Color(0xFFF0F1F3), width: 1),
                ),
              ),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                scrollDirection: Axis.horizontal,
                itemCount: widget.categories.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final cat = widget.categories[index];
                  final isSelected = cat.id == _selectedCategory.id;
                  return InkWell(
                    onTap: () => _switchCategory(cat),
                    borderRadius: BorderRadius.circular(18),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppConstants.primaryColor
                            : const Color(0xFFF4F6F8),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        cat.name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSelected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          color: isSelected
                              ? Colors.white
                              : const Color(0xFF2B2D42),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

          // 2. Üst Kaydırmalı Alt Kategoriler (Subcategory) Çubuğu
          if (subcategories.isNotEmpty)
            Container(
              height: 50,
              decoration: const BoxDecoration(
                color: Color(0xFFFAFDFB),
                border: Border(
                  bottom: BorderSide(color: Color(0xFFE9ECEF), width: 1),
                ),
              ),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                scrollDirection: Axis.horizontal,
                itemCount: subcategories.length + 1,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final sub = index == 0 ? null : subcategories[index - 1];
                  final isSelected = _selectedSubcategory?.id == sub?.id;
                  final label = sub == null ? strings.all : sub.name;

                  return InkWell(
                    onTap: () {
                      setState(() => _selectedSubcategory = sub);
                    },
                    borderRadius: BorderRadius.circular(20),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? AppConstants.primaryColor.withValues(alpha: 0.14)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isSelected
                              ? AppConstants.primaryColor
                              : const Color(0xFFDDE2E6),
                          width: isSelected ? 1.5 : 1,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: isSelected
                              ? FontWeight.w800
                              : FontWeight.w600,
                          color: isSelected
                              ? AppConstants.primaryColor
                              : const Color(0xFF343A40),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),

          // 3. Ürün Izgarası
          Expanded(
            child: RefreshIndicator(
              color: AppConstants.primaryColor,
              onRefresh: () async {
                final fut = _fetchCategoryProducts(_selectedCategory.id);
                setState(() => _productsFuture = fut);
                await fut;
              },
              child: FutureBuilder<List<Product>>(
                future: _productsFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(
                        color: AppConstants.primaryColor,
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.cloud_off,
                              size: 44,
                              color: Colors.grey,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Ürünler yüklenemedi.\n${snapshot.error}',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: () {
                                setState(() {
                                  _productsFuture = _fetchCategoryProducts(
                                    _selectedCategory.id,
                                  );
                                });
                              },
                              icon: const Icon(Icons.refresh),
                              label: const Text('Tekrar dene'),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppConstants.primaryColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  final allProducts = snapshot.data ?? const <Product>[];
                  final activeSub = _selectedSubcategory;
                  final filtered = activeSub == null
                      ? allProducts
                      : allProducts
                          .where((p) => p.matchesSubcategory(activeSub))
                          .toList();

                  if (filtered.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          strings.noSearchResults,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade600),
                        ),
                      ),
                    );
                  }

                  return GridView.builder(
                    padding: const EdgeInsets.all(16),
                    physics: const AlwaysScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 14,
                      childAspectRatio: 0.72,
                    ),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final product = filtered[index];
                      final isFavorite = widget.favoriteProductIds.contains(
                        product.id,
                      );

                      return Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: const Color(0xFFF0F1F3),
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.025),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Align(
                              alignment: Alignment.topRight,
                              child: IconButton(
                                iconSize: 20,
                                padding: const EdgeInsets.all(8),
                                constraints: const BoxConstraints(),
                                icon: Icon(
                                  isFavorite
                                      ? Icons.favorite_rounded
                                      : Icons.favorite_border_rounded,
                                  color: isFavorite
                                      ? Colors.red
                                      : Colors.grey.shade400,
                                ),
                                onPressed: () async {
                                  await widget.onToggleFavorite(product.id);
                                  if (mounted) setState(() {});
                                },
                              ),
                            ),
                            Expanded(
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: InkWell(
                                      onTap: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              ProductDetailScreen(
                                                product: product,
                                              ),
                                        ),
                                      ).then((_) {
                                        if (mounted) setState(() {});
                                      }),
                                      child: Center(
                                        child: Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                            8,
                                            0,
                                            8,
                                            22,
                                          ),
                                          child: Image.network(
                                            product.imageUrl,
                                            fit: BoxFit.contain,
                                            errorBuilder: (_, _, _) =>
                                                const Icon(
                                                  Icons
                                                      .image_not_supported_outlined,
                                                  size: 40,
                                                  color: Colors.grey,
                                                ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    left: 10,
                                    right: 10,
                                    bottom: 0,
                                    child: AddToCartControl(product: product),
                                  ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    product.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF1E2022),
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    product.description.isNotEmpty
                                        ? product.description
                                        : (product.subcategory.isNotEmpty
                                            ? product.subcategory
                                            : '1 adet'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w400,
                                      color: Colors.grey.shade500,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    '₺${product.price.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w900,
                                      color: AppConstants.primaryColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
