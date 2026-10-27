import datetime
import logging
import os
import secrets
import shutil
import subprocess
import threading
import time
from contextlib import contextmanager
from decimal import Decimal
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
            CREATE TABLE IF NOT EXISTS products (
                id INT AUTO_INCREMENT PRIMARY KEY,
                name VARCHAR(150) NOT NULL,
                description TEXT,
                price DECIMAL(10, 2) NOT NULL,
                category_id INT NOT NULL,
                image VARCHAR(255) NOT NULL,
                stock INT NOT NULL DEFAULT 0,
                active BOOLEAN NOT NULL DEFAULT TRUE,
                FOREIGN KEY (category_id) REFERENCES categories(id)
            )
            """
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
        cursor.execute("SHOW COLUMNS FROM orders LIKE 'payment_method'")
        if not cursor.fetchone():
            cursor.execute(
                "ALTER TABLE orders ADD COLUMN payment_method VARCHAR(50) NOT NULL DEFAULT 'Nakit' AFTER shipping_address"
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
            CREATE TABLE IF NOT EXISTS admin_login_attempts (
                ip_address VARCHAR(64) PRIMARY KEY,
                failed_count INT NOT NULL DEFAULT 0,
                locked_until DATETIME NULL,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
            )
            """
        )
        conn.commit()
        cursor.close()


init_database_schema()

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


class OrderItemRequest(BaseModel):
    product_id: int = Field(gt=0, strict=True)
    quantity: int = Field(gt=0, le=2147483647, strict=True)


class CreateOrderRequest(BaseModel):
    items: List[OrderItemRequest] = Field(min_length=1, max_length=100)
    address_id: Optional[int] = Field(default=None)
    shipping_address: Optional[str] = Field(default=None, max_length=500)
    full_address: Optional[str] = Field(default=None, max_length=500)
    latitude: Optional[float] = Field(default=None)
    longitude: Optional[float] = Field(default=None)
    payment_method: Optional[str] = Field(default="Nakit", max_length=50)


# ---------------------------------------------------------------------------
# 3. Güvenlik, CSRF ve JWT Yardımcıları
# ---------------------------------------------------------------------------
def generate_jwt_token(user_id: int, email: str, name: str) -> str:
    """Kullanıcı için 7 gün geçerli imzalı JWT erişim token'ı oluşturur."""
    payload = {
        "user_id": user_id,
        "email": email,
        "name": name,
        "exp": datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=7),
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


@app.get("/api/categories")
def api_categories():
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            cursor.execute("SELECT id, name FROM categories ORDER BY name ASC")
            categories = cursor.fetchall()
            return jsonify(categories)
        except Exception:
            logger.exception("Kategoriler getirilirken hata")
            return jsonify({"error": "Kategoriler yüklenemedi."}), 500
        finally:
            cursor.close()


@app.get("/api/products")
def api_products():
    category_id = request.args.get("category_id")
    search_q = request.args.get("q", "").strip()

    try:
        limit = min(max(int(request.args.get("limit", 100)), 1), 200)
        page = max(int(request.args.get("page", 1)), 1)
        offset = (page - 1) * limit
    except ValueError:
        limit = 100
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
                    categories.name AS category
                FROM products
                JOIN categories ON products.category_id = categories.id
                WHERE products.active = TRUE
            """
            params: List[Any] = []

            if category_id:
                base_query += " AND products.category_id = %s"
                params.append(int(category_id))

            if search_q:
                base_query += " AND (products.name LIKE %s OR products.description LIKE %s)"
                params.extend([f"%{search_q}%", f"%{search_q}%"])

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
                SELECT id, name, price, stock
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
            order_details = []
            for product_id, quantity in quantities_by_product.items():
                product = products_db[product_id]
                item_price = Decimal(str(product["price"])).quantize(Decimal("0.01"))
                total_price += item_price * quantity
                order_details.append({
                    "product_id": product_id,
                    "quantity": quantity,
                    "price": item_price,
                })

            if total_price > Decimal("99999999.99"):
                conn.rollback()
                return jsonify({"error": "Sipariş toplamı izin verilen tutarı aşıyor."}), 400

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

            cursor.execute(
                """
                INSERT INTO orders (user_id, total_price, shipping_address, latitude, longitude, payment_method, status) 
                VALUES (%s, %s, %s, %s, %s, %s, 'PENDING')
                """,
                (user_id, total_price, shipping_address, order_lat, order_lng, payment_method),
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
                f"Tutar: {total_price} TL, Ödeme: {payment_method}"
            )
            return jsonify({
                "success": True,
                "order_id": order_id,
                "total_price": float(total_price),
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
            )
        finally:
            cursor.close()


@app.route("/admin/products", methods=["GET", "POST"])
@admin_required
def admin_products():
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        if request.method == "POST":
            name = request.form.get("name", "").strip()
            description = request.form.get("description", "").strip()
            category_id = request.form.get("category_id", "").strip()
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
                    INSERT INTO products (name, description, price, image, stock, category_id, active)
                    VALUES (%s, %s, %s, %s, %s, %s, TRUE)
                    """,
                    (name, description, price, filename, stock, int(category_id)),
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
                       p.active, c.name AS category
                FROM products p
                LEFT JOIN categories c ON c.id = p.category_id
                ORDER BY p.id DESC
                """
            )
            products = cursor.fetchall()
            cursor.execute("SELECT id, name FROM categories ORDER BY name")
            categories = cursor.fetchall()
            return render_template("admin/products.html", products=products, categories=categories)
        except Exception:
            logger.exception("Ürün listesi getirilirken hata")
            flash("Ürünler listelenirken bir hata oluştu.", "error")
            return render_template("admin/products.html", products=[], categories=[])
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
                        category_id = %s, image = %s
                    WHERE id = %s
                    """,
                    (name, description, price, stock, int(category_id), image_filename, product_id),
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
        cursor.close()
        if not product:
            flash("Ürün bulunamadı.", "error")
            return redirect(url_for("admin_products"))
        return render_template("admin/edit_product.html", product=product, categories=categories)


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
            return render_template("admin/categories.html", categories=categories)
        except Exception:
            logger.exception("Kategoriler listelenirken hata")
            flash("Kategoriler yüklenirken hata oluştu.", "error")
            return render_template("admin/categories.html", categories=[])
        finally:
            cursor.close()


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

            orders_by_id[oid] = {
                "order_id": oid,
                "total_price": float(row["total_price"] or 0),
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
                    o.shipping_address,
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
                    o.shipping_address,
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
                        o.shipping_address,
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
                    o.shipping_address,
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
                    o.shipping_address,
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
    app.run(debug=True, host="0.0.0.0", port=5000)