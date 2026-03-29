"""KratosSeeder — one-shot seeder persona for populating Kratos identities.

Drains the credential pool from test_users.json and registers each user via
POST /api/auth/signup/.  Safe to re-run — 409 (email already exists) is
treated as success so the seeder can top-up without re-counting duplicates.

Usage (single worker, headless):
    docker-compose -p hackonomics-locust -f docker-compose.locust.yml \\
        run --rm locust-master \\
        locust --headless --class-picker --users 1000 --spawn-rate 50 \\
               --run-time 5m --only-summary

Or via the Locust web UI (port 8089): select KratosSeeder only, users=1000.
"""

import logging
import threading

from locust import HttpUser, constant, task

from helpers import user_pool
from tasks.auth_tasks import do_signup

logger = logging.getLogger(__name__)

_done_lock = threading.Lock()
_done_count = 0


class KratosSeeder(HttpUser):
    """Registers one credential from the pool per task invocation.

    Uses constant(0) wait time for maximum seeding throughput.
    Stops the runner once the credential pool is exhausted.
    """

    weight = 1  # excluded from normal load-test runs; selected explicitly
    wait_time = constant(0)

    def on_start(self) -> None:
        self._credentials: dict | None = None

    @task
    def seed_one_user(self) -> None:
        global _done_count

        try:
            creds = user_pool.acquire()
        except Exception:
            # Pool exhausted — nothing left to seed.
            self.environment.runner.quit()
            return

        success = do_signup(self.client, creds["email"], creds["password"])

        with _done_lock:
            _done_count += 1
            if _done_count % 100 == 0:
                logger.info("Seeded %d identities so far…", _done_count)

        if not success:
            # Return failed credential to pool so a retry is possible.
            user_pool.release(creds)
