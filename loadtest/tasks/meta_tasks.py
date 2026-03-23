"""Country/metadata task functions.

NOTE: These endpoints proxy the external REST Countries API.
Verify Redis caching (TTL ~86400s) is active before stress testing.
"""

import random

from conftest import META_COUNTRIES, META_COUNTRY_DETAIL, COUNTRY_CODES


def get_countries(client) -> None:
    """GET /api/meta/countries/ — full country list."""
    with client.get(
        META_COUNTRIES,
        name="[meta] countries list",
        catch_response=True,
    ) as resp:
        if resp.status_code == 200:
            return
        resp.failure(f"countries failed: {resp.status_code}")


def get_country_detail(client) -> None:
    """GET /api/meta/countries/{code}/ with a random country code."""
    code = random.choice(COUNTRY_CODES)
    url = META_COUNTRY_DETAIL.format(code=code)
    with client.get(
        url,
        name="[meta] country detail [code]",
        catch_response=True,
    ) as resp:
        if resp.status_code == 200:
            return
        resp.failure(f"country/{code} failed: {resp.status_code}")
