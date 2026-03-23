"""Seed test users into the Hackonomics backend.

Reads loadtest/data/test_users.json and registers each user via
POST /api/auth/signup/.  Safe to run multiple times — existing users
(HTTP 400 with email-already-registered) are skipped gracefully.

Usage:
    python scripts/seed_users.py --host http://localhost:8000
    python scripts/seed_users.py --host http://localhost:8000 --workers 10
"""

import argparse
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import requests

DATA_FILE = Path(__file__).parent.parent / "data" / "test_users.json"
SIGNUP_PATH = "/api/auth/signup/"


def seed_user(host: str, user: dict, session: requests.Session) -> tuple[str, str]:
    """Returns (email, status) where status is 'created', 'skipped', or 'error'."""
    url = host.rstrip("/") + SIGNUP_PATH
    payload = {
        "email": user["email"],
        "password": user["password"],
        "confirm_password": user["password"],
        "device_id": user["device_id"],
    }
    try:
        resp = session.post(url, json=payload, timeout=10)
        if resp.status_code in (200, 201):
            return user["email"], "created"
        if resp.status_code == 400:
            body = resp.json() if resp.headers.get("content-type", "").startswith("application/json") else {}
            # Treat email-already-registered as a skip, not a failure
            if "email" in str(body).lower() or "already" in str(body).lower():
                return user["email"], "skipped"
            return user["email"], f"error:{resp.status_code}:{resp.text[:100]}"
        return user["email"], f"error:{resp.status_code}"
    except requests.RequestException as exc:
        return user["email"], f"error:exception:{exc}"


def main() -> None:
    parser = argparse.ArgumentParser(description="Seed Hackonomics test users")
    parser.add_argument("--host", default="http://localhost:8000", help="Django base URL")
    parser.add_argument("--workers", type=int, default=5, help="Parallel HTTP workers")
    parser.add_argument("--delay", type=float, default=0.05, help="Delay between batches (seconds)")
    args = parser.parse_args()

    if not DATA_FILE.exists():
        print(f"ERROR: {DATA_FILE} not found. Generate it first.", file=sys.stderr)
        sys.exit(1)

    users = json.loads(DATA_FILE.read_text())
    print(f"Seeding {len(users)} users → {args.host} (workers={args.workers})")

    created = skipped = errors = 0
    start = time.monotonic()

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        session = requests.Session()
        futures = {pool.submit(seed_user, args.host, u, session): u for u in users}
        for i, future in enumerate(as_completed(futures), 1):
            email, status = future.result()
            if status == "created":
                created += 1
            elif status == "skipped":
                skipped += 1
            else:
                errors += 1
                print(f"  FAIL  {email}: {status}")
            if i % 50 == 0:
                elapsed = time.monotonic() - start
                print(f"  Progress: {i}/{len(users)} ({elapsed:.1f}s)")
            time.sleep(args.delay)

    elapsed = time.monotonic() - start
    print(
        f"\nDone in {elapsed:.1f}s — "
        f"created={created}, skipped={skipped}, errors={errors}"
    )
    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main()
