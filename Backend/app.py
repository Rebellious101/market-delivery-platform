import datetime
import logging
import os
import secrets
from contextlib import contextmanager
from functools import wraps
from typing import Any, Dict, List, Optional
from uuid import uuid4

import jwt
from flask_jwt_extended import JWTManager, jwt_required, get_jwt_identity
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
load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger("market_app")

app = Flask(__name__)
app.config["SECRET_KEY"] = os.getenv("FLASK_SECRET_KEY", "default-dev-key-change-in-production")
app.config["SESSION_COOKIE_HTTPONLY"] = True
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
app.config["MAX_CONTENT_LENGTH"] = 5 * 1024 * 1024  # Maksimum 5 MB dosya yükleme sınırı
app.config["JWT_SECRET_KEY"] = os.getenv("JWT_SECRET_KEY", "default-jwt-dev-secret-change-it")

JWT_SECRET_KEY = app.config["JWT_SECRET_KEY"]
jwt_manager = JWTManager(app)
ADMIN_USERNAME = os.getenv("ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "admin123")

UPLOAD_FOLDER = os.path.join(app.root_path, "static", "uploads")
ALLOWED_IMAGE_EXTENSIONS = {"jpg", "jpeg", "png", "webp", "gif"}
os.makedirs(UPLOAD_FOLDER, exist_ok=True)

# ---------------------------------------------------------------------------
# 1. MySQL Bağlantı Havuzu (Thread-Safe Connection Pool)
# ---------------------------------------------------------------------------
try:
    db_pool = pooling.MySQLConnectionPool(
        pool_name="market_pool",
        pool_size=10,
        pool_reset_session=True,
        host=os.getenv("DB_HOST", "localhost"),
        port=int(os.getenv("DB_PORT", 3306)),
        user=os.getenv("DB_USER", "market_admin"),
        password=os.getenv("DB_PASSWORD", ""),
        database=os.getenv("DB_NAME", "market_db"),
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
                status VARCHAR(50) NOT NULL DEFAULT 'Hazırlanıyor',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
            )
            """
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
    product_id: int = Field(gt=0)
    quantity: int = Field(gt=0)


class CreateOrderRequest(BaseModel):
    items: List[OrderItemRequest] = Field(min_length=1)
    shipping_address: Optional[str] = Field(default=None, max_length=500)


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
    shipping_address = req.shipping_address or ""

    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        try:
            # 1. Ürün bilgisi ve fiyatlarını al
            p_ids = [item.product_id for item in req.items]
            format_strings = ",".join(["%s"] * len(p_ids))
            cursor.execute(
                f"SELECT id, name, price, stock FROM products WHERE id IN ({format_strings}) AND active = TRUE",
                tuple(p_ids),
            )
            products_db = {p["id"]: p for p in cursor.fetchall()}

            # Tüm istenen ürünler mevcut mu kontrol et
            for item in req.items:
                if item.product_id not in products_db:
                    return jsonify({"error": f"Ürün bulunamadı veya satışta değil (ID: {item.product_id})"}), 404

            total_price = 0.0
            order_details = []

            # 2. Stokları atomik düşür ve toplam tutarı hesapla
            for item in req.items:
                pid = item.product_id
                qty = item.quantity
                prod = products_db[pid]
                item_price = float(prod["price"])
                total_price += item_price * qty

                # Atomik Stok Güncellemesi: Eşzamanlı iki işlemde stok eksiye düşemez
                cursor.execute(
                    """
                    UPDATE products 
                    SET stock = stock - %s 
                    WHERE id = %s AND stock >= %s AND active = TRUE
                    """,
                    (qty, pid, qty),
                )
                if cursor.rowcount == 0:
                    conn.rollback()
                    return jsonify({
                        "error": f"Yetersiz stok! '{prod['name']}' ürününden en fazla {prod['stock']} adet alınabilir."
                    }), 400

                order_details.append({
                    "product_id": pid,
                    "quantity": qty,
                    "price": item_price,
                })

            # 3. Ana siparişi kullanıcı kimliği ve adresle kaydet
            cursor.execute(
                """
                INSERT INTO orders (user_id, total_price, shipping_address, status) 
                VALUES (%s, %s, %s, 'Hazırlanıyor')
                """,
                (user_id, total_price, shipping_address),
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
            logger.info(f"Sipariş #{order_id} kullanıcı #{user_id} tarafından oluşturuldu. Tutar: {total_price} TL")
            return jsonify({
                "success": True,
                "order_id": order_id,
                "total_price": total_price,
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
    city: str = Field(..., min_length=2)
    district: str = Field(..., min_length=2)
    latitude: Optional[float] = None
    longitude: Optional[float] = None


@app.get("/api/addresses")
@token_required
def get_user_addresses(current_user):
    with get_db() as conn:
        cursor = conn.cursor(dictionary=True)
        cursor.execute(
            "SELECT id, title, full_address, city, district, latitude, longitude, is_default "
            "FROM user_addresses WHERE user_id = %s ORDER BY id DESC",
            (current_user["id"],)
        )
        addresses = cursor.fetchall()
        cursor.close()
    return jsonify({"success": True, "data": addresses}), 200


@app.post("/api/addresses")
@token_required
def add_user_address(current_user):
    try:
        data = AddressCreateSchema(**request.json)
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
                current_user["id"],
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
def delete_user_address(current_user, address_id: int):
    with get_db() as conn:
        cursor = conn.cursor()
        cursor.execute(
            "DELETE FROM user_addresses WHERE id = %s AND user_id = %s",
            (address_id, current_user["id"])
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
        if username == ADMIN_USERNAME and password == ADMIN_PASSWORD:
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

            extension = image.filename.rsplit(".", 1)[-1].lower() if "." in image.filename else ""
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
            cursor = conn.cursor()
            try:
                cursor.execute(
                    "UPDATE orders SET status = %s WHERE id = %s",
                    (new_status, order_id)
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

@app.route('/api/orders', methods=['POST'])
@jwt_required() # JWT token zorunluluğu
def create_order():
    current_user_id = get_jwt_identity()
    data = request.get_json()

    # Sipariş verilerini al
    address_id = data.get('address_id')
    items = data.get('items')
    total_price = data.get('total_price')
    payment_method = data.get('payment_method')

    if not items or not total_price:
        return jsonify({'error': 'Geçersiz sipariş verisi'}), 400

    # Veritabanı kayıt işlemi (Veritabanı modelinize göre uyarlayın)
    # new_order = Order(user_id=current_user_id, address_id=address_id, total_price=total_price, payment_method=payment_method)
    # db.session.add(new_order)
    # db.session.commit()

    return jsonify({'message': 'Sipariş başarıyla oluşturuldu'}), 201

if __name__ == "__main__":
    app.run(debug=True, host="0.0.0.0", port=5000)