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

## Existing protections observed

- Database queries generally use parameterized values.
- User passwords are hashed with Werkzeug.
- Admin form submissions include CSRF checks.
- Order-history queries are scoped to the authenticated user.
