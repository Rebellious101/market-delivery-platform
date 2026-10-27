# Backend Security Review

**Review date:** 2026-10-14  
**Scope:** `app.py` and backend configuration

## Findings

| # | Severity | File | Lines | Vulnerability | Confidence |
|---|----------|------|-------|---------------|------------|
| 1 | 🟠 HIGH | `app.py` | 49-50, 650 | The admin username and password default to the known values `admin` and `admin123`. If the corresponding environment variables are missing, a remote user who can reach `/admin/login` can authenticate and access admin functionality. | 9/10 |
| 2 | 🟠 HIGH | `app.py` | 41, 45, 199, 250 | Flask session and JWT signing keys have fixed fallback values. If a deployment omits either environment variable, an attacker who can reach the service may forge admin sessions or JWTs. The reviewed local configuration has both keys set; this risk applies when those settings are absent or changed. | 9/10 |

## Recommendations

1. Require explicit, strong admin credentials and independently generated Flask and JWT secrets at startup; fail closed if any are missing. Rotate credentials or keys that may have been exposed or used with defaults.
2. For deployment, do not run `app.py` directly: its development entry point enables debug mode and binds to all interfaces (`app.py:1133`). Use a production WSGI server, disable debug mode, serve over HTTPS, and enable secure session cookies.
3. Keep `.env` out of source control and deployment artifacts.

## Remediation status

`app.py` now requires `FLASK_SECRET_KEY` and `JWT_SECRET_KEY` to be set to values of at least 32 characters, and requires explicit admin credentials with an admin password of at least 12 characters. It no longer supplies fallback keys or default admin credentials, so startup fails when these requirements are not met.

Database connection settings (`DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, and `DB_NAME`) are also required explicitly; `DB_PORT` must be between 1 and 65535. The previous development defaults are no longer used.

The duplicate `POST /api/orders` handler was removed so only the transactional order-creation endpoint remains. It loads product prices from the database and calculates the total with `Decimal`; it does not trust a client-supplied total. Product IDs and quantities are strict positive integers, repeated product IDs are combined, and sorted `SELECT ... FOR UPDATE` plus conditional stock updates keep all stock/order changes within one transaction. The endpoint accepts both `shipping_address` and the Flutter checkout's `full_address` field. JWT creation and validation use PyJWT consistently, without registering Flask-JWT-Extended. The `user_addresses` table is now created by the normal schema initialization, and address handlers consistently read the authenticated user's `user_id` from the JWT request context.

Update the local `Backend/.env` and deployment secrets with independently generated signing keys and a new strong admin password before starting the application. Minimum length alone does not make a secret unpredictable; rotate any keys or passwords that may have been exposed.

## Existing protections observed

- Database queries generally use parameterized values.
- User passwords are hashed with Werkzeug.
- Admin form submissions include CSRF checks.
- Order-history queries are scoped to the authenticated user.
