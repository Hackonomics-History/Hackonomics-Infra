"""TokenRefreshMixin — proactively refreshes the access_token cookie.

Django sets access_token max_age = 3600s (1 hour).  This mixin refreshes
at TOKEN_REFRESH_AFTER_SECONDS (50 min by default) so long-running test
sessions never see 401 errors from expired tokens.

Usage:
    class AuthenticatedUser(TokenRefreshMixin, HttpUser):
        ...
        def on_start(self):
            ...
            self.record_login()

        @task
        def some_task(self):
            self.maybe_refresh()
            self.client.get("/api/...")
"""

import threading
import time
import logging

from conftest import AUTH_REFRESH, AUTH_LOGIN, TOKEN_REFRESH_AFTER_SECONDS

logger = logging.getLogger(__name__)


class TokenRefreshMixin:
    """Mix into an HttpUser subclass.  Call record_login() after a successful
    login and maybe_refresh() at the start of each task."""

    _refresh_lock: threading.Lock

    def record_login(self) -> None:
        self._login_time = time.monotonic()
        self._refresh_lock = threading.Lock()

    def maybe_refresh(self) -> None:
        """Refresh token if it is close to expiry.  Re-login on failure."""
        if not hasattr(self, "_login_time"):
            return
        if time.monotonic() - self._login_time < TOKEN_REFRESH_AFTER_SECONDS:
            return
        # Only one greenlet should refresh at a time.
        if not self._refresh_lock.acquire(blocking=False):
            return
        try:
            self._do_refresh()
        finally:
            self._refresh_lock.release()

    def _do_refresh(self) -> None:
        with self.client.post(
            AUTH_REFRESH,
            name="[auth] refresh token",
            catch_response=True,
        ) as resp:
            if resp.status_code == 200:
                self.record_login()
                logger.debug("Token refreshed for %s", getattr(self, "email", "?"))
            else:
                resp.failure(f"Refresh failed: {resp.status_code}")
                logger.warning(
                    "Refresh failed (%s) — re-logging in", resp.status_code
                )
                self._re_login()

    def _re_login(self) -> None:
        """Called when refresh fails. Attempts full re-authentication."""
        credentials = getattr(self, "_credentials", None)
        if credentials is None:
            return
        with self.client.post(
            AUTH_LOGIN,
            json=credentials,
            name="[auth] re-login after refresh failure",
            catch_response=True,
        ) as resp:
            if resp.status_code == 200:
                self.record_login()
            else:
                resp.failure(f"Re-login failed: {resp.status_code}")
