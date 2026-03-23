"""Hackonomics load test entry point.

User classes:
  AuthenticatedUser  weight=9  — logged-in browsing + writes
  AnonymousUser      weight=1  — new signups

Quickstart:
  # UI mode (recommended for initial exploration)
  locust --host http://localhost:8000

  # Headless stress test
  locust --headless --users 1000 --spawn-rate 50 --run-time 10m

  # Distributed (4 workers)
  docker compose -f docker-compose.locust.yml up --scale locust-worker=4
"""

import logging

from locust import events

from users.authenticated_user import AuthenticatedUser  # noqa: F401
from users.anonymous_user import AnonymousUser          # noqa: F401
from helpers import user_pool

logger = logging.getLogger(__name__)


@events.init.add_listener
def on_locust_init(environment, **kwargs) -> None:
    pool_sz = user_pool.pool_size()
    logger.info("Locust initialised. Credential pool size: %d", pool_sz)
    if pool_sz < 10:
        logger.warning(
            "Credential pool has only %d entries. "
            "Run `python scripts/seed_users.py` before stress testing.",
            pool_sz,
        )


@events.test_start.add_listener
def on_test_start(environment, **kwargs) -> None:
    logger.info(
        "Load test started — target host: %s",
        environment.host,
    )


@events.test_stop.add_listener
def on_test_stop(environment, **kwargs) -> None:
    stats = environment.stats.total
    logger.info(
        "Load test complete — requests: %d, failures: %d (%.1f%%), "
        "median: %dms, p95: %dms, p99: %dms",
        stats.num_requests,
        stats.num_failures,
        stats.fail_ratio * 100,
        stats.median_response_time,
        stats.get_response_time_percentile(0.95),
        stats.get_response_time_percentile(0.99),
    )
