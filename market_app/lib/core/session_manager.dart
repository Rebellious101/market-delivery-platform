import 'package:flutter/foundation.dart';

class SessionManager extends ChangeNotifier {
  static final SessionManager instance = SessionManager._internal();
  factory SessionManager() => instance;
  SessionManager._internal();

  String? _token;
  Map<String, dynamic>? _user;

  String? get token => _token;
  Map<String, dynamic>? get user => _user;
  bool get isAuthenticated => _token != null && _token!.isNotEmpty;

  String get userName => _user?['name']?.toString() ?? 'Kullanıcı';
  String get userEmail => _user?['email']?.toString() ?? '';
  int? get userId => _user?['id'] is int ? _user!['id'] as int : null;

  void setSession({required String token, required Map<String, dynamic> user}) {
    _token = token;
    _user = user;
    notifyListeners();
  }

  void clearSession() {
    _token = null;
    _user = null;
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
