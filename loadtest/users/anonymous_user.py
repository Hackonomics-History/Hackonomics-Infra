"""AnonymousUser — new-user signup persona (9% of traffic).

Simulates fresh signups arriving at the platform.  Each instance signs up
once then stops, generating a DB write + Kafka outbox event per user.

A global cap prevents unbounded user table growth during long soak tests.
Set MAX_SIGNUPS=0 to disable the cap (useful for stress testing the signup path).
"""

import os
import threading
import uuid
import logging

from faker import Faker
from locust import HttpUser, between, task

from conftest import AUTH_SIGNUP

logger = logging.getLogger(__name__)

_fake = Faker()

MAX_SIGNUPS = int(os.getenv("MAX_SIGNUPS", "500"))
_signup_count = 0
_signup_lock = threading.Lock()


def _generate_credentials() -> dict:
    unique = uuid.uuid4().hex[:12]
    return {
        "email": f"loadtest+{unique}@hackonomics.test",
        "password": "LoadTest1!",
        "confirm_password": "LoadTest1!",
        "device_id": str(uuid.uuid4()),
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
            elif resp.status_code == 400:
                # Validation error — treat as test data issue, not system failure.
                resp.failure(f"Signup validation error: {resp.text[:200]}")
            else:
                resp.failure(f"Signup failed: {resp.status_code}")

        # Each AnonymousUser does exactly one signup then goes idle.
        self.wait_time = between(3600, 7200)  # type: ignore[assignment]
