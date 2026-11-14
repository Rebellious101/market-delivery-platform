import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../core/localization.dart';
import '../core/session_manager.dart';
import '../firebase_options.dart';
import '../main.dart';
import 'address_book.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, this.onContinueAsGuest});

  final VoidCallback? onContinueAsGuest;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  bool _isLoading = false;
  String? _verificationId;
  int? _resendToken;
  String _sentPhoneNumber = '';
  Timer? _countdownTimer;
  int _countdownSeconds = 90; // 1.5 dakika

  static const Color _darkGreen = Color(0xFF1E5E3A);
  static const Color _fieldFill = Color(0xFFF5F8FB);
  static const Color _fieldBorder = Color(0xFFE2E8F0);
  static const Color _hintColor = Color(0xFF94A3B8);

  bool get _isCodeSent => _verificationId != null;

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _nameController.dispose();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownSeconds = 90; // 1.5 dakika
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_countdownSeconds > 1) {
        setState(() => _countdownSeconds--);
      } else {
        timer.cancel();
        setState(() {
          _countdownSeconds = 0;
          _verificationId = null;
          _codeController.clear();
        });
        _showErrorSnackBar(
          '1.5 dakikalık doğrulama süresi doldu. Lütfen tekrar kod talep edin.',
        );
      }
    });
  }

  String _formatTimer(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
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
      // JSON değilse durum koduna göre varsayılan mesaj döndürülür.
    }

    return switch (response.statusCode) {
      400 => 'İstek geçersiz. Girdiğiniz bilgileri kontrol edin.',
      401 => 'Doğrulama anahtarı geçersiz veya süresi dolmuş.',
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

  Future<bool> _ensureFirebaseReady() async {
    if (Firebase.apps.isNotEmpty) return true;
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      return Firebase.apps.isNotEmpty;
    } catch (_) {
      if (!mounted) return false;
      final en = AppStrings.of(context).isEnglish;
      _showErrorSnackBar(
        en
            ? 'Firebase is not configured for this device.'
            : 'Firebase bu cihaz için yapılandırılamadı.',
      );
      return false;
    }
  }

  /// Kullanıcının yazdığı numarayı E.164 formatına çevirir (örn. +905321234567).
  /// Kabul edilen girişler: 5321234567, 05321234567, 905321234567,
  /// +90 532 123 45 67, +90 0532 123 45 67, 00905321234567.
  String _normalizePhoneNumber(String raw) {
    var digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('00')) digits = digits.substring(2);

    // Türkiye / KKTC (+90): ülke kodundan sonra yazılan fazladan 0'ı temizle.
    if (digits.startsWith('90') && digits.length > 10) {
      final rest = digits.substring(2).replaceFirst(RegExp(r'^0+'), '');
      return '+90$rest';
    }
    if (digits.startsWith('0')) {
      return '+90${digits.replaceFirst(RegExp(r'^0+'), '')}';
    }
    if (digits.length == 10) return '+90$digits';
    return '+$digits';
  }

  bool _isValidE164(String phone) {
    if (phone.startsWith('+90')) {
      return RegExp(r'^\+90[2-5]\d{9}$').hasMatch(phone);
    }
    return RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(phone);
  }

  Future<void> _exchangeFirebaseIdToken(String idToken, {String? name}) async {
    final displayName = (name ?? _nameController.text).trim();
    final phoneNum = _sentPhoneNumber.isNotEmpty
        ? _sentPhoneNumber
        : _phoneController.text.trim();
    final response = await http
        .post(
          Uri.parse('${AppConstants.baseUrl}/api/auth/firebase'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'id_token': idToken,
            if (displayName.isNotEmpty) 'name': displayName,
            if (phoneNum.isNotEmpty) 'phone': phoneNum,
          }),
        )
        .timeout(const Duration(seconds: 12));

    if (response.statusCode == 200 || response.statusCode == 201) {
      final responseData = json.decode(response.body);
      final token = responseData['token']?.toString() ?? '';
      final user = responseData['user'] as Map<String, dynamic>? ?? {};
      if (token.isEmpty) {
        throw Exception('Sunucu oturum anahtarı döndürmedi.');
      }
      SessionManager.instance.setSession(token: token, user: user);
      unawaited(AddressBook.instance.fetchUserAddresses());
      if (!mounted) return;
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
      return;
    }

    throw Exception(_responseErrorMessage(response));
  }

  String _firebaseAuthErrorMessage(FirebaseAuthException error, bool en) {
    return switch (error.code) {
      'invalid-verification-code' =>
        en
            ? 'The 6-digit verification code you entered is incorrect. Please check and try again.'
            : 'Girdiğiniz 6 haneli doğrulama kodu hatalıdır. Lütfen kontrol edip tekrar deneyin.',
      'session-expired' || 'invalid-verification-id' =>
        en
            ? 'The verification code has expired. Please try again.'
            : 'Doğrulama kodunun geçerlilik süresi dolmuştur. Lütfen tekrar deneyin.',
      'quota-exceeded' =>
        en
            ? 'SMS limit exceeded. Please try again later.'
            : 'SMS gönderim limiti aşıldı. Lütfen daha sonra tekrar deneyin.',
      'email-already-in-use' =>
        en
            ? 'An account already exists for this email. Please sign in.'
            : 'Bu e-posta adresiyle kayıtlı bir hesap var. Lütfen giriş yapın.',
      'invalid-email' =>
        en
            ? 'Please enter a valid email address.'
            : 'Geçerli bir e-posta adresi girin.',
      'weak-password' =>
        en
            ? 'Choose a stronger password (at least 6 characters).'
            : 'Daha güçlü bir şifre seçin (en az 6 karakter).',
      'user-not-found' || 'wrong-password' || 'invalid-credential' =>
        en
            ? 'Information entered is incorrect. Please try again.'
            : 'Girdiğiniz bilgiler hatalı. Lütfen kontrol edip tekrar deneyin.',
      'account-exists-with-different-credential' =>
        en
            ? 'This email is already registered with another sign-in method.'
            : 'Bu e-posta başka bir giriş yöntemiyle kayıtlı.',
      'operation-not-allowed' =>
        en
            ? 'This sign-in method is not enabled in Firebase.'
            : 'Bu giriş yöntemi Firebase ayarlarında etkin değil.',
      'too-many-requests' =>
        en
            ? 'Too many attempts. Please try again later.'
            : 'Çok fazla deneme yapıldı. Lütfen bir süre bekleyip tekrar deneyin.',
      'app-not-authorized' || 'missing-client-identifier' =>
        en
            ? 'App signature (SHA-1/SHA-256) is not authorized in Firebase.'
            : 'Uygulama imzası (SHA-1/SHA-256) Firebase üzerinde yetkilendirilmemiş.',
      'captcha-check-failed' =>
        en
            ? 'reCAPTCHA verification failed. Please try again.'
            : 'reCAPTCHA doğrulaması başarısız oldu. Lütfen tekrar deneyin.',
      'network-request-failed' =>
        en
            ? 'Check your internet connection and try again.'
            : 'İnternet bağlantınızı kontrol edip tekrar deneyin.',
      _ =>
        '${error.message ?? (en ? 'Authentication failed.' : 'Kimlik doğrulama başarısız oldu.')} (${error.code})',
    };
  }

  Future<void> _sendVerificationCode() async {
    if (!_formKey.currentState!.validate()) return;
    if (!await _ensureFirebaseReady()) return;

    final normalizedPhone = _normalizePhoneNumber(_phoneController.text);
    setState(() => _isLoading = true);

    try {
      // Firebase'in göndereceği SMS dilini kullanıcının seçtiği dil ile eşitle
      final currentLang = AppLanguage.instance.code;
      await FirebaseAuth.instance.setLanguageCode(currentLang);

      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: normalizedPhone,
        forceResendingToken: _resendToken,
        verificationCompleted: (PhoneAuthCredential credential) {
          // Android cihazlarda SMS geldiğinde otomatik giriş yapılmasını engeller;
          // kullanıcının 6 haneli kodu kendisinin girip "Doğrula ve Giriş Yap"a
          // basmasını bekler.
        },
        verificationFailed: (FirebaseAuthException e) {
          if (mounted) setState(() => _isLoading = false);
          _countdownTimer?.cancel();
          final en = AppStrings.of(context).isEnglish;
          _showErrorSnackBar(_firebaseAuthErrorMessage(e, en));
        },
        codeSent: (String verId, int? resendToken) {
          if (!mounted) return;
          setState(() {
            _verificationId = verId;
            _resendToken = resendToken;
            _sentPhoneNumber = normalizedPhone;
            _codeController.clear();
            _isLoading = false;
          });
          _startCountdown();
        },
        codeAutoRetrievalTimeout: (String verId) {
          _verificationId ??= verId;
        },
      );
    } on SocketException {
      if (mounted) setState(() => _isLoading = false);
      _showErrorSnackBar('İnternet bağlantınızı kontrol edin.');
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
      _showErrorSnackBar(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _verifySmsCode() async {
    final en = AppStrings.of(context).isEnglish;
    final code = _codeController.text.trim();
    if (_countdownSeconds <= 0 || _verificationId == null) {
      _showErrorSnackBar(
        en
            ? 'Verification time expired. Please request a new code.'
            : '1.5 dakikalık doğrulama süresi dolmuştur. Lütfen tekrar deneyin.',
      );
      return;
    }
    if (code.length != 6) {
      _showErrorSnackBar(
        en
            ? 'Please enter the 6-digit verification code.'
            : 'Lütfen 6 haneli doğrulama kodunu eksiksiz girin.',
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: _verificationId!,
        smsCode: code,
      );
      final userCred = await FirebaseAuth.instance.signInWithCredential(
        credential,
      );
      final idToken = await userCred.user?.getIdToken();
      if (idToken == null || idToken.isEmpty) {
        throw Exception('Doğrulama anahtarı alınamadı.');
      }
      _countdownTimer?.cancel();
      await _exchangeFirebaseIdToken(idToken);
    } on FirebaseAuthException catch (e) {
      _showErrorSnackBar(_firebaseAuthErrorMessage(e, en));
    } on SocketException {
      _showErrorSnackBar('Sunucuya bağlanılamadı, internetinizi kontrol edin.');
    } on TimeoutException {
      _showErrorSnackBar('Sunucu yanıt vermedi, lütfen tekrar deneyin.');
    } catch (e) {
      _showErrorSnackBar(e.toString().replaceFirst('Exception: ', ''));
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

  InputDecoration _fieldDecoration({
    required String hint,
    required IconData icon,
  }) {
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: color, width: width),
        );

    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: _hintColor, fontSize: 14),
      prefixIcon: Icon(icon, color: _hintColor, size: 20),
      filled: true,
      fillColor: _fieldFill,
      counterText: '',
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      border: border(_fieldBorder),
      enabledBorder: border(_fieldBorder),
      focusedBorder: border(AppConstants.primaryColor, 1.4),
      errorBorder: border(AppConstants.errorColor),
      focusedErrorBorder: border(AppConstants.errorColor, 1.4),
    );
  }

  Widget _fieldLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppConstants.textPrimary,
        ),
      ),
    );
  }

  Widget _buildTopRow(AppStrings strings) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFE9F8EF),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFCDEFD9)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  color: Color(0xFF34C77B),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                strings.isEnglish ? 'FRESH & FAST' : 'TAZE & HIZLI',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  color: _darkGreen,
                ),
              ),
            ],
          ),
        ),
        PopupMenuButton<String>(
          tooltip: strings.language,
          onSelected: AppLanguage.instance.setCode,
          position: PopupMenuPosition.under,
          itemBuilder: (context) => [
            PopupMenuItem(value: 'tr', child: Text(strings.turkish)),
            PopupMenuItem(value: 'en', child: Text(strings.english)),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _fieldBorder),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.language,
                  size: 15,
                  color: AppConstants.textSecondary,
                ),
                const SizedBox(width: 5),
                Text(
                  strings.isEnglish ? 'EN' : 'TR',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppConstants.textPrimary,
                  ),
                ),
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: _hintColor,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBrand(AppStrings strings) {
    return Column(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF2E8B57), _darkGreen],
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: _darkGreen.withValues(alpha: 0.28),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Icon(
            Icons.shopping_basket_outlined,
            size: 28,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'Prestij',
                    style: TextStyle(color: AppConstants.textPrimary),
                  ),
                  TextSpan(
                    text: 'Market',
                    style: TextStyle(color: AppConstants.primaryColor),
                  ),
                ],
              ),
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFDDF6E6),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                strings.isEnglish ? 'ONLINE' : 'ONLİNE',
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  color: _darkGreen,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppLanguage.instance,
      builder: (context, _) {
        final strings = AppStrings.of(context);
        final en = strings.isEnglish;

        return Scaffold(
      backgroundColor: const Color(0xFFEFF3F8),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Container(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 24),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(32),
                  gradient: const LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment(0, -0.2),
                    colors: [Color(0xFFE8FAF0), Colors.white],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 30,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildTopRow(strings),
                      const SizedBox(height: 18),
                      _buildBrand(strings),
                      const SizedBox(height: 26),

                      // Başlık
                      Text(
                        _isCodeSent
                            ? (en ? 'Verify your phone' : 'Doğrulama Kodu')
                            : (en ? 'Welcome' : 'Hoş geldiniz'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 23,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _isCodeSent
                            ? (en
                                  ? 'Enter the 6-digit SMS code sent to $_sentPhoneNumber'
                                  : '$_sentPhoneNumber numarasına gönderilen 6 haneli SMS kodunu girin.')
                            : (en
                                  ? 'Enter your phone number to start ordering.'
                                  : 'Sipariş vermek için telefon numaranızla hızlıca giriş yapın.'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 13.5,
                          color: AppConstants.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 24),

                      if (!_isCodeSent) ...[
                        _fieldLabel(en ? 'Full name' : 'Ad Soyad'),
                        TextFormField(
                          controller: _nameController,
                          textInputAction: TextInputAction.next,
                          decoration: _fieldDecoration(
                            hint: en ? 'John Doe' : 'Adınız Soyadınız',
                            icon: Icons.person_outline_rounded,
                          ),
                          validator: (value) {
                            if (value == null || value.trim().length < 2) {
                              return en
                                  ? 'Please enter your name.'
                                  : 'Lütfen adınızı ve soyadınızı girin.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 16),
                        _fieldLabel(en ? 'Phone number' : 'Telefon numarası'),
                        TextFormField(
                          controller: _phoneController,
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) => _sendVerificationCode(),
                          decoration:
                              _fieldDecoration(
                                hint: '5XX XXX XX XX',
                                icon: Icons.phone_iphone_rounded,
                              ).copyWith(
                                prefixText: '+90 ',
                                prefixStyle: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppConstants.textPrimary,
                                ),
                              ),
                          validator: (value) {
                            final normalized = _normalizePhoneNumber(
                              value ?? '',
                            );
                            if (!_isValidE164(normalized)) {
                              return en
                                  ? 'Enter a valid phone number.'
                                  : 'Geçerli bir telefon numarası girin.';
                            }
                            return null;
                          },
                        ),
                      ] else ...[
                        _fieldLabel(
                          en ? '6-Digit SMS Code' : '6 Haneli Doğrulama Kodu',
                        ),
                        TextFormField(
                          controller: _codeController,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          autofocus: true,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) => _verifySmsCode(),
                          decoration: _fieldDecoration(
                            hint: '123456',
                            icon: Icons.sms_outlined,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),

                      // Ana Buton
                      Container(
                        height: 52,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: _darkGreen.withValues(alpha: 0.25),
                              blurRadius: 18,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: FilledButton(
                          onPressed: _isLoading
                              ? null
                              : (_isCodeSent
                                    ? _verifySmsCode
                                    : _sendVerificationCode),
                          style: FilledButton.styleFrom(
                            backgroundColor: _darkGreen,
                            disabledBackgroundColor: _darkGreen.withValues(
                              alpha: 0.7,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _isLoading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        _isCodeSent
                                            ? (en
                                                  ? 'Verify & Sign In'
                                                  : 'Doğrula ve Giriş Yap')
                                            : (en
                                                  ? 'Send Verification Code'
                                                  : 'Doğrulama Kodu Gönder'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        softWrap: false,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 15.5,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Icon(
                                      Icons.arrow_forward_rounded,
                                      size: 18,
                                      color: Colors.white,
                                    ),
                                  ],
                                ),
                        ),
                      ),

                      if (_isCodeSent) ...[
                        const SizedBox(height: 16),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 11,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.timer_outlined,
                                size: 18,
                                color: _darkGreen,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                en
                                    ? 'Remaining time: ${_formatTimer(_countdownSeconds)}'
                                    : 'Kalan süre: ${_formatTimer(_countdownSeconds)}',
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                  color: _darkGreen,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 18),

                      // Misafir olarak devam et
                      Center(
                        child: InkWell(
                          onTap: _isLoading ? null : _continueAsGuest,
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  en
                                      ? 'Continue as guest'
                                      : 'Misafir olarak devam et',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppConstants.textSecondary,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                  const Icon(
                                    Icons.chevron_right_rounded,
                                    size: 18,
                                    color: _hintColor,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            ),
          ),
        );
      },
    );
  }
}
