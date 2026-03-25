"""Authentication task functions.

These are plain functions (not @task decorators) so they can be called
from on_start / on_stop without contributing to Locust's task stats,
or wrapped in @task inside a user class when needed.
"""

import logging

from conftest import AUTH_LOGIN, AUTH_LOGOUT, AUTH_REFRESH, AUTH_ME, AUTH_SIGNUP

logger = logging.getLogger(__name__)


def do_signup(client, email: str, password: str) -> bool:
    """POST /api/auth/signup/ — register a new identity in Kratos.

    Returns True on 200/201 (created) and 409 (already exists) so the seeder
    can be re-run without counting duplicates as failures.
    """
    payload = {"email": email, "password": password}
    with client.post(
        AUTH_SIGNUP,
        json=payload,
        name="[seeder] signup",
        catch_response=True,
    ) as resp:
        if resp.status_code in (200, 201):
            logger.debug("Signup OK: %s", email)
            return True
        if resp.status_code == 409:
            resp.success()  # idempotent re-run — not a failure
            return True
        resp.failure(f"Signup failed: {resp.status_code} — {resp.text[:200]}")
        logger.error("Signup failed for %s: %s", email, resp.status_code)
        return False


def do_login(client, credentials: dict) -> bool:
    """POST /api/auth/login/ and return True on success.

    Cookies are automatically persisted by requests.Session (HttpUser's client).
    credentials must have: email, password, device_id
    """
    payload = {
        "email": credentials["email"],
        "password": credentials["password"],
        "device_id": credentials["device_id"],
        "remember_me": False,
    }
    with client.post(
        AUTH_LOGIN,
        json=payload,
        name="[auth] login",
        catch_response=True,
    ) as resp:
        if resp.status_code == 200:
            return True
        resp.failure(f"Login failed: {resp.status_code} — {resp.text[:200]}")
        logger.error("Login failed for %s: %s", credentials["email"], resp.status_code)
        return False


def do_logout(client) -> None:
    """POST /api/auth/logout/."""
    with client.post(
        AUTH_LOGOUT,
        name="[auth] logout",
        catch_response=True,
    ) as resp:
        if resp.status_code in (200, 204):
            return
        resp.failure(f"Logout failed: {resp.status_code}")


def do_refresh(client) -> bool:
    """POST /api/auth/refresh/ using existing session cookies."""
    with client.post(
        AUTH_REFRESH,
        name="[auth] refresh token",
        catch_response=True,
    ) as resp:
        if resp.status_code == 200:
            return True
        resp.failure(f"Refresh failed: {resp.status_code}")
        return False


def do_me(client) -> None:
    """GET /api/auth/me/ — verify the current session is valid."""
    with client.get(
        AUTH_ME,
        name="[auth] me",
        catch_response=True,
    ) as resp:
        if resp.status_code == 200:
            return
        resp.failure(f"auth/me failed: {resp.status_code}")
