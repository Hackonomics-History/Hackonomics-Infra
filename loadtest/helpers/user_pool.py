"""Thread-safe pool of pre-seeded test credentials.

Each Locust user acquires one credential set on on_start() and releases it
on on_stop(), preventing multiple simulated users from sharing a session.

In distributed mode, each worker process has its own pool backed by the same
test_users.json file.  Ensure total_locust_users <= len(test_users) * num_workers.
"""

import json
import queue
import threading
from pathlib import Path

_DATA_FILE = Path(__file__).parent.parent / "data" / "test_users.json"

_lock = threading.Lock()
_pool: queue.Queue | None = None


def _init_pool() -> queue.Queue:
    with _DATA_FILE.open() as f:
        users = json.load(f)
    q: queue.Queue = queue.Queue()
    for user in users:
        q.put(user)
    return q


def _get_pool() -> queue.Queue:
    global _pool
    if _pool is None:
        with _lock:
            if _pool is None:
                _pool = _init_pool()
    return _pool


def acquire() -> dict:
    """Block until a free credential set is available, then return it."""
    return _get_pool().get(block=True, timeout=30)


def release(user: dict) -> None:
    """Return credentials back to the pool after a session ends."""
    _get_pool().put(user)


def pool_size() -> int:
    return _get_pool().qsize()
