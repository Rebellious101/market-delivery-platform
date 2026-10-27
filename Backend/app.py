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
                status VARCHAR(50) NOT NULL DEFAULT 'Hazırlanıyor',
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
    shipping_address: Optional[str] = Field(default=None, max_length=500)
    full_address: Optional[str] = Field(default=None, max_length=500)
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
    """Admin panelindeki tüm POST isteklerinde CSRF token doğrulaması yapar."""
    if request.method == "POST" and request.path.startswith("/admin"):
        token = request.form.get("csrf_token")
        session_token = session.get("_csrf_token")
        if not token or not session_token or not secrets.compare_digest(token, session_token):
            logger.warning(f"CSRF doğrulama hatası tespit edildi: {request.path}")
            flash("Güvenlik oturumu doğrulanamadı (CSRF). Lütfen formu tekrar gönderin.", "error")
            return redirect(request.referrer or url_for("admin_dashboard"))


def admin_required(view):
    """Admin oturumu gerektiren görünümler için yetki kontrolü."""
    @wraps(view)
    def wrapped_view(*args, **kwargs):
        if not session.get("admin_authenticated"):
            return redirect(url_for("admin_login", next=request.path))
        return view(*args, **kwargs)

    return wrapped_view


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

            # 3. Ana siparişi kullanıcı kimliği, adres ve ödeme yöntemiyle kaydet
            payment_method = (req.payment_method or "Nakit").strip() or "Nakit"
            cursor.execute(
                """
                INSERT INTO orders (user_id, total_price, shipping_address, payment_method, status) 
                VALUES (%s, %s, %s, %s, 'Hazırlanıyor')
                """,
                (user_id, total_price, shipping_address, payment_method),
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
                "status": "Hazırlanıyor",
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
                    orders[oid] = {
                        "order_id": oid,
                        "total_price": float(row["total_price"]),
                        "shipping_address": row["shipping_address"] or "",
                        "payment_method": row["payment_method"] or "Nakit",
                        "status": row["status"] or "Hazırlanıyor",
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

@app.route("/admin/login", methods=["GET", "POST"])
def admin_login():
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        if secrets.compare_digest(username, ADMIN_USERNAME) and secrets.compare_digest(
            password, ADMIN_PASSWORD
        ):
            session.clear()
            session["admin_authenticated"] = True
            session["admin_username"] = username
            next_url = request.args.get("next") or request.form.get("next")
            if not next_url or not next_url.startswith("/admin") or next_url == "/admin/login":
                next_url = url_for("admin_dashboard")
            return redirect(next_url)
        flash("Kullanıcı adı veya şifre hatalı.", "error")
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


@app.route("/admin/orders")
@admin_required
def admin_orders():
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
                    u.name as user_name,
                    u.email as user_email,
                    oi.quantity, 
                    oi.price, 
                    p.name as product_name 
                FROM orders o
                LEFT JOIN users u ON o.user_id = u.id
                JOIN order_items oi ON o.id = oi.order_id
                JOIN products p ON oi.product_id = p.id
                ORDER BY o.created_at DESC
                """
            )
            rows = cursor.fetchall()

            orders: Dict[int, Dict[str, Any]] = {}
            for row in rows:
                oid = row["order_id"]
                if oid not in orders:
                    orders[oid] = {
                        "order_id": oid,
                        "total_price": float(row["total_price"]),
                        "shipping_address": row["shipping_address"] or "Belirtilmemiş",
                        "payment_method": row["payment_method"] or "Nakit",
                        "status": row["status"] or "Hazırlanıyor",
                        "user_name": row["user_name"] or "Misafir Kullanıcı",
                        "user_email": row["user_email"] or "-",
                        "created_at": row["created_at"],
                        "items": [],
                    }
                orders[oid]["items"].append({
                    "name": row["product_name"],
                    "quantity": row["quantity"],
                    "price": float(row["price"]),
                })
            return render_template("admin/orders.html", orders=orders)
        except Exception:
            logger.exception("Admin siparişleri yüklenirken hata")
            flash("Siparişler yüklenemedi.", "error")
            return render_template("admin/orders.html", orders={})
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

@app.post("/admin/orders/status/<int:order_id>")
@admin_required
def admin_update_order_status(order_id: int):
    new_status = request.form.get("status", "").strip()
    valid_statuses = {"Hazırlanıyor", "Yolda", "Teslim Edildi", "İptal Edildi"}

    if new_status in valid_statuses:
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
                    flash("Sipariş bulunamadı.", "error")
                    return redirect(url_for("admin_orders"))

                old_status = order["status"]
                if old_status != new_status:
                    cursor.execute(
                        "UPDATE orders SET status = %s WHERE id = %s",
                        (new_status, order_id),
                    )
                    # Sipariş iptal edildiyse stokları iade et
                    if new_status == "İptal Edildi" and old_status != "İptal Edildi":
                        cursor.execute(
                            "SELECT product_id, quantity FROM order_items WHERE order_id = %s",
                            (order_id,),
                        )
                        for item in cursor.fetchall():
                            cursor.execute(
                                "UPDATE products SET stock = stock + %s WHERE id = %s",
                                (item["quantity"], item["product_id"]),
                            )
                    # İptal edilmiş bir sipariş tekrar aktif duruma alınırsa stoktan düş
                    elif old_status == "İptal Edildi" and new_status != "İptal Edildi":
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
                flash(f"Sipariş #{order_id} durumu '{new_status}' olarak güncellendi.", "success")
            except Exception:
                conn.rollback()
                flash("Sipariş durumu güncellenemedi.", "error")
            finally:
                cursor.close()
    return redirect(url_for("admin_orders"))

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