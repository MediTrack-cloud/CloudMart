"""
Unit tests for product-service using the in-memory store backend.
Run: pytest tests/ -v
"""
import pytest
import json
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

# Force in-memory backend for tests
os.environ["STORE_BACKEND"] = "memory"

from app import app as flask_app


@pytest.fixture
def client():
    flask_app.config["TESTING"] = True
    with flask_app.test_client() as c:
        yield c


# ---------------------------------------------------------------------------
# Health / readiness
# ---------------------------------------------------------------------------

def test_health_returns_200(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["status"] == "healthy"


def test_ready_returns_200(client):
    resp = client.get("/ready")
    assert resp.status_code == 200


# ---------------------------------------------------------------------------
# Product CRUD
# ---------------------------------------------------------------------------

def test_list_products_returns_all_seed_data(client):
    resp = client.get("/products")
    assert resp.status_code == 200
    data = resp.get_json()
    assert "products" in data
    assert data["count"] >= 6   # seed data has 6 products


def test_get_existing_product(client):
    resp = client.get("/products/prod-001")
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["id"] == "prod-001"
    assert "name" in data
    assert "price" in data


def test_get_nonexistent_product_returns_404(client):
    resp = client.get("/products/prod-999")
    assert resp.status_code == 404


def test_create_product_returns_201(client):
    payload = {"name": "Test Widget", "price": 9.99, "category": "electronics", "stock": 10}
    resp = client.post("/products", json=payload)
    assert resp.status_code == 201
    data = resp.get_json()
    assert data["name"] == "Test Widget"
    assert data["price"] == 9.99
    assert "id" in data


def test_create_product_missing_name_returns_400(client):
    resp = client.post("/products", json={"price": 5.00})
    assert resp.status_code == 400


def test_update_product(client):
    resp = client.put("/products/prod-002", json={"price": 14.99})
    assert resp.status_code == 200
    assert resp.get_json()["price"] == 14.99


def test_update_nonexistent_product_returns_404(client):
    resp = client.put("/products/prod-999", json={"price": 1.00})
    assert resp.status_code == 404


def test_delete_product(client):
    # Create one to delete
    created = client.post("/products", json={"name": "To Delete", "price": 1.00}).get_json()
    resp = client.delete(f"/products/{created['id']}")
    assert resp.status_code == 200
    # Verify it's gone
    assert client.get(f"/products/{created['id']}").status_code == 404


# ---------------------------------------------------------------------------
# Stock management
# ---------------------------------------------------------------------------

def test_check_stock(client):
    resp = client.get("/products/prod-001/stock")
    assert resp.status_code == 200
    data = resp.get_json()
    assert "stock" in data
    assert data["available"] is True


def test_decrement_stock(client):
    resp = client.post("/products/prod-001/stock/decrement", json={"quantity": 1})
    assert resp.status_code == 200


def test_decrement_insufficient_stock_returns_409(client):
    resp = client.post("/products/prod-001/stock/decrement", json={"quantity": 999999})
    assert resp.status_code == 409


# ---------------------------------------------------------------------------
# Filter / search
# ---------------------------------------------------------------------------

def test_filter_by_category(client):
    resp = client.get("/products?category=electronics")
    assert resp.status_code == 200
    data = resp.get_json()
    for p in data["products"]:
        assert p["category"] == "electronics"


def test_search_products(client):
    resp = client.get("/products?search=tea")
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["count"] > 0


def test_categories_endpoint(client):
    resp = client.get("/categories")
    assert resp.status_code == 200
    data = resp.get_json()
    assert "categories" in data
    assert len(data["categories"]) > 0
