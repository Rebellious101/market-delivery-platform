import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:http/http.dart' as http;

import 'core/constants.dart';
import 'core/local_storage.dart';
import 'core/localization.dart';
import 'screen/auth_screen.dart';
import 'models/campaign_model.dart';
import 'models/category_model.dart';
import 'models/product_model.dart';
import 'screen/product_detail_screen.dart';
import 'screen/cart_screen.dart'; // Sepet ekranını içe aktardık
import 'screen/cart_manager.dart';
import 'screen/delivery_address_screen.dart';
import 'screen/address_book.dart';
import 'core/session_manager.dart';
import 'screen/order_history_screen.dart';

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
          primaryColor: AppConstants.primaryColor,
          scaffoldBackgroundColor: AppConstants.backgroundColor,
          colorScheme: ColorScheme.fromSeed(
            seedColor: AppConstants.primaryColor,
            secondary: AppConstants.secondaryColor,
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
  bool _hasLoadedCategories = false;
  int? _selectedCategoryId;
  int _selectedTab = 0;
  String _searchQuery = '';
  Timer? _searchDebounce;

  void _onAddressBookChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _productsFuture = _fetchProducts();
    _campaignsFuture = _fetchCampaigns();
    unawaited(AddressBook.instance.fetchUserAddresses());
    AddressBook.instance.addListener(_onAddressBookChanged);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    AddressBook.instance.removeListener(_onAddressBookChanged);
    super.dispose();
  }

  // Flask API'den ürünleri çeken fonksiyon
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
        'Sunucuya zamanında bağlanılamadı. Backend servisinin açık olduğunu kontrol edin.',
      );
    }
  }

  Future<List<Category>> _fetchCategories() async {
    final response = await http
        .get(Uri.parse('${AppConstants.baseUrl}/api/categories'))
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception('Kategoriler yüklenemedi (${response.statusCode}).');
    }

    final body = json.decode(response.body) as List<dynamic>;
    return body
        .map((item) => Category.fromJson(item as Map<String, dynamic>))
        .toList();
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

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _editDeliveryAddress,
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 230),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.location_on, size: 20),
                  const SizedBox(width: 7),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          strings.deliveryAddress,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            letterSpacing: .5,
                          ),
                        ),
                        Text(
                          AddressBook.instance.selectedAddress != null
                              ? '${AddressBook.instance.selectedAddress!.title} - ${AddressBook.instance.selectedAddress!.fullText}'
                              : strings.addAddress,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 5),
                  const Icon(Icons.keyboard_arrow_down, size: 18),
                ],
              ),
            ),
          ),
        ),
        centerTitle: true,
        backgroundColor: AppConstants.primaryColor,
        foregroundColor: AppConstants.textLight,
        actions: [
          ListenableBuilder(
            listenable: SessionManager.instance,
            builder: (context, _) {
              if (SessionManager.instance.isAuthenticated) {
                return PopupMenuButton<String>(
                  tooltip: 'Hesabım (${SessionManager.instance.userName})',
                  icon: CircleAvatar(
                    radius: 14,
                    backgroundColor: Colors.white,
                    child: Text(
                      SessionManager.instance.userName.isNotEmpty
                          ? SessionManager.instance.userName[0].toUpperCase()
                          : 'U',
                      style: const TextStyle(
                        color: AppConstants.primaryColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  onSelected: (value) {
                    if (value == 'orders') {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const OrderHistoryScreen(),
                        ),
                      );
                    } else if (value == 'logout') {
                      if (widget.onLogout != null) {
                        widget.onLogout!();
                      } else {
                        SessionManager.instance.clearSession();
                        AddressBook.instance.clear();
                      }
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      enabled: false,
                      child: Text(
                        SessionManager.instance.userName,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'orders',
                      child: Row(
                        children: [
                          Icon(Icons.receipt_long, size: 18),
                          SizedBox(width: 8),
                          Text('Sipariş Geçmişim'),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'logout',
                      child: Row(
                        children: [
                          Icon(Icons.logout, size: 18, color: Colors.red),
                          SizedBox(width: 8),
                          Text(
                            'Çıkış Yap',
                            style: TextStyle(color: Colors.red),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              } else {
                return IconButton(
                  tooltip: 'Giriş Yap',
                  icon: const Icon(Icons.account_circle_outlined),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AuthScreen()),
                    );
                  },
                );
              }
            },
          ),
          PopupMenuButton<String>(
            tooltip: strings.language,
            icon: const Icon(Icons.language),
            onSelected: AppLanguage.instance.setCode,
            itemBuilder: (context) => [
              PopupMenuItem(value: 'tr', child: Text(strings.turkish)),
              PopupMenuItem(value: 'en', child: Text(strings.english)),
            ],
          ),
        ],
      ),
      body: _buildCurrentPage(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        onDestinationSelected: (index) {
          if (index == 2) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const CartScreen()),
            ).then((_) => _retryLoadingProducts());
            return;
          }
          setState(() {
            _selectedTab = index;
            if (index == 1 && !_hasLoadedCategories) {
              _hasLoadedCategories = true;
              _categoriesFuture = _fetchCategories();
            } else if (index == 3) {
              _campaignsFuture = _fetchCampaigns();
            }
          });
        },
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.home_outlined),
            selectedIcon: const Icon(Icons.home),
            label: strings.home,
          ),
          NavigationDestination(
            icon: const Icon(Icons.category_outlined),
            selectedIcon: const Icon(Icons.category),
            label: strings.categories,
          ),
          NavigationDestination(
            icon: _buildCartIcon(Icons.shopping_bag_outlined),
            selectedIcon: _buildCartIcon(Icons.shopping_bag),
            label: strings.cart,
          ),
          NavigationDestination(
            icon: const Icon(Icons.local_offer_outlined),
            selectedIcon: const Icon(Icons.local_offer),
            label: strings.campaigns,
          ),
        ],
      ),
    );
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

  Widget _buildCartIcon(IconData icon) {
    return ListenableBuilder(
      listenable: CartManager(),
      builder: (context, _) {
        final total = CartManager().totalPrice;
        return Badge(
          isLabelVisible: total > 0,
          label: Text('${total.toStringAsFixed(0)} TL'),
          alignment: AlignmentDirectional.topEnd,
          offset: const Offset(8, -5),
          child: Icon(icon),
        );
      },
    );
  }

  Widget _buildCurrentPage() {
    switch (_selectedTab) {
      case 1:
        return _buildCategoriesPage();
      case 3:
        return _buildCampaignsPage();
      default:
        return _buildProductsPage();
    }
  }

  Widget _buildProductsPage() {
    final strings = AppStrings.of(context);
    return Padding(
      padding: const EdgeInsets.all(AppConstants.defaultPadding),
      child: FutureBuilder<List<Product>>(
        future: _productsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
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
                  ),
                ],
              ),
            );
          }
          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return const Center(child: Text('Hiç ürün bulunamadı.'));
          }

          final products = snapshot.data!;
          final normalizedQuery = _searchQuery.trim().toLowerCase();
          final filteredProducts = normalizedQuery.isEmpty
              ? products
              : products.where((product) {
                  return product.title.toLowerCase().contains(
                        normalizedQuery,
                      ) ||
                      product.description.toLowerCase().contains(
                        normalizedQuery,
                      );
                }).toList();

          return Column(
            children: [
              _buildPromoBanner(strings),
              const SizedBox(height: 14),
              _buildSearchField(),
              const SizedBox(height: 12),
              if (filteredProducts.isEmpty)
                Expanded(child: Center(child: Text(strings.noSearchResults)))
              else
                Expanded(
                  child: GridView.builder(
                    itemCount: filteredProducts.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 0.75,
                        ),
                    itemBuilder: (context, index) {
                      final product = filteredProducts[index];
                      final quantity = CartManager().quantityFor(product.id);
                      return Card(
                        elevation: 2,
                        clipBehavior: Clip.antiAlias,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            AppConstants.defaultRadius,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: InkWell(
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        ProductDetailScreen(product: product),
                                  ),
                                ).then((_) => setState(() {})),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Image.network(
                                        product.imageUrl,
                                        width: double.infinity,
                                        fit: BoxFit.cover,
                                        errorBuilder:
                                            (context, error, stackTrace) =>
                                                const Center(
                                                  child: Icon(
                                                    Icons.image_not_supported,
                                                  ),
                                                ),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        8,
                                        8,
                                        8,
                                        4,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            product.title,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 14,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            '${product.price.toStringAsFixed(2)} TL',
                                            style: const TextStyle(
                                              color: AppConstants.primaryColor,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 15,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            _ProductQuantityControls(
                              product: product,
                              quantity: quantity,
                              onChanged: () => setState(() {}),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSearchField() {
    final strings = AppStrings.of(context);
    return TextField(
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
        hintText: strings.searchProducts,
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _searchQuery.isEmpty
            ? null
            : IconButton(
                onPressed: () {
                  setState(() {
                    _searchQuery = '';
                  });
                },
                icon: const Icon(Icons.clear),
                tooltip: strings.clearSearch,
              ),
        filled: true,
        fillColor: AppConstants.surfaceColor,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppConstants.defaultRadius),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildPromoBanner(AppStrings strings) {
    return FutureBuilder<List<Campaign>>(
      future: _campaignsFuture,
      builder: (context, snapshot) {
        final latestCampaign = (snapshot.hasData && snapshot.data!.isNotEmpty)
            ? snapshot.data!.first
            : null;

        final bannerTitle = latestCampaign != null
            ? latestCampaign.title
            : (strings.isEnglish
                  ? 'Fast & Fresh Delivery'
                  : 'Hızlı & Taze Teslimat');
        final bannerDesc =
            (latestCampaign != null && latestCampaign.description.isNotEmpty)
            ? latestCampaign.description
            : strings.campaignsDescription;

        return InkWell(
          onTap: () {
            setState(() {
              _selectedTab = 3;
              _campaignsFuture = _fetchCampaigns();
            });
          },
          borderRadius: BorderRadius.circular(AppConstants.defaultRadius),
          child: Container(
            width: double.infinity,
            constraints: const BoxConstraints(minHeight: 132),
            padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
            decoration: BoxDecoration(
              color: AppConstants.primaryColor,
              borderRadius: BorderRadius.circular(AppConstants.defaultRadius),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (latestCampaign != null &&
                          latestCampaign.badgeText.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.22),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            latestCampaign.badgeText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],
                      Text(
                        bannerTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        bannerDesc,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.local_offer,
                    color: Colors.white,
                    size: 32,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCategoriesPage() {
    final strings = AppStrings.of(context);
    return FutureBuilder<List<Category>>(
      future: _categoriesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Text(
              '${strings.categories} yüklenemedi.\n${snapshot.error}',
            ),
          );
        }

        final categories = snapshot.data ?? <Category>[];
        return ListView(
          padding: const EdgeInsets.all(AppConstants.defaultPadding),
          children: [
            ListTile(
              leading: const Icon(Icons.apps),
              title: Text(strings.all),
              selected: _selectedCategoryId == null,
              selectedTileColor: AppConstants.primaryColor.withValues(
                alpha: 0.12,
              ),
              onTap: () {
                _selectCategory(null);
                setState(() => _selectedTab = 0);
              },
            ),
            const Divider(height: 20),
            ...categories.map(
              (category) => ListTile(
                leading: const Icon(Icons.category_outlined),
                title: Text(category.name),
                selected: _selectedCategoryId == category.id,
                selectedTileColor: AppConstants.primaryColor.withValues(
                  alpha: 0.12,
                ),
                onTap: () {
                  _selectCategory(category.id);
                  setState(() => _selectedTab = 0);
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCampaignsPage() {
    final strings = AppStrings.of(context);
    return FutureBuilder<List<Campaign>>(
      future: _campaignsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
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
                    size: 48,
                    color: AppConstants.textSecondary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Kampanyalar yüklenemedi.\n${snapshot.error.toString().replaceFirst('Exception: ', '')}',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () {
                      setState(() {
                        _campaignsFuture = _fetchCampaigns();
                      });
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Tekrar dene'),
                  ),
                ],
              ),
            ),
          );
        }

        final campaigns = snapshot.data ?? <Campaign>[];
        if (campaigns.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.local_offer_outlined,
                    size: 64,
                    color: AppConstants.secondaryColor,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    strings.campaignsSoon,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    strings.campaignsDescription,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() {
                        _campaignsFuture = _fetchCampaigns();
                      });
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Yenile'),
                  ),
                ],
              ),
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () async {
            final future = _fetchCampaigns();
            setState(() {
              _campaignsFuture = future;
            });
            await future;
          },
          child: ListView.separated(
            padding: const EdgeInsets.all(AppConstants.defaultPadding),
            itemCount: campaigns.length,
            separatorBuilder: (_, index) => const SizedBox(height: 14),
            itemBuilder: (context, index) {
              final campaign = campaigns[index];
              return Card(
                clipBehavior: Clip.antiAlias,
                elevation: 2,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(
                    AppConstants.defaultRadius,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (campaign.imageUrl != null)
                      SizedBox(
                        width: double.infinity,
                        height: 160,
                        child: Image.network(
                          campaign.imageUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) =>
                              Container(
                                color: AppConstants.primaryColor.withValues(
                                  alpha: 0.1,
                                ),
                                alignment: Alignment.center,
                                child: const Icon(
                                  Icons.local_offer,
                                  size: 48,
                                  color: AppConstants.primaryColor,
                                ),
                              ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.local_offer,
                                size: 20,
                                color: AppConstants.primaryColor,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  campaign.title,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              if (campaign.badgeText.isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppConstants.secondaryColor
                                        .withValues(alpha: 0.16),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    campaign.badgeText,
                                    style: const TextStyle(
                                      color: AppConstants.secondaryColor,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          if (campaign.description.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              campaign.description,
                              style: const TextStyle(
                                color: AppConstants.textSecondary,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _ProductQuantityControls extends StatelessWidget {
  const _ProductQuantityControls({
    required this.product,
    required this.quantity,
    required this.onChanged,
  });

  final Product product;
  final int quantity;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final cart = CartManager();
    final hasStock = product.stock > 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 8),
      child: Row(
        children: [
          _QuantityIconButton(
            icon: Icons.remove,
            tooltip: 'Miktarı azalt',
            onPressed: quantity == 0
                ? null
                : () {
                    cart.decreaseQuantity(product.id);
                    onChanged();
                  },
          ),
          Expanded(
            child: Text(
              quantity == 0 ? 'Sepete ekle' : '$quantity adet',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: quantity == 0
                    ? AppConstants.textSecondary
                    : AppConstants.primaryColor,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          _QuantityIconButton(
            icon: Icons.add,
            tooltip: 'Miktarı artır',
            onPressed: !hasStock || quantity >= product.stock
                ? null
                : () {
                    cart.addItem(product);
                    onChanged();
                  },
          ),
        ],
      ),
    );
  }
}

class _QuantityIconButton extends StatelessWidget {
  const _QuantityIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton.filledTonal(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
