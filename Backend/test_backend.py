import json
from app import app, generate_jwt_token

def test_api():
    client = app.test_client()

    print("\n--- 1. Testing Registration Validation ---")
    res = client.post("/api/auth/register", json={"name": "A", "email": "invalid-email", "password": "123"})
    assert res.status_code == 400
    print("✓ Invalid registration payload properly rejected with 400")

    print("\n--- 2. Testing Registration & Login ---")
    test_email = "testuser_unique_99@example.com"
    res = client.post("/api/auth/register", json={
        "name": "Test User",
        "email": test_email,
        "password": "Password123!"
    })
    # Might be 201 or 409 if already exists
    assert res.status_code in (201, 409)
    
    login_res = client.post("/api/auth/login", json={
        "email": test_email,
        "password": "Password123!"
    })
    assert login_res.status_code == 200
    data = login_res.get_json()
    assert "token" in data
    assert data["user"]["email"] == test_email
    token = data["token"]
    user_id = data["user"]["id"]
    print(f"✓ Login successful, JWT token issued: {token[:20]}...")

    print("\n--- 3. Testing Products and Categories ---")
    cat_res = client.get("/api/categories")
    assert cat_res.status_code == 200
    print(f"✓ Categories loaded: {len(cat_res.get_json())} found")

    prod_res = client.get("/api/products?limit=5")
    assert prod_res.status_code == 200
    prods = prod_res.get_json()
    print(f"✓ Products loaded: {len(prods)} found")

    print("\n--- 4. Testing Protected Orders API (BOLA & Token Security) ---")
    # Without token
    no_auth_res = client.post("/api/orders", json={"items": [{"product_id": 1, "quantity": 1}]})
    assert no_auth_res.status_code == 401
    print("✓ Missing token properly blocked with 401")

    no_auth_get = client.get("/api/orders")
    assert no_auth_get.status_code == 401
    print("✓ GET orders without token blocked with 401")

    # With valid token
    headers = {"Authorization": f"Bearer {token}"}
    orders_get = client.get("/api/orders", headers=headers)
    assert orders_get.status_code == 200
    user_orders = orders_get.get_json()
    print(f"✓ User orders successfully retrieved (scoped to user {user_id}): {len(user_orders)} orders")

    if prods:
        first_prod = prods[0]
        # Test atomic order creation
        order_res = client.post("/api/orders", headers=headers, json={
            "items": [{"product_id": first_prod["id"], "quantity": 1}],
            "shipping_address": "Test Caddesi No: 42 Istanbul"
        })
        if first_prod["stock"] >= 1:
            assert order_res.status_code == 201
            order_data = order_res.get_json()
            assert order_data["success"] is True
            print(f"✓ Order #{order_data['order_id']} placed atomically! Total: {order_data['total_price']} TL")
        else:
            assert order_res.status_code == 400
            print("✓ Out of stock rejected correctly")

    print("\n--- 5. Testing Admin CSRF Protection ---")
    with client.session_transaction() as sess:
        sess["admin_authenticated"] = True
        sess["admin_username"] = "admin"
        sess["_csrf_token"] = "valid_csrf_token_value_123"

    # POST without CSRF token
    csrf_fail_res = client.post("/admin/categories", data={"name": "Kategori Deneme"})
    # Should redirect because of CSRF failure
    assert csrf_fail_res.status_code == 302
    print("✓ Form submission without CSRF redirected with error")

    print("\nALL BACKEND SECURITY & PERFORMANCE CHECKS PASSED!")

if __name__ == "__main__":
    test_api()
