"""Shared constants and configuration for the load test suite."""

import os

# ── Target ────────────────────────────────────────────────────────────────────
HOST = os.getenv("LOCUST_HOST", "http://localhost:8000")

# ── Timing ────────────────────────────────────────────────────────────────────
# Think-time range (seconds) — reflects realistic browsing pauses
THINK_TIME_MIN = 3
THINK_TIME_MAX = 15

# Proactively refresh the access token this many seconds before expiry.
# Django sets access_token cookie max_age = 3600s (1 hour).
TOKEN_REFRESH_AFTER_SECONDS = 50 * 60  # refresh at 50 min

# ── API paths ─────────────────────────────────────────────────────────────────
AUTH_SIGNUP    = "/api/auth/signup/"
AUTH_LOGIN     = "/api/auth/login/"
AUTH_REFRESH   = "/api/auth/refresh/"
AUTH_LOGOUT    = "/api/auth/logout/"
AUTH_ME        = "/api/auth/me/"

ACCOUNT_ME            = "/api/account/me/"
ACCOUNT_EXCHANGE_RATE = "/api/account/me/exchange-rate/"

META_COUNTRIES        = "/api/meta/countries/"
META_COUNTRY_DETAIL   = "/api/meta/countries/{code}/"

EXCHANGE_USD_TO       = "/api/exchange/usd-to/{currency}/"
EXCHANGE_HISTORY      = "/api/exchange/history/"

NEWS_BUSINESS         = "/api/news/business-news/"

SIMULATION_COMPARE    = "/api/simulation/compare/dca-vs-deposit/"

CALENDAR_ME           = "/api/calendar/me/"
CALENDAR_EVENTS       = "/api/calendar/events/"
CALENDAR_EVENTS_CREATE = "/api/calendar/events/create/"
CALENDAR_CATEGORIES   = "/api/calendar/categories/"

# ── Bounded label values (safe for Prometheus — never use user-supplied IDs) ──
CURRENCIES = [
    "EUR", "GBP", "JPY", "KRW", "AUD", "CAD", "CHF", "CNY",
    "HKD", "SGD", "INR", "BRL", "MXN", "SEK", "NOK",
]

COUNTRY_CODES = [
    "US", "KR", "JP", "GB", "DE", "FR", "AU", "CA",
    "SG", "IN", "BR", "MX", "SE", "NO", "CH",
]

# Pre-validated (country_code, currency) pairs for AccountUpdateSerializer.
# Each pair is guaranteed valid by the REST Countries data used in the meta app.
# US/USD is excluded because USD is absent from the CURRENCIES list above.
COUNTRY_CURRENCY_PAIRS = [
    ("KR", "KRW"),
    ("JP", "JPY"),
    ("GB", "GBP"),
    ("DE", "EUR"),
    ("FR", "EUR"),
    ("AU", "AUD"),
    ("CA", "CAD"),
    ("SG", "SGD"),
    ("IN", "INR"),
    ("BR", "BRL"),
    ("MX", "MXN"),
    ("SE", "SEK"),
    ("NO", "NOK"),
    ("CH", "CHF"),
]

SIMULATION_PERIODS = ["1y", "2y", "3y", "5y"]

# Calendar event categories (must match values seeded in the DB)
CALENDAR_CATEGORY_IDS = [1, 2, 3]
