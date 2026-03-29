"""AnonymousUser — new-user signup persona (9% of traffic).

Simulates fresh signups arriving at the platform.  Each instance signs up
once then stops, generating a DB write + Kafka outbox event per user.

A global cap prevents unbounded user table growth during long soak tests.
Set MAX_SIGNUPS=0 to disable the cap (useful for stress testing the signup path).
"""

import os
import threading
import logging
import time

from locust import HttpUser, between, task

from conftest import AUTH_SIGNUP

logger = logging.getLogger(__name__)

MAX_SIGNUPS = int(os.getenv("MAX_SIGNUPS", "500"))
_signup_count = 0
_signup_lock = threading.Lock()

# Per-run epoch prefix ensures emails are globally unique across test runs.
# Within a run, a zero-padded counter enables easy identity tracking in logs.
_RUN_ID = str(int(time.time()))
_anon_email_counter = 0
_anon_email_lock = threading.Lock()


def _next_anon_email() -> str:
    global _anon_email_counter
    with _anon_email_lock:
        _anon_email_counter += 1
        n = _anon_email_counter
    return f"loadtest+{_RUN_ID}_{n:03d}@hackonomics.test"


def _generate_credentials() -> dict:
    """Return a flat signup payload matching SignupRequestSerializer:
    { email, password, confirm_password }
    """
    return {
        "email": _next_anon_email(),
        "password": "LoadTest1234!@#",
        "confirm_password": "LoadTest1234!@#",
    }


class AnonymousUser(HttpUser):
    weight = 1
    wait_time = between(10, 30)

    @task
    def signup(self) -> None:
        global _signup_count

        if MAX_SIGNUPS > 0:
            with _signup_lock:
                if _signup_count >= MAX_SIGNUPS:
                    # Cap reached — behave as idle user instead.
                    return
                _signup_count += 1

        credentials = _generate_credentials()
        with self.client.post(
            AUTH_SIGNUP,
            json=credentials,
            name="[anon] signup",
            catch_response=True,
        ) as resp:
            if resp.status_code in (200, 201):
                logger.debug("Signup OK: %s", credentials["email"])
            elif resp.status_code == 409:
                # Duplicate email — expected under repeated runs; not a system error.
                logger.debug("Signup duplicate (409): %s", credentials["email"])
                resp.success()
            elif resp.status_code == 400:
                # Validation error — treat as test data issue, not system failure.
                resp.failure(f"Signup validation error: {resp.text[:200]}")
            else:
                resp.failure(f"Signup failed: {resp.status_code}")

        # Exit
        return
