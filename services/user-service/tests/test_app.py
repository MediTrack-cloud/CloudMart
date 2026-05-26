"""
Unit tests for user-service using the in-memory backend.
Run: pytest tests/ -v
"""
import pytest
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
os.environ["DB_BACKEND"] = "memory"
os.environ["JWT_SECRET"] = "test-secret"

from app import app as flask_app


@pytest.fixture(autouse=True)
def reset_users():
    from app import users_db
    users_db.clear()
    yield
    users_db.clear()


@pytest.fixture
def client():
    flask_app.config["TESTING"] = True
    with flask_app.test_client() as c:
        yield c


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "healthy"


def test_ready(client):
    resp = client.get("/ready")
    assert resp.status_code == 200


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------

def test_register_user(client):
    resp = client.post("/auth/register", json={
        "email": "test@example.com",
        "password": "SecurePass1!",
        "name": "Test User",
    })
    assert resp.status_code == 201
    data = resp.get_json()
    assert data["email"] == "test@example.com"
    assert "token" in data
    assert "password" not in data


def test_register_duplicate_email_returns_409(client):
    payload = {"email": "dup@example.com", "password": "Pass1!", "name": "User"}
    client.post("/auth/register", json=payload)
    resp = client.post("/auth/register", json=payload)
    assert resp.status_code == 409


def test_register_missing_fields_returns_400(client):
    resp = client.post("/auth/register", json={"email": "x@y.com"})
    assert resp.status_code == 400


# ---------------------------------------------------------------------------
# Login
# ---------------------------------------------------------------------------

def test_login_valid_credentials(client):
    client.post("/auth/register", json={
        "email": "login@example.com",
        "password": "MyPassword1!",
        "name": "Login User",
    })
    resp = client.post("/auth/login", json={
        "email": "login@example.com",
        "password": "MyPassword1!",
    })
    assert resp.status_code == 200
    assert "token" in resp.get_json()


def test_login_wrong_password_returns_401(client):
    client.post("/auth/register", json={
        "email": "user@example.com",
        "password": "Correct1!",
        "name": "U",
    })
    resp = client.post("/auth/login", json={
        "email": "user@example.com",
        "password": "Wrong",
    })
    assert resp.status_code == 401


def test_login_nonexistent_user_returns_401(client):
    resp = client.post("/auth/login", json={
        "email": "nobody@example.com",
        "password": "anything",
    })
    assert resp.status_code == 401


# ---------------------------------------------------------------------------
# Profile (authenticated)
# ---------------------------------------------------------------------------

def _register_and_get_token(client, email="profile@example.com"):
    resp = client.post("/auth/register", json={
        "email": email,
        "password": "ProfilePass1!",
        "name": "Profile User",
    })
    return resp.get_json()["token"]


def test_get_profile_with_token(client):
    token = _register_and_get_token(client)
    resp = client.get("/users/me", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["email"] == "profile@example.com"
    assert "password" not in data


def test_get_profile_without_token_returns_401(client):
    resp = client.get("/users/me")
    assert resp.status_code == 401


def test_update_profile(client):
    token = _register_and_get_token(client)
    resp = client.put("/users/me",
                      json={"name": "Updated Name"},
                      headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200
    assert resp.get_json()["name"] == "Updated Name"
