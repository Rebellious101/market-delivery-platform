import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../core/session_manager.dart';
import 'auth_screen.dart';

class OrderHistoryScreen extends StatefulWidget {
  const OrderHistoryScreen({super.key});

  @override
  State<OrderHistoryScreen> createState() => _OrderHistoryScreenState();
}

class _OrderHistoryScreenState extends State<OrderHistoryScreen> {
  late Future<List<OrderHistory>> _ordersFuture;

  @override
  void initState() {
    super.initState();
    _ordersFuture = _fetchOrders();
  }

  Future<List<OrderHistory>> _fetchOrders() async {
    if (!SessionManager.instance.isAuthenticated) {
      throw Exception('Sipariş geçmişinizi görüntülemek için lütfen giriş yapın.');
    }

    try {
      final response = await http
          .get(
            Uri.parse('${AppConstants.baseUrl}/api/orders'),
            headers: SessionManager.instance.authHeaders(isJson: false),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 401) {
        throw Exception('Oturum süreniz dolmuş. Lütfen tekrar giriş yapın.');
      }

      if (response.statusCode != 200) {
        throw Exception('Siparişler yüklenemedi (${response.statusCode}).');
      }

      final body = json.decode(response.body) as List<dynamic>;
      return body
          .map((item) => OrderHistory.fromJson(item as Map<String, dynamic>))
          .toList();
    } on TimeoutException {
      throw Exception(
        'Sunucuya zamanında bağlanılamadı. Backend servisinin açık olduğunu kontrol edin.',
      );
    }
  }

  void _retry() {
    setState(() {
      _ordersFuture = _fetchOrders();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Geçmiş Siparişler'),
        backgroundColor: AppConstants.primaryColor,
        foregroundColor: AppConstants.textLight,
      ),
      body: FutureBuilder<List<OrderHistory>>(
        future: _ordersFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            final isAuthError = !SessionManager.instance.isAuthenticated ||
                snapshot.error.toString().contains('giriş') ||
                snapshot.error.toString().contains('Oturum');
            return _OrderHistoryMessage(
              icon: isAuthError ? Icons.lock_outline : Icons.cloud_off,
              message: isAuthError
                  ? 'Sipariş geçmişinizi görüntülemek için lütfen giriş yapın.'
                  : 'Siparişler yüklenemedi.\n${snapshot.error.toString().replaceFirst('Exception: ', '')}',
              action: isAuthError
                  ? FilledButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const AuthScreen()),
                        ).then((_) => _retry());
                      },
                      icon: const Icon(Icons.login),
                      label: const Text('Giriş Yap'),
                    )
                  : FilledButton.icon(
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Tekrar dene'),
                    ),
            );
          }

          final orders = snapshot.data ?? <OrderHistory>[];
          if (orders.isEmpty) {
            return const _OrderHistoryMessage(
              icon: Icons.receipt_long_outlined,
              message: 'Henüz verilmiş bir siparişiniz yok.',
            );
          }

          return RefreshIndicator(
            onRefresh: () async {
              final future = _fetchOrders();
              setState(() {
                _ordersFuture = future;
              });
              await future;
            },
            child: ListView.separated(
              padding: const EdgeInsets.all(AppConstants.defaultPadding),
              itemCount: orders.length,
              separatorBuilder: (_, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) => _OrderCard(order: orders[index]),
            ),
          );
        },
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order});

  final OrderHistory order;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppConstants.defaultRadius),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        leading: CircleAvatar(
          backgroundColor: AppConstants.primaryColor.withValues(alpha: 0.12),
          foregroundColor: AppConstants.primaryColor,
          child: const Icon(Icons.receipt_long),
        ),
        title: Row(
          children: [
            Text(
              'Sipariş #${order.id}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppConstants.primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                order.status,
                style: const TextStyle(
                  color: AppConstants.primaryColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(order.formattedDate),
              if (order.shippingAddress.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    'Adres: ${order.shippingAddress}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AppConstants.textSecondary),
                  ),
                ),
            ],
          ),
        ),
        trailing: Text(
          '${order.totalPrice.toStringAsFixed(2)} TL',
          style: const TextStyle(
            color: AppConstants.primaryColor,
            fontWeight: FontWeight.bold,
          ),
        ),
        children: [
          const Divider(height: 1),
          const SizedBox(height: 8),
          ...order.items.map(
            (item) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text('${item.quantity} adet'),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 78,
                    child: Text(
                      '${item.price.toStringAsFixed(2)} TL',
                      textAlign: TextAlign.end,
                      style: const TextStyle(fontWeight: FontWeight.w600),
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

class _OrderHistoryMessage extends StatelessWidget {
  const _OrderHistoryMessage({
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: AppConstants.textSecondary),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class OrderHistory {
  const OrderHistory({
    required this.id,
    required this.totalPrice,
    required this.createdAt,
    required this.items,
    this.status = 'Hazırlanıyor',
    this.shippingAddress = '',
  });

  final int id;
  final double totalPrice;
  final DateTime? createdAt;
  final List<OrderHistoryItem> items;
  final String status;
  final String shippingAddress;

  factory OrderHistory.fromJson(Map<String, dynamic> json) {
    return OrderHistory(
      id: (json['order_id'] as num).toInt(),
      totalPrice: double.parse(json['total_price'].toString()),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      status: json['status']?.toString() ?? 'Hazırlanıyor',
      shippingAddress: json['shipping_address']?.toString() ?? '',
      items: (json['items'] as List<dynamic>? ?? [])
          .map(
            (item) => OrderHistoryItem.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
    );
  }

  String get formattedDate {
    if (createdAt == null) return 'Tarih bilgisi yok';
    final date = createdAt!;
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}  ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}

class OrderHistoryItem {
  const OrderHistoryItem({
    required this.name,
    required this.quantity,
    required this.price,
  });

  final String name;
  final int quantity;
  final double price;

  factory OrderHistoryItem.fromJson(Map<String, dynamic> json) {
    return OrderHistoryItem(
      name: json['name'] as String? ?? 'Ürün',
      quantity: (json['quantity'] as num).toInt(),
      price: double.parse(json['price'].toString()),
    );
  }
}
