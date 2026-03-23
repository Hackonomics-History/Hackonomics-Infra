"""Simulation task — compute-heavy endpoint.

Hits both PostgreSQL (exchange history) and runs a DCA calculation.
Weight is intentionally low (1) to avoid overwhelming compute capacity.
"""

import random

from conftest import SIMULATION_COMPARE, SIMULATION_PERIODS


def run_dca_comparison(client) -> None:
    """POST /api/simulation/compare/dca-vs-deposit/."""
    payload = {
        "period": random.choice(SIMULATION_PERIODS),
        "deposit_rate": round(random.uniform(1.0, 8.0), 2),
    }
    with client.post(
        SIMULATION_COMPARE,
        json=payload,
        name="[simulation] dca vs deposit",
        catch_response=True,
    ) as resp:
        if resp.status_code == 200:
            return
        resp.failure(f"simulation failed: {resp.status_code} — {resp.text[:200]}")
