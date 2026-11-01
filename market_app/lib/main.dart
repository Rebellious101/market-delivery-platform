import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;

import 'core/constants.dart';
import 'core/local_storage.dart';
import 'core/localization.dart';
import 'core/session_manager.dart';
import 'models/campaign_model.dart';
import 'models/category_model.dart';
import 'models/product_model.dart';
import 'screen/address_book.dart';
import 'screen/auth_screen.dart';
import 'screen/cart_manager.dart';
import 'screen/cart_screen.dart';
import 'screen/delivery_address_screen.dart';
import 'screen/order_history_screen.dart';
import 'screen/product_detail_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalStorage.instance.init();
  SessionManager.instance.restoreSession();
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
  Future<List<Category>> _categoriesFuture = Future.value(const []);
  late Future<List<Campaign>> _campaignsFuture;
  int? _selectedCategoryId;
  int _selectedTab = 0;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  final Set<int> _favoriteProductIds = {};

  void _onAddressBookChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _productsFuture = _fetchProducts();
    _categoriesFuture = _fetchCategories();
    _campaignsFuture = _fetchCampaigns();
    unawaited(AddressBook.instance.fetchUserAddresses());
    AddressBook.instance.addListener(_onAddressBookChanged);

    // Açılışta 1 kereye mahsus gönderim bilgilendirme pop-up'ı
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showDeliveryInfoOnce();
    });
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
    AddressBook.instance.removeListener(_onAddressBookChanged);
    super.dispose();
  }

  Future<List<Product>> _fetchProducts({int? categoryId}) async {
    try {
      final uri = Uri.parse('${AppConstants.baseUrl}/api/products').replace(
        queryParameters: categoryId == null
            ? null
            : {'category_id': categoryId.toString()},
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        List<dynamic> body = json.decode(response.body);
        List<Product> products = body
            .map((dynamic item) => Product.fromJson(item))
            .toList();
        if (categoryId == null) {
          CartManager().syncWithProducts(products);
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

  Future<List<Category>> _fetchCategories() async {
    try {
      final response = await http
          .get(Uri.parse('${AppConstants.baseUrl}/api/categories'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        return const <Category>[];
      }

      final body = json.decode(response.body) as List<dynamic>;
      return body
          .map((item) => Category.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const <Category>[];
    }
  }

  Future<List<Campaign>> _fetchCampaigns() async {
    try {
      final response = await http
          .get(Uri.parse('${AppConstants.baseUrl}/api/campaigns'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        return const <Campaign>[];
      }

      final body = json.decode(response.body);
      if (body is List) {
        return body
            .whereType<Map<String, dynamic>>()
            .map(Campaign.fromJson)
            .toList();
      }
      return const <Campaign>[];
    } catch (_) {
      return const <Campaign>[];
    }
  }

  void _selectCategory(int? categoryId) {
    setState(() {
      _selectedCategoryId = categoryId;
      _productsFuture = _fetchProducts(categoryId: categoryId);
    });
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
        final catFuture = _fetchCategories();
        final campFuture = _fetchCampaigns();
        setState(() {
          _productsFuture = prodFuture;
          _categoriesFuture = catFuture;
          _campaignsFuture = campFuture;
        });
        await Future.wait([prodFuture, catFuture, campFuture]);
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
              child: _buildCampaignBanner(strings),
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

  // Üst Bar: Logo ("Marketim") + "📍 Konum seçin >" + 🔔 Zili
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

  // Fırsat / Kampanya Bannerı (Nane Yeşili Kart + Alışveriş Torbası & %50 İndirim Rozeti)
  Widget _buildCampaignBanner(AppStrings strings) {
    return FutureBuilder<List<Campaign>>(
      future: _campaignsFuture,
      builder: (context, snapshot) {
        final latestCampaign = (snapshot.hasData && snapshot.data!.isNotEmpty)
            ? snapshot.data!.first
            : null;

        return Column(
          children: [
            InkWell(
              onTap: () {
                setState(() => _selectedTab = 1);
              },
              borderRadius: BorderRadius.circular(22),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.fromLTRB(20, 18, 14, 18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: const LinearGradient(
                    colors: [Color(0xFFD6F5E3), Color(0xFFEAF8F0)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Row(
                  children: [
                    // Sol Metinler
                    Expanded(
                      flex: 6,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppConstants.primaryColor,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              latestCampaign?.badgeText.isNotEmpty == true
                                  ? latestCampaign!.badgeText
                                  : strings.weeklyDeals,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            latestCampaign != null
                                ? latestCampaign.title
                                : strings.freshDiscounts,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF134224),
                              height: 1.25,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                strings.exploreNow,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: AppConstants.primaryColor,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Sağ: Görsel ve Daire İndirim Rozeti
                    Expanded(
                      flex: 4,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: latestCampaign?.imageUrl != null
                                ? Image.network(
                                    latestCampaign!.imageUrl!,
                                    height: 100,
                                    width: double.infinity,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        _buildFallbackBannerArt(),
                                  )
                                : _buildFallbackBannerArt(),
                          ),
                          Positioned(
                            top: 0,
                            right: 0,
                            child: Container(
                              padding: const EdgeInsets.all(7),
                              decoration: const BoxDecoration(
                                color: Color(0xFF12522B),
                                shape: BoxShape.circle,
                              ),
                              child: Text(
                                strings.upToDiscount,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w900,
                                  height: 1.1,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Banner Sayfa Gösterge Noktaları
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 16,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppConstants.primaryColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    width: 6,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    width: 6,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFallbackBannerArt() {
    return Container(
      height: 95,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Center(
        child: Icon(
          Icons.shopping_basket_rounded,
          size: 52,
          color: AppConstants.primaryColor,
        ),
      ),
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
                itemCount: categories.length + 1, // +1 "Tümü" için
                itemBuilder: (context, index) {
                  final isAll = index == 0;
                  final category = isAll ? null : categories[index - 1];
                  final isSelected = isAll
                      ? _selectedCategoryId == null
                      : _selectedCategoryId == category?.id;

                  final title = isAll ? strings.all : category!.name;
                  final iconData = _getCategoryIcon(title);

                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: InkWell(
                      onTap: () {
                        _selectCategory(category?.id);
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
                                  ? AppConstants.primaryColor
                                      .withValues(alpha: 0.18)
                                  : const Color(0xFFE8F6ED),
                              shape: BoxShape.circle,
                              border: isSelected
                                  ? Border.all(
                                      color: AppConstants.primaryColor,
                                      width: 2,
                                    )
                                  : null,
                            ),
                            child: Icon(
                              iconData,
                              size: 28,
                              color: AppConstants.primaryColor,
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
                                    ? AppConstants.primaryColor
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
          ],
        );
      },
    );
  }

  IconData _getCategoryIcon(String categoryName) {
    final lower = categoryName.toLowerCase();
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            _selectedCategoryId != null
                ? strings.categories
                : strings.popularProducts,
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
        final query = _searchQuery.trim().toLowerCase();
        final filtered = query.isEmpty
            ? products
            : products.where((p) {
                return p.title.toLowerCase().contains(query) ||
                    p.description.toLowerCase().contains(query);
              }).toList();

        if (filtered.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(48),
              child: Center(
                child: Text(
                  strings.noSearchResults,
                  style: TextStyle(color: Colors.grey.shade600),
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

  // Modern Ürün Kartı (Ekrandakiyle Birebir Tasarım)
  Widget _buildModernProductCard(Product product) {
    final isFavorite = _favoriteProductIds.contains(product.id);
    final inCartQty = CartManager().quantityFor(product.id);

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
          // 1. Kartın Üstü: Kalp (Favori) İkonu
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
              onPressed: () {
                setState(() {
                  if (isFavorite) {
                    _favoriteProductIds.remove(product.id);
                  } else {
                    _favoriteProductIds.add(product.id);
                  }
                });
              },
            ),
          ),

          // 2. Ürün Fotoğrafı
          Expanded(
            child: InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ProductDetailScreen(product: product),
                ),
              ).then((_) => setState(() {})),
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
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

          // 3. Ürün Bilgileri ve Fiyat / Sepet Butonu
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // İsim
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

                // Birim (ör: "1 kg", "1 adet" veya açıklama)
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
                const SizedBox(height: 8),

                // Fiyat ve Sepete Ekle Butonu
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '₺${product.price.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                        color: AppConstants.primaryColor,
                      ),
                    ),

                    // Yeşil Yuvarlak Sepet Butonu
                    InkWell(
                      onTap: product.stock <= 0
                          ? null
                          : () {
                              CartManager().addItem(product);
                              setState(() {});
                              ScaffoldMessenger.of(context)
                                ..hideCurrentSnackBar()
                                ..showSnackBar(
                                  SnackBar(
                                    content: Text('${product.title} sepete eklendi!'),
                                    duration: const Duration(seconds: 1),
                                    behavior: SnackBarBehavior.floating,
                                    backgroundColor: AppConstants.primaryColor,
                                  ),
                                );
                            },
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: product.stock > 0
                              ? AppConstants.primaryColor
                              : Colors.grey.shade400,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            const Icon(
                              Icons.shopping_cart_outlined,
                              color: Colors.white,
                              size: 18,
                            ),
                            if (inCartQty > 0)
                              Positioned(
                                top: 2,
                                right: 2,
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: const BoxDecoration(
                                    color: Colors.amber,
                                    shape: BoxShape.circle,
                                  ),
                                  constraints: const BoxConstraints(
                                    minWidth: 12,
                                    minHeight: 12,
                                  ),
                                  child: Text(
                                    '$inCartQty',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.black,
                                      fontSize: 8,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
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
                  itemCount: categories.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final isAll = index == 0;
                    final category = isAll ? null : categories[index - 1];
                    final title = isAll ? strings.all : category!.name;
                    final isSelected = isAll
                        ? _selectedCategoryId == null
                        : _selectedCategoryId == category?.id;

                    return Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: BorderSide(
                          color: isSelected
                              ? AppConstants.primaryColor
                              : const Color(0xFFEEF0F2),
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      color: isSelected
                          ? AppConstants.primaryColor.withValues(alpha: 0.08)
                          : Colors.white,
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFFE8F6ED),
                          child: Icon(
                            _getCategoryIcon(title),
                            color: AppConstants.primaryColor,
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
                                ? AppConstants.primaryColor
                                : const Color(0xFF1E2022),
                          ),
                        ),
                        trailing: const Icon(
                          Icons.chevron_right,
                          color: Colors.grey,
                        ),
                        onTap: () {
                          _selectCategory(category?.id);
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

            if (isAuthenticated) ...[
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
