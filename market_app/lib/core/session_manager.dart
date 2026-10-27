import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'local_storage.dart';

class SessionManager extends ChangeNotifier {
  static final SessionManager instance = SessionManager._internal();
  factory SessionManager() => instance;
  SessionManager._internal();

  static const String _storageKey = 'auth_session';

  String? _token;
  Map<String, dynamic>? _user;

  String? get token => _token;
  Map<String, dynamic>? get user => _user;
  bool get isAuthenticated => _token != null && _token!.isNotEmpty;

  String get userName => _user?['name']?.toString() ?? 'Kullanıcı';
  String get userEmail => _user?['email']?.toString() ?? '';
  int? get userId => _user?['id'] is int ? _user!['id'] as int : null;

  void restoreSession() {
    final raw = LocalStorage.instance.read(_storageKey);
    if (raw is Map) {
      final savedToken = raw['token']?.toString();
      final savedUser = raw['user'];
      if (savedToken != null &&
          savedToken.isNotEmpty &&
          !_isJwtExpired(savedToken) &&
          savedUser is Map) {
        _token = savedToken;
        _user = Map<String, dynamic>.from(savedUser);
      } else {
        unawaited(LocalStorage.instance.remove(_storageKey));
      }
    }
  }

  bool _isJwtExpired(String jwtToken) {
    try {
      final parts = jwtToken.split('.');
      if (parts.length != 3) return false;
      final normalized = base64Url.normalize(parts[1]);
      final payloadStr = utf8.decode(base64Url.decode(normalized));
      final payload = jsonDecode(payloadStr);
      if (payload is Map && payload['exp'] is num) {
        final expiryMs = (payload['exp'] as num).toInt() * 1000;
        return DateTime.now().millisecondsSinceEpoch >= expiryMs;
      }
    } catch (_) {}
    return false;
  }

  void setSession({required String token, required Map<String, dynamic> user}) {
    _token = token;
    _user = user;
    unawaited(
      LocalStorage.instance.write(_storageKey, {'token': token, 'user': user}),
    );
    notifyListeners();
  }

  void clearSession() {
    _token = null;
    _user = null;
    unawaited(LocalStorage.instance.remove(_storageKey));
    notifyListeners();
  }

  Map<String, String> authHeaders({bool isJson = true}) {
    final headers = <String, String>{};
    if (isJson) {
      headers['Content-Type'] = 'application/json';
    }
    if (_token != null && _token!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $_token';
    }
    return headers;
  }
}
