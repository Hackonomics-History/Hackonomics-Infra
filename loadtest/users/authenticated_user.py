"""AuthenticatedUser — primary load persona (91% of traffic).

Simulates a logged-in Hackonomics user browsing the finance dashboard.
Task weights mirror real usage: read-heavy with infrequent writes.

Weight distribution (total = 27):
  news           5  — business news feed (Qdrant vector search)
  exchange_usd   4  — exchange rate lookup (external Frankfurter API)
  countries      3  — country list (external REST Countries API)
  account_get    3  — view account profile
  calendar_me    2  — view calendar
  calendar_ev    2  — list calendar events
  exchange_hist  2  — exchange history
  my_rate        2  — personal exchange rate
  auth_me        1  — verify session
  update_account 1  — update profile (triggers Kafka event)
  simulation     1  — DCA comparison (compute-heavy)
  create_event   1  — create calendar event (DB write)
"""

from locust import HttpUser, between, task

from helpers import user_pool
from helpers.token_refresh import TokenRefreshMixin
from tasks.auth_tasks import do_login, do_logout
from tasks import (
    news_tasks,
    exchange_tasks,
    meta_tasks,
    account_tasks,
    simulation_tasks,
    calendar_tasks,
    auth_tasks,
)


class AuthenticatedUser(TokenRefreshMixin, HttpUser):
    weight = 9
    wait_time = between(3, 15)

    def on_start(self) -> None:
        self._credentials = user_pool.acquire()
        success = do_login(self.client, self._credentials)
        if not success:
            # If login fails, stop this simulated user immediately so the
            # error is visible in the stats without flooding the test.
            self.environment.runner.quit()
            return
        self.record_login()
        self.email = self._credentials["email"]

    def on_stop(self) -> None:
        do_logout(self.client)
        if self._credentials:
            user_pool.release(self._credentials)
            self._credentials = None

    # ── Read tasks (high weight) ──────────────────────────────────────────────

    @task(5)
    def browse_business_news(self) -> None:
        self.maybe_refresh()
        news_tasks.get_business_news(self.client)

    @task(4)
    def check_exchange_rate(self) -> None:
        self.maybe_refresh()
        exchange_tasks.get_usd_to_currency(self.client)

    @task(3)
    def browse_countries(self) -> None:
        self.maybe_refresh()
        meta_tasks.get_countries(self.client)

    @task(3)
    def view_account(self) -> None:
        self.maybe_refresh()
        account_tasks.get_account(self.client)

    @task(2)
    def view_calendar(self) -> None:
        self.maybe_refresh()
        calendar_tasks.get_my_calendar(self.client)

    @task(2)
    def list_calendar_events(self) -> None:
        self.maybe_refresh()
        calendar_tasks.list_events(self.client)

    @task(2)
    def view_exchange_history(self) -> None:
        self.maybe_refresh()
        exchange_tasks.get_exchange_history(self.client)

    @task(2)
    def view_my_exchange_rate(self) -> None:
        self.maybe_refresh()
        account_tasks.get_my_exchange_rate(self.client)

    @task(1)
    def verify_session(self) -> None:
        self.maybe_refresh()
        auth_tasks.do_me(self.client)

    # ── Write tasks (low weight) ──────────────────────────────────────────────

    @task(1)
    def update_profile(self) -> None:
        self.maybe_refresh()
        account_tasks.update_account(self.client)

    @task(1)
    def run_simulation(self) -> None:
        self.maybe_refresh()
        simulation_tasks.run_dca_comparison(self.client)

    @task(1)
    def add_calendar_event(self) -> None:
        self.maybe_refresh()
        calendar_tasks.create_event(self.client)
