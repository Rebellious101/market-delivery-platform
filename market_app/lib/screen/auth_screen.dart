import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../core/localization.dart';
import '../core/session_manager.dart';
import '../main.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, this.onContinueAsGuest});

  final VoidCallback? onContinueAsGuest;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLogin = true;
  bool _isLoading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _responseErrorMessage(http.Response response) {
    try {
      final decoded = json.decode(response.body);
      if (decoded is Map) {
        for (final key in const ['message', 'error', 'detail']) {
          final value = decoded[key]?.toString().trim();
          if (value != null && value.isNotEmpty) return value;
        }
      }
    } on FormatException {
      // Use the status-specific fallback when the response isn't JSON.
    }

    return switch (response.statusCode) {
      400 => 'İstek geçersiz. Girdiğiniz bilgileri kontrol edin.',
      401 => 'E-posta veya şifre hatalı.',
      403 => 'Bu işlem için yetkiniz bulunmuyor.',
      404 => 'Kimlik doğrulama servisi bulunamadı.',
      409 => 'Bu e-posta adresi zaten kayıtlı.',
      >= 500 => 'Sunucuda bir hata oluştu. Lütfen daha sonra tekrar deneyin.',
      _ => 'İşlem tamamlanamadı (HTTP ${response.statusCode}).',
    };
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: AppConstants.errorColor,
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    final payload = {
      if (!_isLogin) 'name': _nameController.text.trim(),
      'email': _emailController.text.trim(),
      'password': _passwordController.text,
    };

    try {
      final response = await http
          .post(
            Uri.parse(
              '${AppConstants.baseUrl}/api/auth/${_isLogin ? 'login' : 'register'}',
            ),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(payload),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final responseData = json.decode(response.body);
        final token = responseData['token']?.toString() ?? '';
        final user = responseData['user'] as Map<String, dynamic>? ?? {};
        if (token.isEmpty) {
          throw Exception('Sunucu oturum anahtarı döndürmedi.');
        }
        SessionManager.instance.setSession(token: token, user: user);
        if (!mounted) return;
        if (Navigator.of(context).canPop()) Navigator.of(context).pop();
        return;
      }

      _showErrorSnackBar(_responseErrorMessage(response));
    } on SocketException {
      _showErrorSnackBar(
        'Sunucuya bağlanılamadı, lütfen internetinizi ve backend servisini kontrol edin.',
      );
    } on TimeoutException {
      _showErrorSnackBar(
        'Sunucuya bağlanılamadı, lütfen internetinizi ve backend servisini kontrol edin.',
      );
    } on http.ClientException {
      _showErrorSnackBar(
        'Sunucuya bağlanılamadı, lütfen internetinizi ve backend servisini kontrol edin.',
      );
    } on FormatException {
      _showErrorSnackBar('Sunucudan geçersiz bir yanıt alındı.');
    } catch (error) {
      _showErrorSnackBar(error.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _continueAsGuest() {
    if (widget.onContinueAsGuest != null) {
      widget.onContinueAsGuest!();
      return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const MarketHomePage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: PopupMenuButton<String>(
                        tooltip: strings.language,
                        icon: const Icon(Icons.language),
                        onSelected: AppLanguage.instance.setCode,
                        itemBuilder: (context) => [
                          PopupMenuItem(
                            value: 'tr',
                            child: Text(strings.turkish),
                          ),
                          PopupMenuItem(
                            value: 'en',
                            child: Text(strings.english),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 72,
                      height: 72,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppConstants.primaryColor,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(
                        Icons.shopping_basket_outlined,
                        size: 38,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      _isLogin
                          ? (strings.isEnglish
                                ? 'Welcome back'
                                : 'Tekrar hoş geldin')
                          : (strings.isEnglish
                                ? 'Create your account'
                                : 'Hesabını oluştur'),
                      style: const TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: AppConstants.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isLogin
                          ? (strings.isEnglish
                                ? 'Continue shopping where you left off.'
                                : 'Alışverişe kaldığın yerden devam et.')
                          : (strings.isEnglish
                                ? 'Track your favorite products more easily.'
                                : 'Favori ürünlerini daha kolay takip et.'),
                      style: const TextStyle(color: AppConstants.textSecondary),
                    ),
                    const SizedBox(height: 28),
                    if (!_isLogin) ...[
                      TextFormField(
                        controller: _nameController,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: strings.isEnglish
                              ? 'Full name'
                              : 'Ad soyad',
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return strings.isEnglish
                                ? 'Full name is required.'
                                : 'Ad soyad zorunludur.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),
                    ],
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: strings.isEnglish ? 'Email' : 'E-posta',
                        prefixIcon: Icon(Icons.email_outlined),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return strings.isEnglish
                              ? 'Email is required.'
                              : 'E-posta zorunludur.';
                        }
                        if (!value.contains('@')) {
                          return strings.isEnglish
                              ? 'Enter a valid email.'
                              : 'Geçerli bir e-posta girin.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: strings.isEnglish ? 'Password' : 'Şifre',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: (value) => value == null || value.length < 6
                          ? (strings.isEnglish
                                ? 'Password must be at least 6 characters.'
                                : 'Şifre en az 6 karakter olmalıdır.')
                          : null,
                    ),
                    const SizedBox(height: 22),
                    SizedBox(
                      height: 52,
                      child: FilledButton(
                        onPressed: _isLoading ? null : _submit,
                        child: _isLoading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.5,
                                ),
                              )
                            : Text(
                                _isLogin
                                    ? (strings.isEnglish
                                          ? 'Log in'
                                          : 'Giriş yap')
                                    : (strings.isEnglish
                                          ? 'Register'
                                          : 'Kayıt ol'),
                              ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextButton(
                      onPressed: _isLoading
                          ? null
                          : () => setState(() {
                              _isLogin = !_isLogin;
                              _formKey.currentState?.reset();
                            }),
                      child: Text(
                        _isLogin
                            ? (strings.isEnglish
                                  ? "Don't have an account? Register"
                                  : 'Hesabın yok mu? Kayıt ol')
                            : (strings.isEnglish
                                  ? 'Already have an account? Log in'
                                  : 'Zaten hesabın var mı? Giriş yap'),
                      ),
                    ),
                    TextButton(
                      onPressed: _isLoading ? null : _continueAsGuest,
                      child: Text(
                        strings.isEnglish
                            ? 'Continue as guest'
                            : 'Misafir olarak devam et',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
