import datetime
from email.message import EmailMessage
import json
import logging
import os
import secrets
import shutil
import smtplib
import ssl
import subprocess
import threading
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from decimal import Decimal, InvalidOperation
from functools import wraps
from typing import Any, Dict, List, Optional
from urllib.parse import quote_plus
from uuid import uuid4

import jwt
from dotenv import load_dotenv
from flask import (
    Flask,
    flash,
    jsonify,
    redirect,
    render_template,
    request,
    session,
    url_for,
)
import mysql.connector
from mysql.connector import pooling
from pydantic import BaseModel, EmailStr, Field, ValidationError
from werkzeug.security import check_password_hash, generate_password_hash
from werkzeug.utils import secure_filename

# ---------------------------------------------------------------------------
# 0. Ortam Değişkenleri ve Konfigürasyon
# ---------------------------------------------------------------------------
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env"))


def require_environment_variable(name: str, *, minimum_length: int = 1) -> str:
    value = os.getenv(name)
    if not value or len(value) < minimum_length:
        raise RuntimeError(
            f"{name} must be set to a value with at least {minimum_length} characters."
        )
    return value


def require_database_port() -> int:
    value = require_environment_variable("DB_PORT")
    try:
        port = int(value)
    except ValueError as exc:
        raise RuntimeError("DB_PORT must be an integer between 1 and 65535.") from exc
    if not 1 <= port <= 65535:
        raise RuntimeError("DB_PORT must be an integer between 1 and 65535.")
    return port


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger("market_app")

app = Flask(__name__)
app.config["SECRET_KEY"] = require_environment_variable("FLASK_SECRET_KEY", minimum_length=32)
app.config["SESSION_COOKIE_HTTPONLY"] = True
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
app.config["MAX_CONTENT_LENGTH"] = 5 * 1024 * 1024  # Maksimum 5 MB dosya yükleme sınırı
app.config["JWT_SECRET_KEY"] = require_environment_variable("JWT_SECRET_KEY", minimum_length=32)

JWT_SECRET_KEY = app.config["JWT_SECRET_KEY"]
ADMIN_USERNAME = require_environment_variable("ADMIN_USERNAME")
ADMIN_PASSWORD = require_environment_variable("ADMIN_PASSWORD", minimum_length=12)

# Google / telefon ile giriş (Firebase) – isteğe bağlı. Boşsa bu giriş yöntemleri kapalıdır.
FIREBASE_PROJECT_ID = os.getenv("FIREBASE_PROJECT_ID", "").strip()
FIREBASE_WEB_API_KEY = os.getenv("FIREBASE_WEB_API_KEY", "").strip()
DEFAULT_MINIMUM_ORDER_AMOUNT = Decimal("450.00")
MINIMUM_ORDER_SETTING_KEY = "minimum_order_amount"
FREE_DELIVERY_THRESHOLD = Decimal("1000.00")
DELIVERY_FEE = Decimal("50.00")

# "Şifremi unuttum" e-postaları için SMTP – isteğe bağlı. Boşsa e-posta ile sıfırlama kapalıdır.
SMTP_HOST = os.getenv("SMTP_HOST", "").strip()
SMTP_PORT = int(os.getenv("SMTP_PORT", "587") or 587)
SMTP_USER = os.getenv("SMTP_USER", "").strip()
SMTP_PASSWORD = os.getenv("SMTP_PASSWORD", "")
SMTP_FROM = os.getenv("SMTP_FROM", "").strip() or SMTP_USER

PASSWORD_RESET_CODE_MINUTES = 15
PASSWORD_RESET_MAX_ATTEMPTS = 5
PASSWORD_RESET_RESEND_SECONDS = 60

UPLOAD_FOLDER = os.path.join(app.root_path, "static", "uploads")
ALLOWED_IMAGE_EXTENSIONS = {"jpg", "jpeg", "png", "webp", "gif"}
os.makedirs(UPLOAD_FOLDER, exist_ok=True)

# ---------------------------------------------------------------------------
# 1. MySQL Bağlantı Havuzu (Thread-Safe Connection Pool)
# ---------------------------------------------------------------------------
DB_HOST = require_environment_variable("DB_HOST")
DB_PORT = require_database_port()
DB_USER = require_environment_variable("DB_USER")
DB_PASSWORD = require_environment_variable("DB_PASSWORD")
DB_NAME = require_environment_variable("DB_NAME")

try:
    db_pool = pooling.MySQLConnectionPool(
        pool_name="market_pool",
        pool_size=10,
        pool_reset_session=True,
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        use_pure=True,
    )
    logger.info("MySQL Bağlantı Havuzu (Connection Pool) başarıyla başlatıldı.")
except Exception as e:
    logger.critical(f"MySQL bağlantı havuzu başlatılamadı: {e}")
    raise


@contextmanager
def get_db():
    """Bağlantı havuzundan güvenli şekilde connection alır ve işlem bitince havuza iade eder."""
    conn = db_pool.get_connection()
    try:
        yield conn
    finally:
        conn.close()


def init_database_schema() -> None:
    """Veritabanı tablolarını ve gerekli sütunları güvenceye alır."""
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS users (
                id INT AUTO_INCREMENT PRIMARY KEY,
                name VARCHAR(120) NOT NULL,
                email VARCHAR(190) NOT NULL UNIQUE,
                password_hash VARCHAR(255) NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS user_addresses (
                id INT AUTO_INCREMENT PRIMARY KEY,
                user_id INT NOT NULL,
                title VARCHAR(50) NOT NULL,
                full_address TEXT NOT NULL,
                city VARCHAR(50) NOT NULL,
                district VARCHAR(50) NOT NULL,
                latitude DECIMAL(10, 8) NULL,
                longitude DECIMAL(11, 8) NULL,
                is_default TINYINT(1) NOT NULL DEFAULT 0,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
            )
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS categories (
                id INT AUTO_INCREMENT PRIMARY KEY,
                name VARCHAR(100) NOT NULL UNIQUE
            )
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS subcategories (
                id INT AUTO_INCREMENT PRIMARY KEY,
                category_id INT NOT NULL,
                name VARCHAR(100) NOT NULL,
                UNIQUE KEY uq_cat_sub (category_id, name),
                FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE CASCADE
            )
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS products (
                id INT AUTO_INCREMENT PRIMARY KEY,
                name VARCHAR(150) NOT NULL,
                description TEXT,
                price DECIMAL(10, 2) NOT NULL,
                category_id INT NOT NULL,
                subcategory_id INT NULL,
                image VARCHAR(255) NOT NULL,
                stock INT NOT NULL DEFAULT 0,
                active BOOLEAN NOT NULL DEFAULT TRUE,
                FOREIGN KEY (category_id) REFERENCES categories(id)
            )
            """
        )
        cursor.execute("SHOW COLUMNS FROM products LIKE 'subcategory_id'")
        if not cursor.fetchone():
            cursor.execute(
                "ALTER TABLE products ADD COLUMN subcategory_id INT NULL AFTER category_id"
            )
        cursor.execute("SHOW COLUMNS FROM products LIKE 'minimum_order_exempt'")
        if not cursor.fetchone():
            cursor.execute(
                "ALTER TABLE products ADD COLUMN minimum_order_exempt BOOLEAN NOT NULL DEFAULT FALSE"
            )
        # Mevcut kategoriler için varsayılan alt kategorileri oluştur (yoksa ekler)
        default_subcategories_map = {
            "İçecek": ["Gazlı İçecek", "Su & Maden Suyu", "Meyve Suyu", "Soğuk Çay & Kahve", "Enerji İçeceği"],
            "Atıştırmalık": ["Cips & Kraker", "Çikolata & Gofret", "Bisküvi & Kek", "Kuruyemiş", "Şekerleme & Sakız"],
            "Temel Gıda": ["Ekmek & Unlu Mamüller", "Makarna & Bakliyat", "Sıvı Yağ", "Un, Şeker & Tuz", "Konserve & Salça"],
            "Süt Ürünleri": ["Süt", "Yoğurt & Ayran", "Peynir", "Tereyağı & Kaymak"],
            "Temizlik": ["Çamaşır Yıkama", "Bulaşık Yıkama", "Yüzey & Genel Temizlik", "Kağıt Ürünleri"],
            "Kahvaltılık": ["Zeytin", "Reçel, Bal & Krem Çikolata", "Yumurta", "Şarküteri & Sucuk", "Mısır Gevreği & Yulaf"],
            "Kişisel bakım": ["Şampuan & Duş Jeli", "Ağız & Diş Bakımı", "Deodorant & Parfüm", "Cilt & El Bakımı", "Hijyenik Ped & Pamuk"],
            "Sigara/Tütün": ["Sigara", "Sarma Tütün", "Puro & Çakmak"],
            "Alkollü içecek": ["Bira", "Şarap", "Rakı", "Viski & Votka", "Cin & Likör"],
        }
        cursor.execute("SELECT id, name FROM categories")
        existing_cats = cursor.fetchall()
        for cat_id, cat_name in existing_cats:
            matched_subs = None
            for key_name, sub_list in default_subcategories_map.items():
                if key_name.lower() == str(cat_name).strip().lower():
                    matched_subs = sub_list
                    break
            if not matched_subs:
                matched_subs = ["Genel", "Popüler", "Avantajlı Paket"]
            for sub_name in matched_subs:
                cursor.execute(
                    "INSERT IGNORE INTO subcategories (category_id, name) VALUES (%s, %s)",
                    (cat_id, sub_name),
                )

        # Alt kategorisi atanmamış mevcut ürünleri isimlerine göre otomatik eşleştir
        cursor.execute("SELECT id, category_id, name FROM subcategories")
        all_subs = cursor.fetchall()
        sub_lookup: Dict[tuple, int] = {}
        first_sub_for_cat: Dict[int, int] = {}
        for s_id, s_cat_id, s_name in all_subs:
            sub_lookup[(int(s_cat_id), str(s_name).lower())] = int(s_id)
            first_sub_for_cat.setdefault(int(s_cat_id), int(s_id))

        cursor.execute("SELECT id, category_id, name FROM products WHERE subcategory_id IS NULL")
        unassigned_products = cursor.fetchall()
        for p_id, p_cat_id, p_name in unassigned_products:
            p_cat_id = int(p_cat_id)
            lower_name = str(p_name).lower()
            target_sub_name = None
            if any(k in lower_name for k in ("maden suyu", "soda", "avşar", "uludağ doğal", "frutti elmalı", "frutti limonlu")):
                target_sub_name = "su & maden suyu"
            elif any(k in lower_name for k in ("iced coffee", "mr. brown", "kahve", "soğuk çay", "ice tea", "lipton", "fuse tea")):
                target_sub_name = "soğuk çay & kahve"
            elif any(k in lower_name for k in ("nektar", "meyve", "elma suyu", "vişne", "şeftali", "kayısı", "portakal nektar", "limonata")):
                target_sub_name = "meyve suyu"
            elif any(k in lower_name for k in ("cola", "fanta", "sprite", "gazoz", "frutti extra", "pepsi")):
                target_sub_name = "gazlı içecek"
            elif any(k in lower_name for k in ("cips", "lays", "ruffles", "doritos", "kraker", "crax", "gong", "patlağı")):
                target_sub_name = "cips & kraker"
            elif any(k in lower_name for k in ("bisküvi", "burçak", "tutku", "negro", "benimo", "kek", "paykek", "browni", "topkek", "popkek", "form çikolata kaplı")):
                target_sub_name = "bisküvi & kek"
            elif any(k in lower_name for k in ("çikolata", "karam", "canga", "hoşbeş", "gofret", "bar")):
                target_sub_name = "çikolata & gofret"
            elif any(k in lower_name for k in ("yulaf", "lifalif", "gevrek", "mısır gevreği")):
                target_sub_name = "mısır gevreği & yulaf"
            elif any(k in lower_name for k in ("ekmek", "unlu")):
                target_sub_name = "ekmek & unlu mamüller"
            elif any(k in lower_name for k in ("süt", "sut")):
                target_sub_name = "süt"
            elif any(k in lower_name for k in ("efes", "tuborg", "carlsberg", "corona", "miller", "beck", "bomonti", "amsterdam", "desperados", "sol ", "frederik", "kronenbourg", "bira")):
                target_sub_name = "bira"

            assigned_sub_id = (
                sub_lookup.get((p_cat_id, target_sub_name))
                if target_sub_name
                else None
            ) or first_sub_for_cat.get(p_cat_id)
            if assigned_sub_id:
                cursor.execute(
                    "UPDATE products SET subcategory_id = %s WHERE id = %s",
                    (assigned_sub_id, int(p_id)),
                )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS weekly_deal_products (
                product_id INT PRIMARY KEY,
                position INT NOT NULL DEFAULT 0,
                added_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE CASCADE
            )
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS app_settings (
                setting_key VARCHAR(100) PRIMARY KEY,
                setting_value VARCHAR(255) NOT NULL,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
            )
            """
        )
        cursor.execute(
            """
            INSERT IGNORE INTO app_settings (setting_key, setting_value)
            VALUES (%s, %s)
            """,
            (MINIMUM_ORDER_SETTING_KEY, str(DEFAULT_MINIMUM_ORDER_AMOUNT)),
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS orders (
                id INT AUTO_INCREMENT PRIMARY KEY,
                user_id INT NULL,
                total_price DECIMAL(10, 2) NOT NULL,
                shipping_address TEXT NULL,
                payment_method VARCHAR(50) NOT NULL DEFAULT 'Nakit',
                status VARCHAR(50) NOT NULL DEFAULT 'PENDING',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
            )
            """
        )
        cursor.execute("SHOW COLUMNS FROM orders LIKE 'delivery_fee'")
        if not cursor.fetchone():
            cursor.execute(
                "ALTER TABLE orders ADD COLUMN delivery_fee DECIMAL(10, 2) NOT NULL DEFAULT 0.00 AFTER total_price"
            )
        cursor.execute("SHOW COLUMNS FROM orders LIKE 'payment_method'")
        if not cursor.fetchone():
            cursor.execute(
                "ALTER TABLE orders ADD COLUMN payment_method VARCHAR(50) NOT NULL DEFAULT 'Nakit' AFTER shipping_address"
            )
        cursor.execute("SHOW COLUMNS FROM orders LIKE 'phone'")
        if not cursor.fetchone():
            cursor.execute(
                "ALTER TABLE orders ADD COLUMN phone VARCHAR(30) NULL AFTER shipping_address"
            )
        cursor.execute("SHOW COLUMNS FROM orders LIKE 'latitude'")
        if not cursor.fetchone():
            cursor.execute(
                "ALTER TABLE orders ADD COLUMN latitude DECIMAL(10, 8) NULL AFTER shipping_address"
            )
        cursor.execute("SHOW COLUMNS FROM orders LIKE 'longitude'")
        if not cursor.fetchone():
            cursor.execute(
                "ALTER TABLE orders ADD COLUMN longitude DECIMAL(11, 8) NULL AFTER latitude"
            )
        # Mevcut Türkçe sipariş durumlarını standart durum kodlarına (PENDING, PREPARING, ON_THE_WAY, DELIVERED, CANCELLED) dönüştür
        status_migrations = [
            ("PENDING", ("Beklemede", "PENDING")),
            ("PREPARING", ("Hazırlanıyor", "PREPARING")),
            ("ON_THE_WAY", ("Yolda", "Kuryede", "ON_THE_WAY")),
            ("DELIVERED", ("Teslim Edildi", "DELIVERED")),
            ("CANCELLED", ("İptal Edildi", "CANCELLED")),
        ]
        for target_code, legacy_values in status_migrations:
            placeholders = ", ".join(["%s"] * len(legacy_values))
            cursor.execute(
                f"UPDATE orders SET status = %s WHERE status IN ({placeholders})",
                (target_code, *legacy_values),
            )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS order_items (
                id INT AUTO_INCREMENT PRIMARY KEY,
                order_id INT NOT NULL,
                product_id INT NOT NULL,
                quantity INT NOT NULL,
                price DECIMAL(10, 2) NOT NULL,
                FOREIGN KEY (order_id) REFERENCES orders(id) ON DELETE CASCADE,
                FOREIGN KEY (product_id) REFERENCES products(id)
            )
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS campaigns (
                id INT AUTO_INCREMENT PRIMARY KEY,
                title VARCHAR(150) NOT NULL,
                description TEXT NULL,
                badge_text VARCHAR(60) NULL,
                image VARCHAR(255) NULL,
                active BOOLEAN NOT NULL DEFAULT TRUE,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS product_requests (
                id INT AUTO_INCREMENT PRIMARY KEY,
                user_id INT NULL,
                user_name VARCHAR(120) NULL,
                user_phone VARCHAR(30) NULL,
                product_name VARCHAR(30) NOT NULL,
                status VARCHAR(30) NOT NULL DEFAULT 'PENDING',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
            )
            """
        )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS admin_login_attempts (
                ip_address VARCHAR(64) PRIMARY KEY,
                failed_count INT NOT NULL DEFAULT 0,
                locked_until DATETIME NULL,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
            )
            """
        )
        # Google / telefon ile giriş için kullanıcı tablosu genişletmeleri.
        # Telefonla kayıt olanların e-postası olmayabilir -> email NULL olabilir
        # (UNIQUE indeks birden fazla NULL değere izin verir).
        cursor.execute("SHOW COLUMNS FROM users LIKE 'email'")
        email_column = cursor.fetchone()
        if email_column and str(email_column[2]).upper() == "NO":
            cursor.execute("ALTER TABLE users MODIFY email VARCHAR(190) NULL")
        cursor.execute("SHOW COLUMNS FROM users LIKE 'phone'")
        if not cursor.fetchone():
            cursor.execute("ALTER TABLE users ADD COLUMN phone VARCHAR(20) NULL UNIQUE AFTER email")
        cursor.execute("SHOW COLUMNS FROM users LIKE 'firebase_uid'")
        if not cursor.fetchone():
            cursor.execute(
                "ALTER TABLE users ADD COLUMN firebase_uid VARCHAR(128) NULL UNIQUE AFTER phone"
            )
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS password_reset_codes (
                id INT AUTO_INCREMENT PRIMARY KEY,
                user_id INT NOT NULL,
                code_hash VARCHAR(255) NOT NULL,
                expires_at DATETIME NOT NULL,
                attempts INT NOT NULL DEFAULT 0,
                used TINYINT(1) NOT NULL DEFAULT 0,
                created_at DATETIME NOT NULL,
                INDEX idx_reset_user (user_id),
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
            )
            """
        )
        conn.commit()
        cursor.close()


init_database_schema()


def get_minimum_order_amount(cursor) -> Decimal:
    cursor.execute(
        "SELECT setting_value FROM app_settings WHERE setting_key = %s",
        (MINIMUM_ORDER_SETTING_KEY,),
    )
    row = cursor.fetchone()
    if not row:
        raise RuntimeError("Minimum order setting is missing from the database.")
    return Decimal(str(row["setting_value"]))


# ---------------------------------------------------------------------------
# 2. Pydantic Doğrulama Modelleri
# ---------------------------------------------------------------------------
class RegisterRequest(BaseModel):
    name: str = Field(min_length=2, max_length=100)
    email: EmailStr
    password: str = Field(min_length=6, max_length=128)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1)


class FirebaseLoginRequest(BaseModel):
    id_token: str = Field(min_length=20)
    name: Optional[str] = Field(default=None, max_length=100)
    phone: Optional[str] = Field(default=None, max_length=50)


class ForgotPasswordRequest(BaseModel):
    email: EmailStr


class ResetPasswordRequest(BaseModel):
    email: EmailStr
    code: str = Field(min_length=6, max_length=6, pattern=r"^\d{6}$")
    new_password: str = Field(min_length=6, max_length=128)


class PhoneResetPasswordRequest(BaseModel):
    id_token: str = Field(min_length=20)
    new_password: str = Field(min_length=6, max_length=128)


class OrderItemRequest(BaseModel):
    product_id: int = Field(gt=0, strict=True)
    quantity: int = Field(gt=0, le=2147483647, strict=True)


class CreateOrderRequest(BaseModel):
    items: List[OrderItemRequest] = Field(min_length=1, max_length=100)
    address_id: Optional[int] = Field(default=None)
    shipping_address: Optional[str] = Field(default=None, max_length=500)
    full_address: Optional[str] = Field(default=None, max_length=500)
    phone: Optional[str] = Field(default=None, max_length=50)
    latitude: Optional[float] = Field(default=None)
    longitude: Optional[float] = Field(default=None)
    payment_method: Optional[str] = Field(default="Nakit", max_length=50)


# ---------------------------------------------------------------------------
# 3. Güvenlik, CSRF ve JWT Yardımcıları
# ---------------------------------------------------------------------------
def generate_jwt_token(user_id: int, email: str, name: str) -> str:
    """Kullanıcı için 30 gün geçerli imzalı JWT erişim token'ı oluşturur.

    Mobil uygulama her açılışta /api/auth/refresh ile token'ı yenilediği için,
    kullanıcı çıkış yapmadığı sürece oturum açık kalır.
    """
    payload = {
        "user_id": user_id,
        "email": email,
        "name": name,
        "exp": datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=30),
        "iat": datetime.datetime.now(datetime.timezone.utc),
    }
    return jwt.encode(payload, JWT_SECRET_KEY, algorithm="HS256")


def decode_jwt_token(token: str) -> Optional[Dict[str, Any]]:
    """JWT token'ını doğrular ve decode eder; geçersizse None döner."""
    try:
        return jwt.decode(token, JWT_SECRET_KEY, algorithms=["HS256"])
    except (jwt.ExpiredSignatureError, jwt.InvalidTokenError):
        return None


def token_required(f):
    """Mobil API isteklerinde Bearer token zorunluluğu getiren dekoratör."""
    @wraps(f)
    def decorated(*args, **kwargs):
        auth_header = request.headers.get("Authorization", "")
        if not auth_header:
            return jsonify({"error": "Yetkilendirme başlığı (Authorization) eksik."}), 401

        parts = auth_header.split()
        if len(parts) != 2 or parts[0].lower() != "bearer":
            return jsonify({"error": "Geçersiz yetki formatı. 'Bearer <token>' bekleniyor."}), 401

        token = parts[1]
        payload = decode_jwt_token(token)
        if not payload:
            return jsonify({"error": "Geçersiz veya oturum süresi dolmuş token."}), 401

        # Geçerli kullanıcı bilgilerini request nesnesine ekle
        request.current_user = payload
        return f(*args, **kwargs)

    return decorated


def get_csrf_token() -> str:
    """Admin formları için oturuma özel güvenli CSRF token üretir."""
    if "_csrf_token" not in session:
        session["_csrf_token"] = secrets.token_hex(32)
    return session["_csrf_token"]


app.jinja_env.globals["csrf_token"] = get_csrf_token


@app.before_request
def verify_admin_csrf():
    """Admin ve kurye panelindeki mutasyon isteklerinde CSRF token doğrulaması yapar."""
    if request.method in ("POST", "PATCH", "PUT", "DELETE") and (
        request.path.startswith("/admin")
        or request.path.startswith("/api/admin")
        or request.path.startswith("/api/courier")
    ):
        token = (
            request.form.get("csrf_token")
            or request.headers.get("X-CSRF-Token")
            or (request.get_json(silent=True) or {}).get("csrf_token")
        )
        session_token = session.get("_csrf_token")
        if not token or not session_token or not secrets.compare_digest(str(token), str(session_token)):
            logger.warning(f"CSRF doğrulama hatası tespit edildi: {request.path}")
            if request.path.startswith("/api/"):
                return jsonify({"success": False, "error": "Güvenlik oturumu doğrulanamadı (CSRF)."}), 403
            flash("Güvenlik oturumu doğrulanamadı (CSRF). Lütfen formu tekrar gönderin.", "error")
            return redirect(request.referrer or url_for("admin_dashboard"))


def admin_required(view):
    """Admin oturumu gerektiren görünümler ve admin API'leri için yetki kontrolü."""
    @wraps(view)
    def wrapped_view(*args, **kwargs):
        if not session.get("admin_authenticated"):
            if request.path.startswith("/api/admin"):
                return jsonify({"success": False, "error": "Yetkisiz erişim. Lütfen giriş yapın."}), 401
            return redirect(url_for("admin_login", next=request.path))
        return view(*args, **kwargs)

    return wrapped_view


# ---------------------------------------------------------------------------
# 3.1 Sipariş Durumu Sabitleri ve Yardımcıları
# ---------------------------------------------------------------------------
ACTIVE_ORDER_STATUSES = ("PENDING", "PREPARING", "ON_THE_WAY")
HISTORY_ORDER_STATUSES = ("DELIVERED", "CANCELLED")
ALL_ORDER_STATUSES = ACTIVE_ORDER_STATUSES + HISTORY_ORDER_STATUSES

ORDER_STATUS_LABELS: Dict[str, str] = {
    "PENDING": "Beklemede",
    "PREPARING": "Hazırlanıyor",
    "ON_THE_WAY": "Kuryede",
    "DELIVERED": "Teslim Edildi",
    "CANCELLED": "İptal Edildi",
}

ORDER_STATUS_ALIASES: Dict[str, str] = {
    "PENDING": "PENDING",
    "BEKLEMEDE": "PENDING",
    "Beklemede": "PENDING",
    "PREPARING": "PREPARING",
    "HAZIRLANIYOR": "PREPARING",
    "Hazırlanıyor": "PREPARING",
    "ON_THE_WAY": "ON_THE_WAY",
    "YOLDA": "ON_THE_WAY",
    "Yolda": "ON_THE_WAY",
    "KURYEDE": "ON_THE_WAY",
    "Kuryede": "ON_THE_WAY",
    "DELIVERED": "DELIVERED",
    "TESLIM EDILDI": "DELIVERED",
    "TESLİM EDİLDİ": "DELIVERED",
    "Teslim Edildi": "DELIVERED",
    "CANCELLED": "CANCELLED",
    "CANCELED": "CANCELLED",
    "IPTAL EDILDI": "CANCELLED",
    "İPTAL EDİLDİ": "CANCELLED",
    "İptal Edildi": "CANCELLED",
}


def normalize_order_status(raw_status: Optional[str]) -> Optional[str]:
    if not raw_status:
        return None
    cleaned = raw_status.strip()
    return ORDER_STATUS_ALIASES.get(cleaned) or ORDER_STATUS_ALIASES.get(cleaned.upper())


def order_status_label(status_code: Optional[str]) -> str:
    normalized = normalize_order_status(status_code) or "PENDING"
    return ORDER_STATUS_LABELS.get(normalized, "Beklemede")


# ---------------------------------------------------------------------------
# 4. Mobil REST API Endpoint'leri
# ---------------------------------------------------------------------------

@app.post("/api/auth/register")
def api_register():
    data = request.get_json(silent=True) or {}
    try:
        req = RegisterRequest(**data)
    except ValidationError as err:
        first_error = err.errors()[0]["msg"]
        return jsonify({"error": f"Geçersiz veri: {first_error}"}), 400

    name = req.name.strip()
    email = req.email.strip().lower()
    password_hash = generate_password_hash(req.password)

    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute(
                "INSERT INTO users (name, email, password_hash) VALUES (%s, %s, %s)",
                (name, email, password_hash),
            )
            conn.commit()
            user_id = cursor.lastrowid
            token = generate_jwt_token(user_id=user_id, email=email, name=name)
            return jsonify({
                "success": True,
                "token": token,
                "user": {"id": user_id, "name": name, "email": email},
            }), 201
        except mysql.connector.IntegrityError:
            conn.rollback()
            return jsonify({"error": "Bu e-posta adresi zaten kayıtlı."}), 409
        except Exception as e:
            conn.rollback()
            logger.exception("Kayıt işlemi sırasında veritabanı hatası")
            return jsonify({"error": "Kayıt işlemi gerçekleştirilemedi. Lütfen tekrar deneyin."}), 500
        finally:
            cursor.close()


@app.post("/api/auth/login")
def api_login():
    data = request.get_json(silent=True) or {}
    try:
        req = LoginRequest(**data)
    except ValidationError as err:
        first_error = err.errors()[0]["msg"]
        return jsonify({"error": f"Geçersiz veri: {first_error}"}), 400

    email = req.email.strip().lower()

    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute("SELECT id, name, email, password_hash FROM users WHERE email = %s", (email,))
            user = cursor.fetchone()
            if not user or not check_password_hash(user["password_hash"], req.password):
                return jsonify({"error": "E-posta veya şifre hatalı."}), 401

            token = generate_jwt_token(user_id=user["id"], email=user["email"], name=user["name"])
            return jsonify({
                "success": True,
                "token": token,
                "user": {"id": user["id"], "name": user["name"], "email": user["email"]},
            })
        except Exception as err:
            logger.exception("Giriş işlemi sırasında hata")
            error_message = "Giriş işlemi gerçekleştirilemedi. Lütfen tekrar deneyin."
            if app.debug:
                error_message = f"{error_message} Ayrıntı: {err}"
            return jsonify({"error": error_message}), 500
        finally:
            cursor.close()


@app.post("/api/auth/refresh")
@token_required
def api_refresh_token():
    """Geçerli token ile yeni (süresi uzatılmış) bir token döndürür.

    Kullanıcı silinmişse 401 döner; böylece uygulama oturumu kapatır.
    """
    user_id = request.current_user.get("user_id")
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute("SELECT id, name, email, phone FROM users WHERE id = %s", (user_id,))
            user = cursor.fetchone()
            if not user:
                return jsonify({"error": "Kullanıcı bulunamadı."}), 401

            contact = user.get("email") or user.get("phone") or ""
            token = generate_jwt_token(user_id=user["id"], email=contact, name=user["name"])
            return jsonify({
                "success": True,
                "token": token,
                "user": {
                    "id": user["id"],
                    "name": user["name"],
                    "email": contact,
                    "phone": user.get("phone"),
                },
            })
        except Exception:
            logger.exception("Token yenileme sırasında hata")
            return jsonify({"error": "Oturum yenilenemedi."}), 500
        finally:
            cursor.close()


def verify_firebase_id_token(id_token: str) -> Optional[Dict[str, Any]]:
    """Firebase ID token'ını Google sunucuları üzerinden doğrular ve kullanıcı bilgilerini döner."""
    # 1. Yöntem: Firebase Identity Toolkit REST API (FIREBASE_WEB_API_KEY tanımlıysa)
    if FIREBASE_WEB_API_KEY:
        url = f"https://identitytoolkit.googleapis.com/v1/accounts:lookup?key={quote_plus(FIREBASE_WEB_API_KEY)}"
        payload = json.dumps({"idToken": id_token}).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                body = json.loads(resp.read().decode("utf-8"))
                users = body.get("users") or []
                if not users:
                    return None
                info = users[0]
                return {
                    "uid": info.get("localId"),
                    "email": (info.get("email") or "").strip().lower() or None,
                    "phone": (info.get("phoneNumber") or "").strip() or None,
                    "name": (info.get("displayName") or "").strip() or None,
                }
        except Exception:
            logger.warning("Firebase accounts:lookup doğrulaması başarısız oldu")
            return None

    # 2. Yöntem: Google OAuth2 tokeninfo (FIREBASE_PROJECT_ID tanımlıysa)
    if FIREBASE_PROJECT_ID:
        url = f"https://oauth2.googleapis.com/tokeninfo?id_token={quote_plus(id_token)}"
        try:
            with urllib.request.urlopen(url, timeout=10) as resp:
                info = json.loads(resp.read().decode("utf-8"))
                aud = info.get("aud") or ""
                if FIREBASE_PROJECT_ID and aud != FIREBASE_PROJECT_ID:
                    logger.warning("Firebase token aud uyuşmazlığı: %s", aud)
                    return None
                uid = info.get("user_id") or info.get("sub")
                if not uid:
                    return None
                return {
                    "uid": uid,
                    "email": (info.get("email") or "").strip().lower() or None,
                    "phone": (info.get("phone_number") or "").strip() or None,
                    "name": (info.get("name") or "").strip() or None,
                }
        except Exception:
            logger.warning("Google tokeninfo doğrulaması başarısız oldu")
            return None

    return None


def send_reset_email(to_email: str, code: str) -> bool:
    """Şifre sıfırlama doğrulama kodunu SMTP üzerinden gönderir."""
    if not (SMTP_HOST and SMTP_USER and SMTP_PASSWORD):
        return False

    msg = EmailMessage()
    msg["Subject"] = f"Prestij Market - Şifre Sıfırlama Kodunuz: {code}"
    msg["From"] = SMTP_FROM
    msg["To"] = to_email
    msg.set_content(
        f"Merhaba,\n\n"
        f"Prestij Market şifre sıfırlama doğrulama kodunuz: {code}\n\n"
        f"Bu kod {PASSWORD_RESET_CODE_MINUTES} dakika boyunca geçerlidir.\n"
        f"Bu işlemi siz başlatmadıysanız bu e-postayı dikkate almayın.\n"
    )

    try:
        context = ssl.create_default_context()
        if SMTP_PORT == 465:
            with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, context=context, timeout=15) as server:
                server.login(SMTP_USER, SMTP_PASSWORD)
                server.send_message(msg)
        else:
            with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=15) as server:
                server.starttls(context=context)
                server.login(SMTP_USER, SMTP_PASSWORD)
                server.send_message(msg)
        return True
    except Exception:
        logger.exception("Şifre sıfırlama e-postası gönderilemedi")
        return False


@app.post("/api/auth/firebase")
def api_firebase_login():
    """Google veya Telefon (Firebase Auth) ile doğrulanmış kullanıcıyı sisteme giriş yaptırır."""
    if not (FIREBASE_WEB_API_KEY or FIREBASE_PROJECT_ID):
        return jsonify({
            "error": "Google/Telefon girişi için sunucuda FIREBASE_WEB_API_KEY veya FIREBASE_PROJECT_ID henüz tanımlanmadı."
        }), 503

    data = request.get_json(silent=True) or {}
    try:
        req = FirebaseLoginRequest(**data)
    except ValidationError as err:
        first_error = err.errors()[0]["msg"]
        return jsonify({"error": f"Geçersiz veri: {first_error}"}), 400

    verified = verify_firebase_id_token(req.id_token)
    if not verified or not verified.get("uid"):
        return jsonify({"error": "Kimlik doğrulama anahtarı geçersiz veya süresi dolmuş."}), 401

    firebase_uid = verified["uid"]
    email = verified.get("email")
    phone = (verified.get("phone") or (req.phone or "")).strip() or None
    fallback_name = (
        (req.name or "").strip()
        or verified.get("name")
        or (email.split("@")[0] if email else None)
        or (f"Kullanıcı {phone[-4:]}" if phone and len(phone) >= 4 else "Prestij Müşterisi")
    )

    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            user = None
            cursor.execute(
                "SELECT id, name, email, phone, firebase_uid FROM users WHERE firebase_uid = %s",
                (firebase_uid,),
            )
            user = cursor.fetchone()

            if not user and email:
                cursor.execute(
                    "SELECT id, name, email, phone, firebase_uid FROM users WHERE email = %s",
                    (email,),
                )
                user = cursor.fetchone()

            if not user and phone:
                cursor.execute(
                    "SELECT id, name, email, phone, firebase_uid FROM users WHERE phone = %s",
                    (phone,),
                )
                user = cursor.fetchone()

            if user:
                updates = []
                params = []
                provided_name = (req.name or "").strip()
                if provided_name and provided_name != user.get("name"):
                    updates.append("name = %s")
                    params.append(provided_name)
                if not user.get("firebase_uid"):
                    updates.append("firebase_uid = %s")
                    params.append(firebase_uid)
                if email and not user.get("email"):
                    updates.append("email = %s")
                    params.append(email)
                if phone and not user.get("phone"):
                    updates.append("phone = %s")
                    params.append(phone)
                if updates:
                    params.append(user["id"])
                    cursor.execute(
                        f"UPDATE users SET {', '.join(updates)} WHERE id = %s",
                        tuple(params),
                    )
                    conn.commit()
                user_id = user["id"]
                user_name = provided_name or user["name"]
                user_email = user.get("email") or email
                user_phone = user.get("phone") or phone
            else:
                random_pw_hash = generate_password_hash(secrets.token_urlsafe(32))
                cursor.execute(
                    "INSERT INTO users (name, email, phone, firebase_uid, password_hash) VALUES (%s, %s, %s, %s, %s)",
                    (fallback_name, email, phone, firebase_uid, random_pw_hash),
                )
                conn.commit()
                user_id = cursor.lastrowid
                user_name = fallback_name
                user_email = email
                user_phone = phone

            contact = user_email or user_phone or ""
            token = generate_jwt_token(user_id=user_id, email=contact, name=user_name)
            return jsonify({
                "success": True,
                "token": token,
                "user": {
                    "id": user_id,
                    "name": user_name,
                    "email": contact,
                    "phone": user_phone,
                },
            })
        except Exception:
            conn.rollback()
            logger.exception("Firebase giriş işlemi sırasında hata")
            return jsonify({"error": "Giriş işlemi tamamlanamadı. Lütfen tekrar deneyin."}), 500
        finally:
            cursor.close()


@app.post("/api/auth/forgot-password")
def api_forgot_password():
    """E-posta adresine 6 haneli şifre sıfırlama kodu gönderir."""
    if not (SMTP_HOST and SMTP_USER and SMTP_PASSWORD):
        return jsonify({
            "error": "E-posta gönderim servisi (SMTP) sunucuda henüz yapılandırılmadı."
        }), 503

    data = request.get_json(silent=True) or {}
    try:
        req = ForgotPasswordRequest(**data)
    except ValidationError as err:
        first_error = err.errors()[0]["msg"]
        return jsonify({"error": f"Geçersiz e-posta: {first_error}"}), 400

    email = req.email.strip().lower()
    now = datetime.datetime.utcnow()

    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute("SELECT id, name, email FROM users WHERE email = %s", (email,))
            user = cursor.fetchone()
            if not user:
                return jsonify({"error": "Bu e-posta adresiyle kayıtlı bir hesap bulunamadı."}), 404

            cursor.execute(
                "SELECT created_at FROM password_reset_codes WHERE user_id = %s AND used = 0 ORDER BY id DESC LIMIT 1",
                (user["id"],),
            )
            last_code = cursor.fetchone()
            if last_code and last_code.get("created_at"):
                elapsed = (now - last_code["created_at"]).total_seconds()
                if elapsed < PASSWORD_RESET_RESEND_SECONDS:
                    wait_sec = int(PASSWORD_RESET_RESEND_SECONDS - elapsed)
                    return jsonify({
                        "error": f"Yeni kod istemeden önce lütfen {wait_sec} saniye bekleyin."
                    }), 429

            code = f"{secrets.randbelow(1000000):06d}"
            code_hash = generate_password_hash(code)
            expires_at = now + datetime.timedelta(minutes=PASSWORD_RESET_CODE_MINUTES)

            cursor.execute("UPDATE password_reset_codes SET used = 1 WHERE user_id = %s AND used = 0", (user["id"],))
            cursor.execute(
                """
                INSERT INTO password_reset_codes (user_id, code_hash, expires_at, attempts, used, created_at)
                VALUES (%s, %s, %s, 0, 0, %s)
                """,
                (user["id"], code_hash, expires_at, now),
            )
            conn.commit()

            if not send_reset_email(email, code):
                return jsonify({"error": "Doğrulama e-postası gönderilemedi. SMTP ayarlarını kontrol edin."}), 500

            return jsonify({
                "success": True,
                "message": "6 haneli doğrulama kodu e-posta adresinize gönderildi.",
            })
        except Exception:
            conn.rollback()
            logger.exception("Şifre sıfırlama kodu oluşturulamadı")
            return jsonify({"error": "İşlem gerçekleştirilemedi. Lütfen tekrar deneyin."}), 500
        finally:
            cursor.close()


@app.post("/api/auth/reset-password")
def api_reset_password():
    """E-postaya gelen 6 haneli kodu doğrulayarak şifreyi günceller."""
    data = request.get_json(silent=True) or {}
    try:
        req = ResetPasswordRequest(**data)
    except ValidationError as err:
        first_error = err.errors()[0]["msg"]
        return jsonify({"error": f"Geçersiz veri: {first_error}"}), 400

    email = req.email.strip().lower()
    now = datetime.datetime.utcnow()

    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute("SELECT id FROM users WHERE email = %s", (email,))
            user = cursor.fetchone()
            if not user:
                return jsonify({"error": "Doğrulama kodu geçersiz veya süresi dolmuş."}), 400

            cursor.execute(
                """
                SELECT id, code_hash, expires_at, attempts
                FROM password_reset_codes
                WHERE user_id = %s AND used = 0
                ORDER BY id DESC LIMIT 1
                """,
                (user["id"],),
            )
            reset_row = cursor.fetchone()
            if not reset_row:
                return jsonify({"error": "Aktif bir doğrulama kodu bulunamadı."}), 400

            if reset_row["expires_at"] < now or reset_row["attempts"] >= PASSWORD_RESET_MAX_ATTEMPTS:
                cursor.execute("UPDATE password_reset_codes SET used = 1 WHERE id = %s", (reset_row["id"],))
                conn.commit()
                return jsonify({"error": "Doğrulama kodunun süresi dolmuş. Lütfen yeni kod isteyin."}), 400

            if not check_password_hash(reset_row["code_hash"], req.code):
                new_attempts = reset_row["attempts"] + 1
                mark_used = 1 if new_attempts >= PASSWORD_RESET_MAX_ATTEMPTS else 0
                cursor.execute(
                    "UPDATE password_reset_codes SET attempts = %s, used = %s WHERE id = %s",
                    (new_attempts, mark_used, reset_row["id"]),
                )
                conn.commit()
                return jsonify({"error": "Girdiğiniz doğrulama kodu hatalı."}), 400

            new_hash = generate_password_hash(req.new_password)
            cursor.execute("UPDATE users SET password_hash = %s WHERE id = %s", (new_hash, user["id"]))
            cursor.execute("UPDATE password_reset_codes SET used = 1 WHERE id = %s", (reset_row["id"],))
            conn.commit()

            return jsonify({
                "success": True,
                "message": "Şifreniz başarıyla güncellendi. Yeni şifrenizle giriş yapabilirsiniz.",
            })
        except Exception:
            conn.rollback()
            logger.exception("Şifre sıfırlama hatası")
            return jsonify({"error": "Şifre güncellenemedi. Lütfen tekrar deneyin."}), 500
        finally:
            cursor.close()


@app.post("/api/auth/reset-password-phone")
def api_reset_password_phone():
    """Firebase SMS doğrulamasından alınan id_token ile kullanıcının şifresini günceller."""
    if not (FIREBASE_WEB_API_KEY or FIREBASE_PROJECT_ID):
        return jsonify({
            "error": "Telefon doğrulaması için sunucuda FIREBASE_WEB_API_KEY veya FIREBASE_PROJECT_ID henüz tanımlanmadı."
        }), 503

    data = request.get_json(silent=True) or {}
    try:
        req = PhoneResetPasswordRequest(**data)
    except ValidationError as err:
        first_error = err.errors()[0]["msg"]
        return jsonify({"error": f"Geçersiz veri: {first_error}"}), 400

    verified = verify_firebase_id_token(req.id_token)
    if not verified or not verified.get("uid"):
        return jsonify({"error": "Telefon doğrulama anahtarı geçersiz veya süresi dolmuş."}), 401

    phone = verified.get("phone")
    firebase_uid = verified["uid"]

    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            user = None
            if phone:
                cursor.execute("SELECT id FROM users WHERE phone = %s", (phone,))
                user = cursor.fetchone()
            if not user:
                cursor.execute("SELECT id FROM users WHERE firebase_uid = %s", (firebase_uid,))
                user = cursor.fetchone()
            if not user:
                return jsonify({"error": "Bu telefon numarasıyla kayıtlı bir hesap bulunamadı."}), 404

            new_hash = generate_password_hash(req.new_password)
            cursor.execute(
                "UPDATE users SET password_hash = %s, firebase_uid = COALESCE(firebase_uid, %s) WHERE id = %s",
                (new_hash, firebase_uid, user["id"]),
            )
            conn.commit()
            return jsonify({
                "success": True,
                "message": "Şifreniz başarıyla güncellendi.",
            })
        except Exception:
            conn.rollback()
            logger.exception("Telefon ile şifre sıfırlama hatası")
            return jsonify({"error": "Şifre güncellenemedi. Lütfen tekrar deneyin."}), 500
        finally:
            cursor.close()


@app.delete("/api/auth/account")
@token_required
def api_delete_account():
    """Kullanıcının kendi hesabını ve kayıtlı adreslerini kalıcı olarak siler."""
    user_id = request.current_user["user_id"]
    with get_db() as conn:
        cursor = conn.cursor()
        try:
            cursor.execute("DELETE FROM users WHERE id = %s", (user_id,))
            conn.commit()
            if cursor.rowcount == 0:
                return jsonify({"success": False, "error": "Kullanıcı bulunamadı."}), 404
            logger.info(f"Kullanıcı #{user_id} kendi hesabını sildi.")
            return jsonify({"success": True, "message": "Hesabınız kalıcı olarak silindi."}), 200
        except Exception:
            conn.rollback()
            logger.exception("Hesap silme hatası")
            return jsonify({"success": False, "error": "Hesap silinemedi."}), 500
        finally:
            cursor.close()


@app.get("/api/categories")
def api_categories():
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute("SELECT id, name FROM categories ORDER BY name ASC")
            categories = cursor.fetchall()
            cursor.execute(
                "SELECT id, category_id, name FROM subcategories ORDER BY id ASC"
            )
            subcategories = cursor.fetchall()
            subs_by_cat: Dict[int, List[Dict[str, Any]]] = {}
            for sub in subcategories:
                cid = int(sub["category_id"])
                subs_by_cat.setdefault(cid, []).append(sub)
            for cat in categories:
                cat["subcategories"] = subs_by_cat.get(int(cat["id"]), [])
            return jsonify(categories)
        except Exception:
            logger.exception("Kategoriler getirilirken hata")
            return jsonify({"error": "Kategoriler yüklenemedi."}), 500
        finally:
            cursor.close()


@app.get("/api/store-settings")
def api_store_settings():
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            minimum_order_amount = get_minimum_order_amount(cursor)
            return jsonify({
                "minimum_order_amount": float(minimum_order_amount),
            })
        except Exception:
            logger.exception("Mağaza ayarları getirilirken hata")
            return jsonify({"error": "Mağaza ayarları yüklenemedi."}), 500
        finally:
            cursor.close()


@app.get("/api/products")
def api_products():
    category_id = request.args.get("category_id")
    subcategory_id = request.args.get("subcategory_id")
    search_q = request.args.get("q", "").strip()

    try:
        limit = min(max(int(request.args.get("limit", 500)), 1), 1000)
        page = max(int(request.args.get("page", 1)), 1)
        offset = (page - 1) * limit
    except ValueError:
        limit = 500
        offset = 0

    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            base_query = """
                SELECT 
                    products.id,
                    products.name,
                    products.description,
                    products.price,
                    products.image,
                    products.stock,
                    products.minimum_order_exempt,
                    products.category_id,
                    products.subcategory_id,
                    categories.name AS category,
                    COALESCE(subcategories.name, '') AS subcategory
                FROM products
                JOIN categories ON products.category_id = categories.id
                LEFT JOIN subcategories ON products.subcategory_id = subcategories.id
                WHERE products.active = TRUE
            """
            params: List[Any] = []

            if category_id:
                base_query += " AND products.category_id = %s"
                params.append(int(category_id))

            if subcategory_id:
                base_query += " AND products.subcategory_id = %s"
                params.append(int(subcategory_id))

            if search_q:
                base_query += " AND (products.name LIKE %s OR products.description LIKE %s OR categories.name LIKE %s OR COALESCE(subcategories.name, '') LIKE %s)"
                params.extend([f"%{search_q}%", f"%{search_q}%", f"%{search_q}%", f"%{search_q}%"])

            base_query += " ORDER BY products.id DESC LIMIT %s OFFSET %s"
            params.extend([limit, offset])

            cursor.execute(base_query, tuple(params))
            products = cursor.fetchall()
            return jsonify(products)
        except Exception:
            logger.exception("Ürünler getirilirken hata")
            return jsonify({"error": "Ürünler yüklenemedi."}), 500
        finally:
            cursor.close()


@app.get("/api/weekly-deals")
def api_weekly_deals():
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute(
                """
                SELECT
                    products.id,
                    products.name,
                    products.description,
                    products.price,
                    products.image,
                    products.stock,
                    products.minimum_order_exempt,
                    products.category_id,
                    products.subcategory_id,
                    categories.name AS category,
                    COALESCE(subcategories.name, '') AS subcategory
                FROM weekly_deal_products
                JOIN products ON products.id = weekly_deal_products.product_id
                JOIN categories ON products.category_id = categories.id
                LEFT JOIN subcategories ON products.subcategory_id = subcategories.id
                WHERE products.active = TRUE AND products.stock > 0
                ORDER BY weekly_deal_products.position, weekly_deal_products.added_at
                """
            )
            return jsonify(cursor.fetchall())
        except Exception:
            logger.exception("Haftanın indirim ürünleri getirilirken hata")
            return jsonify({"error": "Haftanın indirimleri yüklenemedi."}), 500
        finally:
            cursor.close()


@app.get("/api/campaigns")
def api_campaigns():
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute(
                """
                SELECT id, title, description, badge_text, image, created_at
                FROM campaigns
                WHERE active = TRUE
                ORDER BY id DESC
                """
            )
            rows = cursor.fetchall()
            for row in rows:
                if row.get("created_at"):
                    row["created_at"] = row["created_at"].strftime("%Y-%m-%d %H:%M:%S")
            return jsonify(rows)
        except Exception:
            logger.exception("Kampanyalar getirilirken hata")
            return jsonify({"error": "Kampanyalar yüklenemedi."}), 500
        finally:
            cursor.close()


@app.post("/api/orders")
@token_required
def api_create_order():
    """
    Sipariş oluşturma API'si.
    Yarış durumlarına (Race Condition / TOCTOU) karşı atomik UPDATE kullanarak stok güvencesi sağlar.
    """
    data = request.get_json(silent=True) or {}
    try:
        req = CreateOrderRequest(**data)
    except ValidationError as err:
        first_error = err.errors()[0]["msg"]
        return jsonify({"error": f"Geçersiz sipariş verisi: {first_error}"}), 400

    user_id = request.current_user["user_id"]
    shipping_address = req.shipping_address or req.full_address or ""
    quantities_by_product: Dict[int, int] = {}
    for item in req.items:
        quantities_by_product[item.product_id] = (
            quantities_by_product.get(item.product_id, 0) + item.quantity
        )
        if quantities_by_product[item.product_id] > 2147483647:
            return jsonify({"error": "Bir ürün için istenen miktar izin verilen sınırı aşıyor."}), 400

    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            p_ids = sorted(quantities_by_product)
            format_strings = ",".join(["%s"] * len(p_ids))
            conn.start_transaction()
            cursor.execute(
                f"""
                SELECT id, name, price, stock, minimum_order_exempt
                FROM products
                WHERE id IN ({format_strings}) AND active = TRUE
                ORDER BY id
                FOR UPDATE
                """,
                tuple(p_ids),
            )
            products_db = {p["id"]: p for p in cursor.fetchall()}

            for product_id in p_ids:
                if product_id not in products_db:
                    conn.rollback()
                    return jsonify({"error": f"Ürün bulunamadı veya satışta değil (ID: {product_id})"}), 404

            total_price = Decimal("0.00")
            minimum_order_total = Decimal("0.00")
            tobacco_quantity = 0
            order_details = []
            for product_id, quantity in quantities_by_product.items():
                product = products_db[product_id]
                item_price = Decimal(str(product["price"])).quantize(Decimal("0.01"))
                line_total = item_price * quantity
                total_price += line_total
                if not product.get("minimum_order_exempt"):
                    minimum_order_total += line_total
                else:
                    tobacco_quantity += quantity
                order_details.append({
                    "product_id": product_id,
                    "quantity": quantity,
                    "price": item_price,
                })

            if tobacco_quantity > 2:
                conn.rollback()
                return jsonify({
                    "error": "Bir siparişte en fazla 2 paket sigara satın alabilirsiniz."
                }), 400

            if total_price > Decimal("99999999.99"):
                conn.rollback()
                return jsonify({"error": "Sipariş toplamı izin verilen tutarı aşıyor."}), 400

            minimum_order_amount = get_minimum_order_amount(cursor)
            if minimum_order_total < minimum_order_amount:
                conn.rollback()
                return jsonify({
                    "error": (
                        f"Minimum sepet tutarı {minimum_order_amount:.2f} TL'dir. "
                        "Sigara ve tütün ürünleri bu tutara dahil değildir."
                    ),
                    "minimum_order_amount": float(minimum_order_amount),
                    "eligible_subtotal": float(minimum_order_total),
                }), 400

            # Conditional updates keep stock nonnegative; all changes roll back if any item fails.
            for detail in order_details:
                product_id = detail["product_id"]
                quantity = detail["quantity"]
                product = products_db[product_id]
                cursor.execute(
                    """
                    UPDATE products 
                    SET stock = stock - %s 
                    WHERE id = %s AND stock >= %s AND active = TRUE
                    """,
                    (quantity, product_id, quantity),
                )
                if cursor.rowcount == 0:
                    conn.rollback()
                    return jsonify({
                        "error": f"Yetersiz stok! '{product['name']}' ürününden en fazla {product['stock']} adet alınabilir."
                    }), 400

            # 3. Ana siparişi kullanıcı kimliği, adres, koordinat ve ödeme yöntemiyle kaydet
            payment_method = (req.payment_method or "Nakit").strip() or "Nakit"
            order_lat = req.latitude
            order_lng = req.longitude
            if (order_lat is None or order_lng is None) and req.address_id:
                cursor.execute(
                    "SELECT latitude, longitude FROM user_addresses WHERE id = %s AND user_id = %s",
                    (req.address_id, user_id),
                )
                addr_row = cursor.fetchone()
                if addr_row:
                    order_lat = float(addr_row["latitude"]) if addr_row.get("latitude") is not None else None
                    order_lng = float(addr_row["longitude"]) if addr_row.get("longitude") is not None else None
            elif order_lat is None or order_lng is None:
                cursor.execute(
                    "SELECT latitude, longitude FROM user_addresses WHERE user_id = %s AND full_address = %s ORDER BY id DESC LIMIT 1",
                    (user_id, shipping_address),
                )
                addr_row = cursor.fetchone()
                if addr_row:
                    order_lat = float(addr_row["latitude"]) if addr_row.get("latitude") is not None else None
                    order_lng = float(addr_row["longitude"]) if addr_row.get("longitude") is not None else None

            # Müşterinin telefon numarasını tespit et ve gerekirse kaydet
            customer_phone = (req.phone or "").strip()
            if not customer_phone and user_id:
                cursor.execute("SELECT phone FROM users WHERE id = %s", (user_id,))
                urow = cursor.fetchone()
                if urow and urow.get("phone"):
                    customer_phone = str(urow["phone"]).strip()

            if customer_phone and user_id:
                cursor.execute(
                    "UPDATE users SET phone = %s WHERE id = %s AND (phone IS NULL OR phone = '')",
                    (customer_phone, user_id),
                )

            # Teslimat/gönderim ücreti hesabı: 1000 TL ve üzeri ÜCRETSİZ, altı için 50 TL
            delivery_fee = (
                Decimal("0.00")
                if total_price >= FREE_DELIVERY_THRESHOLD or total_price == 0
                else DELIVERY_FEE
            )
            final_total_price = total_price + delivery_fee

            cursor.execute(
                """
                INSERT INTO orders (user_id, total_price, delivery_fee, shipping_address, phone, latitude, longitude, payment_method, status) 
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, 'PENDING')
                """,
                (user_id, final_total_price, delivery_fee, shipping_address, customer_phone or None, order_lat, order_lng, payment_method),
            )
            order_id = cursor.lastrowid

            # 4. Sipariş kalemlerini kaydet
            for detail in order_details:
                cursor.execute(
                    """
                    INSERT INTO order_items (order_id, product_id, quantity, price) 
                    VALUES (%s, %s, %s, %s)
                    """,
                    (order_id, detail["product_id"], detail["quantity"], detail["price"]),
                )

            conn.commit()
            logger.info(
                f"Sipariş #{order_id} kullanıcı #{user_id} tarafından oluşturuldu. "
                f"Tutar: {final_total_price} TL (Ürünler: {total_price} TL + Teslimat: {delivery_fee} TL), Ödeme: {payment_method}"
            )
            return jsonify({
                "success": True,
                "order_id": order_id,
                "subtotal": float(total_price),
                "delivery_fee": float(delivery_fee),
                "total_price": float(final_total_price),
                "payment_method": payment_method,
                "status": order_status_label("PENDING"),
                "status_code": "PENDING",
            }), 201

        except Exception:
            conn.rollback()
            logger.exception("Sipariş oluşturma sırasında beklenmeyen hata")
            return jsonify({"error": "Sipariş oluşturulurken bir hata meydana geldi."}), 500
        finally:
            cursor.close()


@app.get("/api/orders")
@token_required
def api_get_orders():
    """
    Giriş yapan kullanıcının kendi sipariş geçmişini listeler (BOLA/IDOR korumalı).
    """
    user_id = request.current_user["user_id"]

    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute(
                """
                SELECT 
                    o.id as order_id, 
                    o.total_price, 
                    o.shipping_address,
                    o.payment_method,
                    o.status,
                    o.created_at, 
                    oi.quantity, 
                    oi.price, 
                    p.name 
                FROM orders o
                JOIN order_items oi ON o.id = oi.order_id
                JOIN products p ON oi.product_id = p.id
                WHERE o.user_id = %s
                ORDER BY o.created_at DESC
                """,
                (user_id,),
            )
            rows = cursor.fetchall()

            orders: Dict[int, Dict[str, Any]] = {}
            for row in rows:
                oid = row["order_id"]
                if oid not in orders:
                    normalized_status = normalize_order_status(row["status"]) or "PENDING"
                    orders[oid] = {
                        "order_id": oid,
                        "total_price": float(row["total_price"]),
                        "shipping_address": row["shipping_address"] or "",
                        "payment_method": row["payment_method"] or "Nakit",
                        "status": order_status_label(normalized_status),
                        "status_code": normalized_status,
                        "created_at": row["created_at"].strftime("%Y-%m-%d %H:%M:%S") if row["created_at"] else None,
                        "items": [],
                    }
                orders[oid]["items"].append({
                    "name": row["name"],
                    "quantity": row["quantity"],
                    "price": float(row["price"]),
                })

            return jsonify(list(orders.values()))
        except Exception:
            logger.exception("Siparişler getirilirken hata")
            return jsonify({"error": "Sipariş geçmişi yüklenemedi."}), 500
        finally:
            cursor.close()


class AddressCreateSchema(BaseModel):
    title: str = Field(..., min_length=2, max_length=50)
    full_address: str = Field(..., min_length=10)
    city: str = Field(default="Gazimağusa", min_length=2)
    district: str = Field(default="Gazimağusa", min_length=2)
    latitude: Optional[float] = None
    longitude: Optional[float] = None


@app.get("/api/addresses")
@token_required
def get_user_addresses():
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        cursor.execute(
            "SELECT id, title, full_address, city, district, latitude, longitude, is_default "
            "FROM user_addresses WHERE user_id = %s ORDER BY id DESC",
            (request.current_user["user_id"],)
        )
        addresses = cursor.fetchall()
        cursor.close()
    return jsonify({"success": True, "data": addresses}), 200


@app.post("/api/addresses")
@token_required
def add_user_address():
    try:
        data = AddressCreateSchema(**(request.get_json(silent=True) or {}))
    except ValidationError as e:
        return jsonify({"success": False, "errors": e.errors()}), 422

    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            """
            INSERT INTO user_addresses (user_id, title, full_address, city, district, latitude, longitude)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            """,
            (
                request.current_user["user_id"],
                data.title,
                data.full_address,
                data.city,
                data.district,
                data.latitude,
                data.longitude,
            )
        )
        conn.commit()
        address_id = cursor.lastrowid
        cursor.close()

    return jsonify({"success": True, "message": "Adres kaydedildi", "address_id": address_id}), 201


@app.delete("/api/addresses/<int:address_id>")
@token_required
def delete_user_address(address_id: int):
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            "DELETE FROM user_addresses WHERE id = %s AND user_id = %s",
            (address_id, request.current_user["user_id"])
        )
        conn.commit()
        affected = cursor.rowcount
        cursor.close()

    if affected == 0:
        return jsonify({"success": False, "message": "Adres bulunamadı veya yetkiniz yok"}), 404

    return jsonify({"success": True, "message": "Adres silindi"}), 200

# ---------------------------------------------------------------------------
# 5. Web Yönetim Paneli (Admin)
# ---------------------------------------------------------------------------
ADMIN_MAX_FAILED_ATTEMPTS = 5
ADMIN_LOCKOUT_MINUTES = 15


def _get_client_ip() -> str:
    remote = request.remote_addr or "unknown"
    # Nginx (aynı sunucudaki reverse proxy) üzerinden gelen isteklerde gerçek istemci IP'si
    # X-Real-IP başlığındadır. Sadece localhost'tan gelen başlığa güvenilir; böylece
    # 5000 portuna doğrudan bağlanan biri sahte başlıkla kilidi atlatamaz.
    if remote in ("127.0.0.1", "::1"):
        real_ip = (request.headers.get("X-Real-IP") or "").strip()
        if real_ip:
            return real_ip[:64]
    return remote[:64]


@app.route("/admin/login", methods=["GET", "POST"])
def admin_login():
    if request.method == "POST":
        client_ip = _get_client_ip()
        now = datetime.datetime.utcnow()

        with get_db() as conn:
            cursor = conn.cursor(dictionary=True)
            cursor.execute(
                "SELECT failed_count, locked_until FROM admin_login_attempts WHERE ip_address = %s",
                (client_ip,),
            )
            attempt_row = cursor.fetchone()

            if attempt_row and attempt_row["locked_until"] and attempt_row["locked_until"] > now:
                remaining_seconds = int((attempt_row["locked_until"] - now).total_seconds())
                remaining_minutes = max(1, (remaining_seconds + 59) // 60)
                cursor.close()
                flash(
                    f"Çok fazla başarısız giriş denemesi! Lütfen {remaining_minutes} dakika sonra tekrar deneyin.",
                    "error",
                )
                return render_template("admin/login.html"), 429

            username = request.form.get("username", "").strip()
            password = request.form.get("password", "")
            if secrets.compare_digest(username, ADMIN_USERNAME) and secrets.compare_digest(
                password, ADMIN_PASSWORD
            ):
                cursor.execute(
                    "DELETE FROM admin_login_attempts WHERE ip_address = %s",
                    (client_ip,),
                )
                conn.commit()
                cursor.close()

                session.clear()
                session["admin_authenticated"] = True
                session["admin_username"] = username
                next_url = request.args.get("next") or request.form.get("next")
                if not next_url or not next_url.startswith("/admin") or next_url == "/admin/login":
                    next_url = url_for("admin_dashboard")
                return redirect(next_url)

            # Başarısız deneme: sayacı artır veya süresi dolmuş kilitten sonra 1'den başlat
            prev_failed = attempt_row["failed_count"] if attempt_row else 0
            if attempt_row and attempt_row["locked_until"] and attempt_row["locked_until"] <= now:
                prev_failed = 0
            new_failed = prev_failed + 1

            if new_failed >= ADMIN_MAX_FAILED_ATTEMPTS:
                locked_until = now + datetime.timedelta(minutes=ADMIN_LOCKOUT_MINUTES)
                cursor.execute(
                    """
                    INSERT INTO admin_login_attempts (ip_address, failed_count, locked_until)
                    VALUES (%s, %s, %s)
                    ON DUPLICATE KEY UPDATE failed_count = VALUES(failed_count), locked_until = VALUES(locked_until)
                    """,
                    (client_ip, new_failed, locked_until),
                )
                conn.commit()
                cursor.close()
                flash(
                    f"5 kez hatalı giriş yaptınız. IP adresiniz {ADMIN_LOCKOUT_MINUTES} dakika süreyle kilitlendi.",
                    "error",
                )
                return render_template("admin/login.html"), 429
            else:
                cursor.execute(
                    """
                    INSERT INTO admin_login_attempts (ip_address, failed_count, locked_until)
                    VALUES (%s, %s, NULL)
                    ON DUPLICATE KEY UPDATE failed_count = VALUES(failed_count), locked_until = NULL
                    """,
                    (client_ip, new_failed),
                )
                conn.commit()
                cursor.close()
                remaining_attempts = ADMIN_MAX_FAILED_ATTEMPTS - new_failed
                flash(
                    f"Kullanıcı adı veya şifre hatalı. (Kalan deneme hakkı: {remaining_attempts})",
                    "error",
                )
    return render_template("admin/login.html")


@app.get("/admin/logout")
def admin_logout():
    session.clear()
    flash("Oturum kapatıldı.", "success")
    return redirect(url_for("admin_login"))


@app.route("/admin")
@admin_required
def admin_dashboard():
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute("SELECT COUNT(*) AS total FROM products")
            product_count = cursor.fetchone()["total"]
            cursor.execute("SELECT COUNT(*) AS total FROM products WHERE active = TRUE")
            active_product_count = cursor.fetchone()["total"]
            cursor.execute("SELECT COUNT(*) AS total FROM categories")
            category_count = cursor.fetchone()["total"]
            cursor.execute("SELECT COUNT(*) AS total FROM orders")
            order_count = cursor.fetchone()["total"]
            cursor.execute("SELECT COALESCE(SUM(total_price), 0) AS total FROM orders")
            revenue = cursor.fetchone()["total"]
            minimum_order_amount = get_minimum_order_amount(cursor)
            cursor.execute(
                """
                SELECT id, name, stock
                FROM products
                WHERE active = TRUE AND stock <= 5
                ORDER BY stock ASC, name ASC
                LIMIT 6
                """
            )
            low_stock_products = cursor.fetchall()
            return render_template(
                "admin/dashboard.html",
                product_count=product_count,
                active_product_count=active_product_count,
                category_count=category_count,
                order_count=order_count,
                revenue=revenue,
                low_stock_products=low_stock_products,
                minimum_order_amount=minimum_order_amount,
            )
        except Exception:
            logger.exception("Admin dashboard yüklenirken hata")
            flash("Dashboard istatistikleri yüklenirken hata oluştu.", "error")
            return render_template(
                "admin/dashboard.html",
                product_count=0,
                active_product_count=0,
                category_count=0,
                order_count=0,
                revenue=0,
                low_stock_products=[],
                minimum_order_amount=DEFAULT_MINIMUM_ORDER_AMOUNT,
            )
        finally:
            cursor.close()


@app.post("/admin/settings/minimum-order")
@admin_required
def admin_update_minimum_order():
    raw_amount = request.form.get("minimum_order_amount", "").strip()
    try:
        amount = Decimal(raw_amount).quantize(Decimal("0.01"))
        if not amount.is_finite() or amount < 0 or amount > Decimal("99999999.99"):
            raise InvalidOperation
    except (InvalidOperation, ValueError):
        flash("Minimum sepet tutarı geçerli ve 0 TL veya üzeri olmalıdır.", "error")
        return redirect(url_for("admin_dashboard"))

    with get_db() as conn:
        cursor = conn.cursor()
        try:
            cursor.execute(
                """
                INSERT INTO app_settings (setting_key, setting_value)
                VALUES (%s, %s)
                ON DUPLICATE KEY UPDATE setting_value = VALUES(setting_value)
                """,
                (MINIMUM_ORDER_SETTING_KEY, str(amount)),
            )
            conn.commit()
            flash(f"Minimum sepet tutarı {amount:.2f} TL olarak güncellendi.", "success")
        except Exception:
            conn.rollback()
            logger.exception("Minimum sepet tutarı güncellenirken hata")
            flash("Minimum sepet tutarı güncellenemedi.", "error")
        finally:
            cursor.close()
    return redirect(url_for("admin_dashboard"))


@app.route("/admin/products", methods=["GET", "POST"])
@admin_required
def admin_products():
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        if request.method == "POST":
            name = request.form.get("name", "").strip()
            description = request.form.get("description", "").strip()
            category_id = request.form.get("category_id", "").strip()
            raw_sub_id = request.form.get("subcategory_id", "").strip()
            subcategory_id = int(raw_sub_id) if raw_sub_id.isdigit() else None
            minimum_order_exempt = request.form.get("minimum_order_exempt") == "on"
            image = request.files.get("image")

            try:
                price = float(request.form.get("price", ""))
                stock = int(request.form.get("stock", ""))
            except ValueError:
                flash("Fiyat ve stok alanlarını geçerli sayısal değerlerle doldurun.", "error")
                cursor.close()
                return redirect(url_for("admin_products"))

            if not name or not category_id or not image or not image.filename:
                flash("Ürün adı, kategori ve görsel alanları zorunludur.", "error")
                cursor.close()
                return redirect(url_for("admin_products"))

            if price < 0 or stock < 0:
                flash("Fiyat ve stok negatif olamaz.", "error")
                cursor.close()
                return redirect(url_for("admin_products"))

            safe_name = secure_filename(image.filename)
            extension = safe_name.rsplit(".", 1)[-1].lower() if "." in safe_name else ""
            if extension not in ALLOWED_IMAGE_EXTENSIONS:
                flash("Sadece JPG, JPEG, PNG, WEBP veya GIF görselleri yükleyebilirsiniz.", "error")
                cursor.close()
                return redirect(url_for("admin_products"))

            filename = f"{uuid4().hex}.{extension}"
            file_path = os.path.join(UPLOAD_FOLDER, filename)
            image.save(file_path)

            try:
                cursor.execute(
                    """
                    INSERT INTO products (
                        name, description, price, image, stock, category_id, subcategory_id, active,
                        minimum_order_exempt
                    )
                    VALUES (%s, %s, %s, %s, %s, %s, %s, TRUE, %s)
                    """,
                    (
                        name, description, price, filename, stock, int(category_id),
                        subcategory_id, minimum_order_exempt,
                    ),
                )
                conn.commit()
                flash("Ürün başarıyla kaydedildi.", "success")
            except Exception:
                conn.rollback()
                if os.path.exists(file_path):
                    os.remove(file_path)
                logger.exception("Ürün ekleme hatası")
                flash("Ürün kaydedilemedi. Lütfen verileri kontrol edin.", "error")
            finally:
                cursor.close()

            return redirect(url_for("admin_products"))

        try:
            cursor.execute(
                """
                SELECT p.id, p.name, p.description, p.price, p.image, p.stock,
                       p.active, p.minimum_order_exempt, c.name AS category,
                       s.name AS subcategory
                FROM products p
                LEFT JOIN categories c ON c.id = p.category_id
                LEFT JOIN subcategories s ON s.id = p.subcategory_id
                ORDER BY p.id DESC
                """
            )
            products = cursor.fetchall()
            cursor.execute("SELECT id, name FROM categories ORDER BY name")
            categories = cursor.fetchall()
            cursor.execute("SELECT id, category_id, name FROM subcategories ORDER BY name")
            subcategories = cursor.fetchall()
            return render_template(
                "admin/products.html",
                products=products,
                categories=categories,
                subcategories=subcategories,
            )
        except Exception:
            logger.exception("Ürün listesi getirilirken hata")
            flash("Ürünler listelenirken bir hata oluştu.", "error")
            return render_template("admin/products.html", products=[], categories=[], subcategories=[])
        finally:
            cursor.close()


@app.route("/admin/products/edit/<int:product_id>", methods=["GET", "POST"])
@admin_required
def admin_edit_product(product_id: int):
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)

        if request.method == "POST":
            name = request.form.get("name", "").strip()
            description = request.form.get("description", "").strip()
            category_id = request.form.get("category_id", "").strip()
            raw_sub_id = request.form.get("subcategory_id", "").strip()
            subcategory_id = int(raw_sub_id) if raw_sub_id.isdigit() else None
            minimum_order_exempt = request.form.get("minimum_order_exempt") == "on"
            image = request.files.get("image")

            try:
                price = float(request.form.get("price", ""))
                stock = int(request.form.get("stock", ""))
            except ValueError:
                flash("Fiyat ve stok alanlarını geçerli değerlerle doldurun.", "error")
                cursor.close()
                return redirect(url_for("admin_edit_product", product_id=product_id))

            if not name or not category_id or price < 0 or stock < 0:
                flash("Ürün adı, kategori, fiyat ve stok alanlarını kontrol edin.", "error")
                cursor.close()
                return redirect(url_for("admin_edit_product", product_id=product_id))

            cursor.execute("SELECT image FROM products WHERE id = %s", (product_id,))
            product = cursor.fetchone()
            if not product:
                cursor.close()
                flash("Ürün bulunamadı.", "error")
                return redirect(url_for("admin_products"))

            image_filename = product["image"]
            new_image_path = None

            if image and image.filename:
                safe_name = secure_filename(image.filename)
                extension = safe_name.rsplit(".", 1)[-1].lower() if "." in safe_name else ""
                if extension not in ALLOWED_IMAGE_EXTENSIONS:
                    cursor.close()
                    flash("Geçersiz görsel formatı.", "error")
                    return redirect(url_for("admin_edit_product", product_id=product_id))
                image_filename = f"{uuid4().hex}.{extension}"
                new_image_path = os.path.join(UPLOAD_FOLDER, image_filename)
                image.save(new_image_path)

            try:
                cursor.execute(
                    """
                    UPDATE products
                    SET name = %s, description = %s, price = %s, stock = %s,
                        category_id = %s, subcategory_id = %s, image = %s, minimum_order_exempt = %s
                    WHERE id = %s
                    """,
                    (
                        name, description, price, stock, int(category_id), subcategory_id,
                        image_filename, minimum_order_exempt, product_id,
                    ),
                )
                conn.commit()
                if new_image_path and product["image"]:
                    old_image_path = os.path.join(UPLOAD_FOLDER, product["image"])
                    if os.path.exists(old_image_path):
                        os.remove(old_image_path)
                flash("Ürün güncellendi.", "success")
            except Exception:
                conn.rollback()
                if new_image_path and os.path.exists(new_image_path):
                    os.remove(new_image_path)
                logger.exception("Ürün güncelleme hatası")
                flash("Ürün güncellenemedi.", "error")
            finally:
                cursor.close()
            return redirect(url_for("admin_products"))

        cursor.execute("SELECT * FROM products WHERE id = %s", (product_id,))
        product = cursor.fetchone()
        cursor.execute("SELECT id, name FROM categories ORDER BY name")
        categories = cursor.fetchall()
        cursor.execute("SELECT id, category_id, name FROM subcategories ORDER BY name")
        subcategories = cursor.fetchall()
        cursor.close()
        if not product:
            flash("Ürün bulunamadı.", "error")
            return redirect(url_for("admin_products"))
        return render_template(
            "admin/edit_product.html",
            product=product,
            categories=categories,
            subcategories=subcategories,
        )


@app.post("/admin/products/toggle/<int:product_id>")
@admin_required
def admin_toggle_product(product_id: int):
    with get_db() as conn:
        cursor = conn.cursor()
        try:
            cursor.execute("UPDATE products SET active = NOT active WHERE id = %s", (product_id,))
            conn.commit()
            flash("Ürün yayın durumu güncellendi.", "success")
        except Exception:
            conn.rollback()
            logger.exception("Ürün aktif/pasif durumu güncellenirken hata")
            flash("İşlem gerçekleştirilemedi.", "error")
        finally:
            cursor.close()
    return redirect(url_for("admin_products"))


@app.route("/admin/categories", methods=["GET", "POST"])
@admin_required
def admin_categories():
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        if request.method == "POST":
            name = request.form.get("name", "").strip()
            if not name:
                flash("Kategori adı boş bırakılamaz.", "error")
            else:
                try:
                    cursor.execute("INSERT INTO categories (name) VALUES (%s)", (name,))
                    new_cat_id = cursor.lastrowid
                    cursor.execute(
                        "INSERT IGNORE INTO subcategories (category_id, name) VALUES (%s, %s)",
                        (new_cat_id, "Genel"),
                    )
                    conn.commit()
                    flash("Kategori başarıyla oluşturuldu.", "success")
                except mysql.connector.IntegrityError:
                    conn.rollback()
                    flash("Bu kategori zaten mevcut.", "error")
                except Exception:
                    conn.rollback()
                    logger.exception("Kategori eklenirken hata")
                    flash("Kategori oluşturulamadı.", "error")
            cursor.close()
            return redirect(url_for("admin_categories"))

        try:
            cursor.execute(
                """
                SELECT c.id, c.name, COUNT(p.id) AS product_count
                FROM categories c
                LEFT JOIN products p ON p.category_id = c.id
                GROUP BY c.id, c.name
                ORDER BY c.name
                """
            )
            categories = cursor.fetchall()
            cursor.execute("SELECT id, category_id, name FROM subcategories ORDER BY id ASC")
            subcategories = cursor.fetchall()
            subs_by_cat: Dict[int, List[Dict[str, Any]]] = {}
            for sub in subcategories:
                subs_by_cat.setdefault(int(sub["category_id"]), []).append(sub)
            for cat in categories:
                cat["subcategories"] = subs_by_cat.get(int(cat["id"]), [])
            return render_template("admin/categories.html", categories=categories)
        except Exception:
            logger.exception("Kategoriler listelenirken hata")
            flash("Kategoriler yüklenirken hata oluştu.", "error")
            return render_template("admin/categories.html", categories=[])
        finally:
            cursor.close()


@app.post("/admin/subcategories/add")
@admin_required
def admin_add_subcategory():
    category_id = request.form.get("category_id", type=int)
    name = request.form.get("name", "").strip()
    if not category_id or not name:
        flash("Kategori ve alt kategori adı zorunludur.", "error")
        return redirect(url_for("admin_categories"))
    with get_db() as conn:
        cursor = conn.cursor()
        try:
            cursor.execute(
                "INSERT INTO subcategories (category_id, name) VALUES (%s, %s)",
                (category_id, name),
            )
            conn.commit()
            flash(f"'{name}' alt kategorisi eklendi.", "success")
        except mysql.connector.IntegrityError:
            conn.rollback()
            flash("Bu alt kategori zaten mevcut.", "error")
        except Exception:
            conn.rollback()
            logger.exception("Alt kategori eklenirken hata")
            flash("Alt kategori eklenemedi.", "error")
        finally:
            cursor.close()
    return redirect(url_for("admin_categories"))


@app.post("/admin/subcategories/delete/<int:subcategory_id>")
@admin_required
def admin_delete_subcategory(subcategory_id: int):
    with get_db() as conn:
        cursor = conn.cursor()
        try:
            cursor.execute(
                "UPDATE products SET subcategory_id = NULL WHERE subcategory_id = %s",
                (subcategory_id,),
            )
            cursor.execute("DELETE FROM subcategories WHERE id = %s", (subcategory_id,))
            conn.commit()
            flash("Alt kategori silindi.", "success")
        except Exception:
            conn.rollback()
            logger.exception("Alt kategori silinirken hata")
            flash("Alt kategori silinemedi.", "error")
        finally:
            cursor.close()
    return redirect(url_for("admin_categories"))


# --- ÜRÜN TALEPLERİ (API & ADMIN) ---
@app.post("/api/product-requests")
def api_create_product_request():
    payload = request.get_json(silent=True) or {}
    product_name = (payload.get("product_name") or "").strip()

    if not product_name:
        return jsonify({"success": False, "error": "Lütfen talep ettiğiniz ürünü yazın."}), 400
    if len(product_name) > 30:
        return jsonify({"success": False, "error": "Ürün talebi en fazla 30 karakter olabilir."}), 400

    user_id = None
    user_name = (payload.get("user_name") or "").strip() or None
    user_phone = (payload.get("user_phone") or "").strip() or None

    auth_header = request.headers.get("Authorization", "")
    parts = auth_header.split()
    if len(parts) == 2 and parts[0].lower() == "bearer":
        decoded = decode_jwt_token(parts[1])
        if decoded:
            user_id = decoded.get("user_id")
            if not user_name:
                user_name = decoded.get("name")

    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            if user_id and not user_phone:
                cursor.execute("SELECT name, phone FROM users WHERE id = %s", (user_id,))
                u_row = cursor.fetchone()
                if u_row:
                    user_name = user_name or u_row.get("name")
                    user_phone = u_row.get("phone")

            cursor.execute(
                """
                INSERT INTO product_requests (user_id, user_name, user_phone, product_name, status)
                VALUES (%s, %s, %s, %s, 'PENDING')
                """,
                (user_id, (user_name or "")[:120] or None, (user_phone or "")[:30] or None, product_name),
            )
            conn.commit()
            return jsonify({
                "success": True,
                "message": "Ürün talebiniz başarıyla alındı.",
            }), 201
        except Exception:
            conn.rollback()
            logger.exception("Ürün talebi kaydedilirken hata")
            return jsonify({"success": False, "error": "Ürün talebi kaydedilemedi."}), 500
        finally:
            cursor.close()


@app.get("/admin/product-requests")
@admin_required
def admin_product_requests():
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute(
                """
                SELECT id, user_id, user_name, user_phone, product_name, status, created_at
                FROM product_requests
                ORDER BY created_at DESC, id DESC
                """
            )
            requests_list = cursor.fetchall()
            cursor.execute(
                """
                SELECT product_name, COUNT(*) AS request_count
                FROM product_requests
                GROUP BY product_name
                ORDER BY request_count DESC, MAX(created_at) DESC
                LIMIT 10
                """
            )
            top_requests = cursor.fetchall()
            return render_template(
                "admin/product_requests.html",
                product_requests=requests_list,
                top_requests=top_requests,
            )
        except Exception:
            logger.exception("Ürün talepleri listelenirken hata")
            flash("Ürün talepleri yüklenirken bir hata oluştu.", "error")
            return render_template(
                "admin/product_requests.html",
                product_requests=[],
                top_requests=[],
            )
        finally:
            cursor.close()


@app.post("/admin/product-requests/toggle/<int:request_id>")
@admin_required
def admin_toggle_product_request(request_id: int):
    with get_db() as conn:
        cursor = conn.cursor()
        try:
            cursor.execute(
                """
                UPDATE product_requests
                SET status = CASE WHEN status = 'COMPLETED' THEN 'PENDING' ELSE 'COMPLETED' END
                WHERE id = %s
                """,
                (request_id,),
            )
            conn.commit()
            flash("Talep durumu güncellendi.", "success")
        except Exception:
            conn.rollback()
            logger.exception("Ürün talebi durumu güncellenirken hata")
            flash("Durum güncellenemedi.", "error")
        finally:
            cursor.close()
    return redirect(url_for("admin_product_requests"))


@app.post("/admin/product-requests/delete/<int:request_id>")
@admin_required
def admin_delete_product_request(request_id: int):
    with get_db() as conn:
        cursor = conn.cursor()
        try:
            cursor.execute("DELETE FROM product_requests WHERE id = %s", (request_id,))
            conn.commit()
            flash("Ürün talebi silindi.", "success")
        except Exception:
            conn.rollback()
            logger.exception("Ürün talebi silinirken hata")
            flash("Ürün talebi silinemedi.", "error")
        finally:
            cursor.close()
    return redirect(url_for("admin_product_requests"))


def _serialize_order_rows(rows: List[Dict[str, Any]], *, for_json: bool = False) -> List[Dict[str, Any]]:
    orders_by_id: Dict[int, Dict[str, Any]] = {}
    ordered_ids: List[int] = []

    for row in rows:
        oid = int(row["order_id"])
        if oid not in orders_by_id:
            ordered_ids.append(oid)
            norm_status = normalize_order_status(row.get("status")) or "PENDING"
            created_dt = row.get("created_at")
            shipping_addr = (row.get("shipping_address") or "Belirtilmemiş").strip()
            lat = float(row["latitude"]) if row.get("latitude") is not None else None
            lng = float(row["longitude"]) if row.get("longitude") is not None else None

            if lat is not None and lng is not None:
                maps_target = f"{lat},{lng}"
            else:
                maps_target = quote_plus(shipping_addr)

            google_maps_url = f"https://www.google.com/maps/dir/?api=1&destination={maps_target}"
            google_maps_embed_url = f"https://maps.google.com/maps?q={maps_target}&hl=tr&z=15&output=embed"

            total_val = float(row["total_price"] or 0)
            delivery_fee_val = float(row.get("delivery_fee") or 0)
            subtotal_val = round(max(0.0, total_val - delivery_fee_val), 2)

            orders_by_id[oid] = {
                "order_id": oid,
                "total_price": total_val,
                "subtotal": subtotal_val,
                "delivery_fee": delivery_fee_val,
                "shipping_address": shipping_addr,
                "latitude": lat,
                "longitude": lng,
                "google_maps_url": google_maps_url,
                "google_maps_embed_url": google_maps_embed_url,
                "payment_method": row.get("payment_method") or "Nakit",
                "status": norm_status,
                "status_label": order_status_label(norm_status),
                "is_active": norm_status in ACTIVE_ORDER_STATUSES,
                "user_name": row.get("user_name") or "Misafir Kullanıcı",
                "user_email": row.get("user_email") or "-",
                "user_phone": (row.get("user_phone") or "").strip() or "-",
                "created_at": (
                    created_dt.strftime("%Y-%m-%d %H:%M:%S")
                    if (for_json and created_dt)
                    else created_dt
                ),
                "created_at_formatted": (
                    created_dt.strftime("%d.%m.%Y • %H:%M") if created_dt else "Tarih belirtilmedi"
                ),
                "total_quantity": 0,
                "items": [],
            }
        qty = int(row.get("quantity") or 0)
        unit_price = float(row.get("price") or 0)
        image_name = row.get("product_image")
        orders_by_id[oid]["total_quantity"] += qty
        orders_by_id[oid]["items"].append({
            "name": row.get("product_name") or "Ürün",
            "image": image_name,
            "image_url": url_for("static", filename=f"uploads/{image_name}") if image_name else None,
            "quantity": qty,
            "price": unit_price,
            "line_total": qty * unit_price,
        })

    return [orders_by_id[oid] for oid in ordered_ids]


def _get_order_dashboard_stats(cursor) -> Dict[str, Any]:
    cursor.execute(
        """
        SELECT status, COUNT(*) as cnt, COALESCE(SUM(total_price), 0) as total_sum
        FROM orders
        GROUP BY status
        """
    )
    counts = {code: 0 for code in ALL_ORDER_STATUSES}
    revenue = 0.0
    for row in cursor.fetchall():
        code = normalize_order_status(row["status"]) or "PENDING"
        cnt = int(row["cnt"] or 0)
        counts[code] = counts.get(code, 0) + cnt
        if code != "CANCELLED":
            revenue += float(row["total_sum"] or 0)

    active_count = counts["PENDING"] + counts["PREPARING"] + counts["ON_THE_WAY"]
    history_count = counts["DELIVERED"] + counts["CANCELLED"]
    return {
        "all": active_count + history_count,
        "active": active_count,
        "history": history_count,
        "pending": counts["PENDING"],
        "preparing": counts["PREPARING"],
        "on_way": counts["ON_THE_WAY"],
        "delivered": counts["DELIVERED"],
        "cancelled": counts["CANCELLED"],
        "revenue": revenue,
    }


@app.route("/admin/orders")
@admin_required
def admin_orders():
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            # Ana ekranda YALNIZCA aktif siparişler (eskiden yeniye - en uzun bekleyen en üstte)
            cursor.execute(
                """
                SELECT 
                    o.id as order_id, 
                    o.total_price, 
                    COALESCE(o.delivery_fee, 0.00) as delivery_fee,
                    o.shipping_address,
                    COALESCE(NULLIF(o.phone, ''), NULLIF(u.phone, ''), '') as user_phone,
                    o.latitude,
                    o.longitude,
                    o.payment_method,
                    o.status,
                    o.created_at, 
                    u.name as user_name,
                    u.email as user_email,
                    oi.quantity, 
                    oi.price, 
                    p.name as product_name,
                    p.image as product_image
                FROM orders o
                LEFT JOIN users u ON o.user_id = u.id
                JOIN order_items oi ON o.id = oi.order_id
                JOIN products p ON oi.product_id = p.id
                WHERE o.status IN ('PENDING', 'PREPARING', 'ON_THE_WAY')
                ORDER BY o.created_at ASC, o.id ASC
                """
            )
            active_orders = _serialize_order_rows(cursor.fetchall(), for_json=False)
            stats = _get_order_dashboard_stats(cursor)
            return render_template("admin/orders.html", active_orders=active_orders, stats=stats)
        except Exception:
            logger.exception("Admin siparişleri yüklenirken hata")
            flash("Siparişler yüklenemedi.", "error")
            return render_template(
                "admin/orders.html",
                active_orders=[],
                stats={
                    "all": 0,
                    "active": 0,
                    "history": 0,
                    "pending": 0,
                    "preparing": 0,
                    "on_way": 0,
                    "delivered": 0,
                    "cancelled": 0,
                    "revenue": 0.0,
                },
            )
        finally:
            cursor.close()


@app.get("/api/admin/orders/active")
@admin_required
def api_admin_active_orders():
    """
    Yalnızca aktif siparişleri ('PENDING', 'PREPARING', 'ON_THE_WAY')
    eskiden yeniye (en uzun süredir bekleyen en üstte) döner.
    """
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute(
                """
                SELECT 
                    o.id as order_id, 
                    o.total_price, 
                    COALESCE(o.delivery_fee, 0.00) as delivery_fee,
                    o.shipping_address,
                    COALESCE(NULLIF(o.phone, ''), NULLIF(u.phone, ''), '') as user_phone,
                    o.latitude,
                    o.longitude,
                    o.payment_method,
                    o.status,
                    o.created_at, 
                    u.name as user_name,
                    u.email as user_email,
                    oi.quantity, 
                    oi.price, 
                    p.name as product_name,
                    p.image as product_image
                FROM orders o
                LEFT JOIN users u ON o.user_id = u.id
                JOIN order_items oi ON o.id = oi.order_id
                JOIN products p ON oi.product_id = p.id
                WHERE o.status IN ('PENDING', 'PREPARING', 'ON_THE_WAY')
                ORDER BY o.created_at ASC, o.id ASC
                """
            )
            orders_list = _serialize_order_rows(cursor.fetchall(), for_json=True)
            stats = _get_order_dashboard_stats(cursor)
            return jsonify({
                "success": True,
                "active_count": stats["active"],
                "stats": stats,
                "orders": orders_list,
            }), 200
        except Exception:
            logger.exception("Aktif siparişler API hatası")
            return jsonify({"success": False, "error": "Aktif siparişler yüklenemedi."}), 500
        finally:
            cursor.close()


@app.get("/api/admin/orders/history")
@admin_required
def api_admin_history_orders():
    """
    Yalnızca tamamlanmış ve iptal edilen siparişleri ('DELIVERED', 'CANCELLED')
    yeniden eskiye sıralı, filtreleme ve sayfalama (pagination) destekli döner.
    """
    status_filter = (request.args.get("status") or "ALL").strip().upper()
    search_query = (request.args.get("search") or request.args.get("q") or "").strip()
    start_date = (request.args.get("start_date") or "").strip()
    end_date = (request.args.get("end_date") or "").strip()

    try:
        page = max(1, int(request.args.get("page", 1)))
    except ValueError:
        page = 1

    try:
        limit = min(100, max(1, int(request.args.get("limit", 10))))
    except ValueError:
        limit = 10

    where_clauses = []
    params: List[Any] = []

    normalized_filter = normalize_order_status(status_filter)
    if normalized_filter in HISTORY_ORDER_STATUSES:
        where_clauses.append("o.status = %s")
        params.append(normalized_filter)
    else:
        where_clauses.append("o.status IN ('DELIVERED', 'CANCELLED')")

    if start_date:
        where_clauses.append("DATE(o.created_at) >= %s")
        params.append(start_date)

    if end_date:
        where_clauses.append("DATE(o.created_at) <= %s")
        params.append(end_date)

    if search_query:
        cleaned_id = search_query.lstrip("#").strip()
        like_pattern = f"%{search_query}%"
        if cleaned_id.isdigit():
            where_clauses.append(
                """(
                    o.id = %s
                    OR COALESCE(u.name, '') LIKE %s
                    OR COALESCE(u.email, '') LIKE %s
                    OR COALESCE(o.shipping_address, '') LIKE %s
                    OR EXISTS (
                        SELECT 1 FROM order_items oi_s
                        JOIN products p_s ON oi_s.product_id = p_s.id
                        WHERE oi_s.order_id = o.id AND p_s.name LIKE %s
                    )
                )"""
            )
            params.extend([int(cleaned_id), like_pattern, like_pattern, like_pattern, like_pattern])
        else:
            where_clauses.append(
                """(
                    COALESCE(u.name, '') LIKE %s
                    OR COALESCE(u.email, '') LIKE %s
                    OR COALESCE(o.shipping_address, '') LIKE %s
                    OR EXISTS (
                        SELECT 1 FROM order_items oi_s
                        JOIN products p_s ON oi_s.product_id = p_s.id
                        WHERE oi_s.order_id = o.id AND p_s.name LIKE %s
                    )
                )"""
            )
            params.extend([like_pattern, like_pattern, like_pattern, like_pattern])

    where_sql = " AND ".join(where_clauses)

    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute(
                f"""
                SELECT COUNT(DISTINCT o.id) as total_items
                FROM orders o
                LEFT JOIN users u ON o.user_id = u.id
                WHERE {where_sql}
                """,
                tuple(params),
            )
            total_row = cursor.fetchone()
            total_items = int(total_row["total_items"] or 0) if total_row else 0
            total_pages = max(1, (total_items + limit - 1) // limit)
            if page > total_pages:
                page = total_pages
            offset = (page - 1) * limit

            cursor.execute(
                f"""
                SELECT o.id
                FROM orders o
                LEFT JOIN users u ON o.user_id = u.id
                WHERE {where_sql}
                ORDER BY o.created_at DESC, o.id DESC
                LIMIT %s OFFSET %s
                """,
                tuple(params + [limit, offset]),
            )
            page_ids = [int(r["id"]) for r in cursor.fetchall()]

            orders_list: List[Dict[str, Any]] = []
            if page_ids:
                id_placeholders = ", ".join(["%s"] * len(page_ids))
                cursor.execute(
                    f"""
                    SELECT 
                        o.id as order_id, 
                        o.total_price, 
                        COALESCE(o.delivery_fee, 0.00) as delivery_fee,
                        o.shipping_address,
                        COALESCE(NULLIF(o.phone, ''), NULLIF(u.phone, ''), '') as user_phone,
                        o.latitude,
                        o.longitude,
                        o.payment_method,
                        o.status,
                        o.created_at, 
                        u.name as user_name,
                        u.email as user_email,
                        oi.quantity, 
                        oi.price, 
                        p.name as product_name,
                        p.image as product_image
                    FROM orders o
                    LEFT JOIN users u ON o.user_id = u.id
                    JOIN order_items oi ON o.id = oi.order_id
                    JOIN products p ON oi.product_id = p.id
                    WHERE o.id IN ({id_placeholders})
                    ORDER BY o.created_at DESC, o.id DESC
                    """,
                    tuple(page_ids),
                )
                orders_list = _serialize_order_rows(cursor.fetchall(), for_json=True)

            stats = _get_order_dashboard_stats(cursor)
            return jsonify({
                "success": True,
                "orders": orders_list,
                "stats": stats,
                "pagination": {
                    "page": page,
                    "limit": limit,
                    "total_items": total_items,
                    "total_pages": total_pages,
                    "has_prev": page > 1,
                    "has_next": page < total_pages,
                },
            }), 200
        except Exception:
            logger.exception("Sipariş geçmişi API hatası")
            return jsonify({"success": False, "error": "Sipariş geçmişi yüklenemedi."}), 500
        finally:
            cursor.close()


# ---------------------------------------------------------------------------
# 6. Global Hata Yakalayıcılar
# ---------------------------------------------------------------------------
@app.errorhandler(404)
def handle_not_found(e):
    if request.path.startswith("/api/"):
        return jsonify({"error": "İstenen API kaynağı bulunamadı."}), 404
    return redirect(url_for("admin_login"))


@app.errorhandler(413)
def handle_file_too_large(e):
    if request.path.startswith("/api/"):
        return jsonify({"error": "Yüklenen dosya boyutu izin verilen sınırı (5MB) aşıyor."}), 413
    flash("Yüklenen dosya boyutu çok büyük (Maksimum 5 MB).", "error")
    return redirect(request.referrer or url_for("admin_products"))


@app.errorhandler(500)
def handle_internal_error(e):
    logger.exception(f"Kritik 500 hatası: {e}")
    if request.path.startswith("/api/"):
        return jsonify({"error": "Sunucuda beklenmeyen bir hata meydana geldi."}), 500
    return "Sunucuda beklenmeyen bir hata meydana geldi.", 500

def _perform_order_status_update(order_id: int, raw_status: str) -> Dict[str, Any]:
    new_status = normalize_order_status(raw_status)
    if not new_status or new_status not in ALL_ORDER_STATUSES:
        return {
            "success": False,
            "status_code": 400,
            "error": "Geçersiz sipariş durumu. İzin verilenler: PENDING, PREPARING, ON_THE_WAY, DELIVERED, CANCELLED.",
        }

    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            conn.start_transaction()
            cursor.execute(
                "SELECT status FROM orders WHERE id = %s FOR UPDATE",
                (order_id,),
            )
            order = cursor.fetchone()
            if not order:
                conn.rollback()
                return {
                    "success": False,
                    "status_code": 404,
                    "error": "Sipariş bulunamadı.",
                }

            old_status = normalize_order_status(order["status"]) or "PENDING"
            if old_status != new_status:
                cursor.execute(
                    "UPDATE orders SET status = %s WHERE id = %s",
                    (new_status, order_id),
                )
                # Sipariş iptal edildiyse stokları iade et
                if new_status == "CANCELLED" and old_status != "CANCELLED":
                    cursor.execute(
                        "SELECT product_id, quantity FROM order_items WHERE order_id = %s",
                        (order_id,),
                    )
                    for item in cursor.fetchall():
                        cursor.execute(
                            "UPDATE products SET stock = stock + %s WHERE id = %s",
                            (item["quantity"], item["product_id"]),
                        )
                # İptal edilmiş bir sipariş tekrar aktif/teslim duruma alınırsa stoktan düş
                elif old_status == "CANCELLED" and new_status != "CANCELLED":
                    cursor.execute(
                        "SELECT product_id, quantity FROM order_items WHERE order_id = %s",
                        (order_id,),
                    )
                    for item in cursor.fetchall():
                        cursor.execute(
                            "UPDATE products SET stock = GREATEST(0, stock - %s) WHERE id = %s",
                            (item["quantity"], item["product_id"]),
                        )

            conn.commit()
            stats = _get_order_dashboard_stats(cursor)
            status_label = order_status_label(new_status)
            return {
                "success": True,
                "status_code": 200,
                "order_id": order_id,
                "old_status": old_status,
                "status": new_status,
                "status_label": status_label,
                "is_active": new_status in ACTIVE_ORDER_STATUSES,
                "active_count": stats["active"],
                "stats": stats,
                "message": f"Sipariş #{order_id} durumu '{status_label}' olarak güncellendi.",
            }
        except Exception:
            conn.rollback()
            logger.exception("Sipariş durumu güncellenirken hata")
            return {
                "success": False,
                "status_code": 500,
                "error": "Sipariş durumu güncellenemedi.",
            }
        finally:
            cursor.close()


@app.route("/api/admin/orders/<int:order_id>/status", methods=["PATCH", "POST"])
@admin_required
def api_admin_update_order_status(order_id: int):
    payload = request.get_json(silent=True) or {}
    raw_status = (payload.get("status") or request.form.get("status") or "").strip()
    result = _perform_order_status_update(order_id, raw_status)
    http_code = result.pop("status_code", 200)
    return jsonify(result), http_code


@app.post("/admin/orders/status/<int:order_id>")
@admin_required
def admin_update_order_status(order_id: int):
    raw_status = request.form.get("status", "").strip()
    result = _perform_order_status_update(order_id, raw_status)
    if result.get("success"):
        flash(result["message"], "success")
    else:
        flash(result.get("error", "Sipariş durumu güncellenemedi."), "error")
    return redirect(url_for("admin_orders"))


# ---------------------------------------------------------------------------
# 6.1 Kurye Dağıtım Uygulaması (Sadece Teslim Edildi Yetkisi + Google Maps)
# ---------------------------------------------------------------------------
COURIER_PASSWORD = os.getenv("COURIER_PASSWORD") or ADMIN_PASSWORD


def courier_required(view):
    """Kurye veya Admin oturumu gerektiren görünümler ve API'ler için yetki kontrolü."""
    @wraps(view)
    def wrapped_view(*args, **kwargs):
        if not (session.get("courier_authenticated") or session.get("admin_authenticated")):
            if request.path.startswith("/api/courier"):
                return jsonify({"success": False, "error": "Yetkisiz erişim. Lütfen kurye girişi yapın."}), 401
            return redirect(url_for("courier_login"))
        return view(*args, **kwargs)

    return wrapped_view


@app.route("/kurye/login", methods=["GET", "POST"])
@app.route("/courier/login", methods=["GET", "POST"])
def courier_login():
    if session.get("courier_authenticated") or session.get("admin_authenticated"):
        return redirect(url_for("courier_dashboard"))

    if request.method == "POST":
        client_ip = _get_client_ip()
        now = datetime.datetime.utcnow()

        with get_db() as conn:
            cursor = conn.cursor(dictionary=True)
            cursor.execute(
                "SELECT failed_count, locked_until FROM admin_login_attempts WHERE ip_address = %s",
                (client_ip,),
            )
            attempt_row = cursor.fetchone()

            if attempt_row and attempt_row["locked_until"] and attempt_row["locked_until"] > now:
                remaining_seconds = int((attempt_row["locked_until"] - now).total_seconds())
                remaining_minutes = max(1, (remaining_seconds + 59) // 60)
                cursor.close()
                flash(
                    f"Çok fazla başarısız deneme! Lütfen {remaining_minutes} dakika sonra tekrar deneyin.",
                    "error",
                )
                return render_template("courier/login.html"), 429

            password = request.form.get("password", "")
            if secrets.compare_digest(password, COURIER_PASSWORD) or secrets.compare_digest(
                password, ADMIN_PASSWORD
            ):
                cursor.execute(
                    "DELETE FROM admin_login_attempts WHERE ip_address = %s",
                    (client_ip,),
                )
                conn.commit()
                cursor.close()
                session["courier_authenticated"] = True
                return redirect(url_for("courier_dashboard"))

            prev_failed = attempt_row["failed_count"] if attempt_row else 0
            if attempt_row and attempt_row["locked_until"] and attempt_row["locked_until"] <= now:
                prev_failed = 0
            new_failed = prev_failed + 1

            if new_failed >= ADMIN_MAX_FAILED_ATTEMPTS:
                locked_until = now + datetime.timedelta(minutes=ADMIN_LOCKOUT_MINUTES)
                cursor.execute(
                    """
                    INSERT INTO admin_login_attempts (ip_address, failed_count, locked_until)
                    VALUES (%s, %s, %s)
                    ON DUPLICATE KEY UPDATE failed_count = VALUES(failed_count), locked_until = VALUES(locked_until)
                    """,
                    (client_ip, new_failed, locked_until),
                )
                conn.commit()
                cursor.close()
                flash(
                    f"5 kez hatalı şifre girdiniz. IP adresiniz {ADMIN_LOCKOUT_MINUTES} dakika kilitlendi.",
                    "error",
                )
                return render_template("courier/login.html"), 429
            else:
                cursor.execute(
                    """
                    INSERT INTO admin_login_attempts (ip_address, failed_count, locked_until)
                    VALUES (%s, %s, NULL)
                    ON DUPLICATE KEY UPDATE failed_count = VALUES(failed_count), locked_until = NULL
                    """,
                    (client_ip, new_failed),
                )
                conn.commit()
                cursor.close()
                remaining_attempts = ADMIN_MAX_FAILED_ATTEMPTS - new_failed
                flash(f"Kurye şifresi hatalı. (Kalan deneme hakkı: {remaining_attempts})", "error")

    return render_template("courier/login.html")


@app.get("/kurye/logout")
@app.get("/courier/logout")
def courier_logout():
    session.pop("courier_authenticated", None)
    flash("Kurye oturumu kapatıldı.", "success")
    return redirect(url_for("courier_login"))


@app.get("/kurye")
@app.get("/courier")
@courier_required
def courier_dashboard():
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute(
                """
                SELECT 
                    o.id as order_id, 
                    o.total_price, 
                    COALESCE(o.delivery_fee, 0.00) as delivery_fee,
                    o.shipping_address,
                    COALESCE(NULLIF(o.phone, ''), NULLIF(u.phone, ''), '') as user_phone,
                    o.latitude,
                    o.longitude,
                    o.payment_method,
                    o.status,
                    o.created_at, 
                    u.name as user_name,
                    u.email as user_email,
                    oi.quantity, 
                    oi.price, 
                    p.name as product_name,
                    p.image as product_image
                FROM orders o
                LEFT JOIN users u ON o.user_id = u.id
                JOIN order_items oi ON o.id = oi.order_id
                JOIN products p ON oi.product_id = p.id
                WHERE o.status IN ('PENDING', 'PREPARING', 'ON_THE_WAY')
                ORDER BY o.created_at ASC, o.id ASC
                """
            )
            active_orders = _serialize_order_rows(cursor.fetchall(), for_json=False)
            return render_template("courier/orders.html", active_orders=active_orders)
        except Exception:
            logger.exception("Kurye siparişleri yüklenirken hata")
            return render_template("courier/orders.html", active_orders=[])
        finally:
            cursor.close()


@app.get("/api/courier/orders")
@courier_required
def api_courier_active_orders():
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute(
                """
                SELECT 
                    o.id as order_id, 
                    o.total_price, 
                    COALESCE(o.delivery_fee, 0.00) as delivery_fee,
                    o.shipping_address,
                    COALESCE(NULLIF(o.phone, ''), NULLIF(u.phone, ''), '') as user_phone,
                    o.latitude,
                    o.longitude,
                    o.payment_method,
                    o.status,
                    o.created_at, 
                    u.name as user_name,
                    u.email as user_email,
                    oi.quantity, 
                    oi.price, 
                    p.name as product_name,
                    p.image as product_image
                FROM orders o
                LEFT JOIN users u ON o.user_id = u.id
                JOIN order_items oi ON o.id = oi.order_id
                JOIN products p ON oi.product_id = p.id
                WHERE o.status IN ('PENDING', 'PREPARING', 'ON_THE_WAY')
                ORDER BY o.created_at ASC, o.id ASC
                """
            )
            orders_list = _serialize_order_rows(cursor.fetchall(), for_json=True)
            return jsonify({
                "success": True,
                "active_count": len(orders_list),
                "orders": orders_list,
            }), 200
        except Exception:
            logger.exception("Kurye aktif sipariş API hatası")
            return jsonify({"success": False, "error": "Siparişler yüklenemedi."}), 500
        finally:
            cursor.close()


@app.post("/api/courier/orders/<int:order_id>/deliver")
@courier_required
def api_courier_deliver_order(order_id: int):
    """
    Kurye uygulaması YALNIZCA siparişi 'DELIVERED' (Teslim Edildi) durumuna çevirebilir.
    İptal etme veya başka bir duruma alma yetkisi yoktur.
    """
    result = _perform_order_status_update(order_id, "DELIVERED")
    http_code = result.pop("status_code", 200)
    return jsonify(result), http_code

# --- KATEGORİ DÜZENLEME ---
@app.route("/admin/categories/edit/<int:category_id>", methods=["GET", "POST"])
@admin_required
def admin_edit_category(category_id: int):
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute("SELECT * FROM categories WHERE id = %s", (category_id,))
            category = cursor.fetchone()
            
            if not category:
                flash("Kategori bulunamadı.", "error")
                return redirect(url_for("admin_categories"))

            if request.method == "POST":
                name = request.form.get("name", "").strip()
                if not name:
                    flash("Kategori adı boş olamaz.", "error")
                else:
                    cursor.execute("UPDATE categories SET name = %s WHERE id = %s", (name, category_id))
                    conn.commit()
                    flash("Kategori adı başarıyla güncellendi.", "success")
                    return redirect(url_for("admin_categories"))

            return render_template("admin/edit_category.html", category=category)
        except Exception as e:
            conn.rollback()
            flash(f"İşlem sırasında hata oluştu: {str(e)}", "error")
            return redirect(url_for("admin_categories"))
        finally:
            cursor.close()


# --- KATEGORİ SİLME ---
@app.post("/admin/categories/delete/<int:category_id>")
@admin_required
def admin_delete_category(category_id: int):
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            # Güvenlik Kontrolü: Kategoriye bağlı ürün var mı?
            cursor.execute("SELECT COUNT(*) as count FROM products WHERE category_id = %s", (category_id,))
            result = cursor.fetchone()
            
            if result and result["count"] > 0:
                flash(f"Bu kategori silinemez! İçinde {result['count']} adet ürün bulunuyor. Önce ürünlerin kategorisini değiştirin.", "error")
                return redirect(url_for("admin_categories"))

            cursor.execute("DELETE FROM categories WHERE id = %s", (category_id,))
            conn.commit()
            flash("Kategori başarıyla silindi.", "success")
        except Exception as e:
            conn.rollback()
            flash("Kategori silinirken veritabanı hatası oluştu.", "error")
        finally:
            cursor.close()
            
    return redirect(url_for("admin_categories"))


# --- KAMPANYA YÖNETİMİ (ADMIN) ---
@app.get("/admin/weekly-deals")
@admin_required
def admin_weekly_deals():
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute(
                """
                SELECT products.id, products.name, products.price, products.stock,
                       products.active, products.image, categories.name AS category
                FROM weekly_deal_products
                JOIN products ON products.id = weekly_deal_products.product_id
                LEFT JOIN categories ON categories.id = products.category_id
                ORDER BY weekly_deal_products.position, weekly_deal_products.added_at
                """
            )
            weekly_products = cursor.fetchall()
            cursor.execute(
                """
                SELECT products.id, products.name, products.price, products.stock,
                       categories.name AS category
                FROM products
                LEFT JOIN categories ON categories.id = products.category_id
                LEFT JOIN weekly_deal_products
                    ON weekly_deal_products.product_id = products.id
                WHERE products.active = TRUE AND weekly_deal_products.product_id IS NULL
                ORDER BY products.name
                """
            )
            available_products = cursor.fetchall()
            return render_template(
                "admin/weekly_deals.html",
                weekly_products=weekly_products,
                available_products=available_products,
            )
        except Exception:
            logger.exception("Haftanın indirimleri admin panelinde listelenemedi")
            flash("Haftanın indirimleri yüklenirken bir hata oluştu.", "error")
            return render_template(
                "admin/weekly_deals.html",
                weekly_products=[],
                available_products=[],
            )
        finally:
            cursor.close()


@app.post("/admin/weekly-deals/add")
@admin_required
def admin_add_weekly_deal():
    product_id = request.form.get("product_id", type=int)
    if product_id is None:
        flash("Eklemek için geçerli bir ürün seçin.", "error")
        return redirect(url_for("admin_weekly_deals"))

    with get_db() as conn:
        cursor = conn.cursor()
        try:
            cursor.execute(
                "SELECT id FROM products WHERE id = %s AND active = TRUE",
                (product_id,),
            )
            if not cursor.fetchone():
                flash("Ürün bulunamadı veya yayında değil.", "error")
                return redirect(url_for("admin_weekly_deals"))

            cursor.execute(
                "SELECT COALESCE(MAX(position), -1) + 1 FROM weekly_deal_products"
            )
            position = cursor.fetchone()[0]
            cursor.execute(
                """
                INSERT IGNORE INTO weekly_deal_products (product_id, position)
                VALUES (%s, %s)
                """,
                (product_id, position),
            )
            if cursor.rowcount:
                conn.commit()
                flash("Ürün haftanın indirimlerine eklendi.", "success")
            else:
                flash("Bu ürün haftanın indirimlerinde zaten bulunuyor.", "error")
        except Exception:
            conn.rollback()
            logger.exception("Haftanın indirimlerine ürün eklenemedi")
            flash("Ürün haftanın indirimlerine eklenemedi.", "error")
        finally:
            cursor.close()
    return redirect(url_for("admin_weekly_deals"))


@app.post("/admin/weekly-deals/remove/<int:product_id>")
@admin_required
def admin_remove_weekly_deal(product_id: int):
    with get_db() as conn:
        cursor = conn.cursor()
        try:
            cursor.execute(
                "DELETE FROM weekly_deal_products WHERE product_id = %s",
                (product_id,),
            )
            if cursor.rowcount:
                conn.commit()
                flash("Ürün haftanın indirimlerinden çıkarıldı.", "success")
            else:
                flash("Ürün haftanın indirimlerinde bulunamadı.", "error")
        except Exception:
            conn.rollback()
            logger.exception("Haftanın indirimlerinden ürün çıkarılamadı")
            flash("Ürün haftanın indirimlerinden çıkarılamadı.", "error")
        finally:
            cursor.close()
    return redirect(url_for("admin_weekly_deals"))


@app.route("/admin/campaigns", methods=["GET", "POST"])
@admin_required
def admin_campaigns():
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        if request.method == "POST":
            title = request.form.get("title", "").strip()
            description = request.form.get("description", "").strip()
            badge_text = request.form.get("badge_text", "").strip()
            image = request.files.get("image")

            if not title:
                flash("Kampanya başlığı zorunludur.", "error")
                cursor.close()
                return redirect(url_for("admin_campaigns"))

            filename = None
            file_path = None
            if image and image.filename:
                safe_name = secure_filename(image.filename)
                extension = safe_name.rsplit(".", 1)[-1].lower() if "." in safe_name else ""
                if extension not in ALLOWED_IMAGE_EXTENSIONS:
                    flash("Sadece JPG, JPEG, PNG, WEBP veya GIF görselleri yükleyebilirsiniz.", "error")
                    cursor.close()
                    return redirect(url_for("admin_campaigns"))
                filename = f"{uuid4().hex}.{extension}"
                file_path = os.path.join(UPLOAD_FOLDER, filename)
                image.save(file_path)

            try:
                cursor.execute(
                    """
                    INSERT INTO campaigns (title, description, badge_text, image, active)
                    VALUES (%s, %s, %s, %s, TRUE)
                    """,
                    (title, description, badge_text or None, filename),
                )
                conn.commit()
                flash("Kampanya başarıyla oluşturuldu.", "success")
            except Exception:
                conn.rollback()
                if file_path and os.path.exists(file_path):
                    os.remove(file_path)
                logger.exception("Kampanya ekleme hatası")
                flash("Kampanya kaydedilemedi.", "error")
            finally:
                cursor.close()

            return redirect(url_for("admin_campaigns"))

        try:
            cursor.execute(
                """
                SELECT id, title, description, badge_text, image, active, created_at
                FROM campaigns
                ORDER BY id DESC
                """
            )
            campaigns = cursor.fetchall()
            return render_template("admin/campaigns.html", campaigns=campaigns)
        except Exception:
            logger.exception("Kampanyalar listelenirken hata")
            flash("Kampanyalar yüklenirken bir hata oluştu.", "error")
            return render_template("admin/campaigns.html", campaigns=[])
        finally:
            cursor.close()


@app.route("/admin/campaigns/edit/<int:campaign_id>", methods=["GET", "POST"])
@admin_required
def admin_edit_campaign(campaign_id: int):
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)

        if request.method == "POST":
            title = request.form.get("title", "").strip()
            description = request.form.get("description", "").strip()
            badge_text = request.form.get("badge_text", "").strip()
            image = request.files.get("image")

            if not title:
                flash("Kampanya başlığı boş bırakılamaz.", "error")
                cursor.close()
                return redirect(url_for("admin_edit_campaign", campaign_id=campaign_id))

            cursor.execute("SELECT image FROM campaigns WHERE id = %s", (campaign_id,))
            campaign = cursor.fetchone()
            if not campaign:
                cursor.close()
                flash("Kampanya bulunamadı.", "error")
                return redirect(url_for("admin_campaigns"))

            image_filename = campaign["image"]
            new_image_path = None

            if image and image.filename:
                safe_name = secure_filename(image.filename)
                extension = safe_name.rsplit(".", 1)[-1].lower() if "." in safe_name else ""
                if extension not in ALLOWED_IMAGE_EXTENSIONS:
                    cursor.close()
                    flash("Geçersiz görsel formatı.", "error")
                    return redirect(url_for("admin_edit_campaign", campaign_id=campaign_id))
                image_filename = f"{uuid4().hex}.{extension}"
                new_image_path = os.path.join(UPLOAD_FOLDER, image_filename)
                image.save(new_image_path)

            try:
                cursor.execute(
                    """
                    UPDATE campaigns
                    SET title = %s, description = %s, badge_text = %s, image = %s
                    WHERE id = %s
                    """,
                    (title, description, badge_text or None, image_filename, campaign_id),
                )
                conn.commit()
                if new_image_path and campaign["image"]:
                    old_image_path = os.path.join(UPLOAD_FOLDER, campaign["image"])
                    if os.path.exists(old_image_path):
                        os.remove(old_image_path)
                flash("Kampanya başarıyla güncellendi.", "success")
            except Exception:
                conn.rollback()
                if new_image_path and os.path.exists(new_image_path):
                    os.remove(new_image_path)
                logger.exception("Kampanya güncelleme hatası")
                flash("Kampanya güncellenemedi.", "error")
            finally:
                cursor.close()
            return redirect(url_for("admin_campaigns"))

        cursor.execute("SELECT * FROM campaigns WHERE id = %s", (campaign_id,))
        campaign = cursor.fetchone()
        cursor.close()
        if not campaign:
            flash("Kampanya bulunamadı.", "error")
            return redirect(url_for("admin_campaigns"))
        return render_template("admin/edit_campaign.html", campaign=campaign)


@app.post("/admin/campaigns/toggle/<int:campaign_id>")
@admin_required
def admin_toggle_campaign(campaign_id: int):
    with get_db() as conn:
        cursor = conn.cursor()
        try:
            cursor.execute("UPDATE campaigns SET active = NOT active WHERE id = %s", (campaign_id,))
            conn.commit()
            flash("Kampanya yayın durumu güncellendi.", "success")
        except Exception:
            conn.rollback()
            logger.exception("Kampanya aktif/pasif durumu güncellenirken hata")
            flash("İşlem gerçekleştirilemedi.", "error")
        finally:
            cursor.close()
    return redirect(url_for("admin_campaigns"))


@app.post("/admin/campaigns/delete/<int:campaign_id>")
@admin_required
def admin_delete_campaign(campaign_id: int):
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute("SELECT image FROM campaigns WHERE id = %s", (campaign_id,))
            campaign = cursor.fetchone()
            cursor.execute("DELETE FROM campaigns WHERE id = %s", (campaign_id,))
            conn.commit()
            if campaign and campaign.get("image"):
                image_path = os.path.join(UPLOAD_FOLDER, campaign["image"])
                if os.path.exists(image_path):
                    os.remove(image_path)
            flash("Kampanya silindi.", "success")
        except Exception:
            conn.rollback()
            logger.exception("Kampanya silinirken hata")
            flash("Kampanya silinemedi.", "error")
        finally:
            cursor.close()
    return redirect(url_for("admin_campaigns"))

def _keep_adb_reverse_alive(port: int = 5000) -> None:
    """USB ile bağlı Android cihazlar için adb reverse tcp:5000 tcp:5000 köprüsünü sürekli aktif tutar."""
    adb_path = shutil.which("adb")
    if not adb_path:
        default_sdk_adb = os.path.expanduser(
            r"~\AppData\Local\Android\Sdk\platform-tools\adb.exe"
        )
        if os.path.exists(default_sdk_adb):
            adb_path = default_sdk_adb
    if not adb_path:
        return
    while True:
        try:
            subprocess.run(
                [adb_path, "reverse", f"tcp:{port}", f"tcp:{port}"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=5,
                check=False,
            )
        except Exception:
            pass
        time.sleep(5)


threading.Thread(target=_keep_adb_reverse_alive, daemon=True).start()

if __name__ == "__main__":
    app.run(debug=False, host="0.0.0.0", port=5000)