"""Exchange rate task functions.

NOTE: These endpoints hit the external Frankfurter API.
If Django does not cache responses in Redis, these tasks will generate
real external HTTP traffic and may trigger rate limits.
Verify caching is active before running stress tests.
"""

import random

from conftest import EXCHANGE_USD_TO, EXCHANGE_HISTORY, CURRENCIES


def get_usd_to_currency(client) -> None:
    """GET /api/exchange/usd-to/{currency}/ with a random currency."""
    currency = random.choice(CURRENCIES)
    url = EXCHANGE_USD_TO.format(currency=currency)
    with client.get(
        url,
        # Group all currency variants under one Locust stat name to avoid
        # cardinality explosion in Prometheus labels.
        name="[exchange] usd-to-[currency]",
        catch_response=True,
    ) as resp:
        if resp.status_code == 200:
            return
        resp.failure(f"usd-to-{currency} failed: {resp.status_code}")


def get_exchange_history(client) -> None:
    """GET /api/exchange/history/."""
    with client.get(
        EXCHANGE_HISTORY,
        name="[exchange] history",
        catch_response=True,
    ) as resp:
        if resp.status_code == 200:
            return
        resp.failure(f"exchange history failed: {resp.status_code}")
