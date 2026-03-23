"""Account profile task functions.

Update payloads use bounded values from conftest so they remain valid
regardless of DB state and do not create unique-constraint violations.
"""

import random

from conftest import (
    ACCOUNT_ME,
    ACCOUNT_EXCHANGE_RATE,
    COUNTRY_CODES,
    CURRENCIES,
)


def get_account(client) -> None:
    """GET /api/account/me/."""
    with client.get(
        ACCOUNT_ME,
        name="[account] get profile",
        catch_response=True,
    ) as resp:
        if resp.status_code == 200:
            return
        resp.failure(f"get account failed: {resp.status_code}")


def update_account(client) -> None:
    """PUT /api/account/me/ with randomized but valid profile data.

    Triggers outbox event → Kafka → consumer pipeline.
    Keep task weight low (1) to avoid overwhelming the event pipeline.
    """
    payload = {
        "country_code": random.choice(COUNTRY_CODES),
        "currency": random.choice(CURRENCIES),
        "annual_income": random.randint(30_000, 200_000),
        "monthly_investable_amount": random.randint(500, 5_000),
    }
    with client.put(
        ACCOUNT_ME,
        json=payload,
        name="[account] update profile",
        catch_response=True,
    ) as resp:
        if resp.status_code in (200, 204):
            return
        resp.failure(f"update account failed: {resp.status_code} — {resp.text[:200]}")


def get_my_exchange_rate(client) -> None:
    """GET /api/account/me/exchange-rate/."""
    with client.get(
        ACCOUNT_EXCHANGE_RATE,
        name="[account] my exchange rate",
        catch_response=True,
    ) as resp:
        if resp.status_code == 200:
            return
        resp.failure(f"exchange-rate failed: {resp.status_code}")
