# Hackonomics-Infra

Load test and infrastructure orchestration for the Hackonomics platform.

```
┌─────────────────────────────────────────────────────────────┐
│                    Hackonomics-Infra                         │
│                                                             │
│  docker-compose.locust.yml                                  │
│  ┌──────────────────┐   ┌──────────────────────────────┐   │
│  │  locust-master   │──▶│  locust-worker (×4)          │   │
│  │  :8089 (UI)      │   │  AuthenticatedUser weight=9  │   │
│  │  :9646 (metrics) │   │  AnonymousUser      weight=1 │   │
│  └──────────────────┘   └──────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
               │ HTTP traffic
               ▼
┌─────────────────────────────────────────────────────────────┐
│              Hackonomics-2026 stack (host network)          │
│                                                             │
│  Django :8000  ──► Go central-auth :8081                   │
│       │                    │                               │
│       ▼                    ▼                               │
│  PostgreSQL :5431    Redis :6380  Kafka :9092              │
│  Qdrant :6333        Prometheus :9090  Grafana :3000       │
└─────────────────────────────────────────────────────────────┘
```

## Monitoring Stack

Prometheus + Grafana run from this repo and connect to application services via the shared Docker network.

### One-time setup

```bash
# Create the external network (run once per Docker host)
docker network create shared-monitor-net
```

Application services (`auth-server`, `django-app`) must also join `shared-monitor-net` in their own compose files:

```yaml
# In your application docker-compose.yml
networks:
  shared-monitor-net:
    external: true

services:
  auth-server:
    networks: [shared-monitor-net]
  django-app:
    networks: [shared-monitor-net]
```

### Start the monitoring stack

```bash
docker compose up -d
```

| Service | URL | Credentials |
|---------|-----|-------------|
| Prometheus | http://localhost:9090 | — |
| Grafana | http://localhost:3000 | admin / admin |

Grafana auto-provisions the Prometheus datasource and loads the "Hackonomics Load Test Dashboard" on first boot — no manual UI steps required.

### Volume management

```bash
# Stop (data is preserved)
docker compose down

# Stop and destroy all data volumes (full reset)
docker compose down -v
```

---

## Prerequisites

- Docker + Docker Compose v2
- Python 3.12+ (for seeding only)
- Hackonomics-2026 stack running (`docker compose up -d`)
- Go central-auth service running on `:8081`

## Quick Start

```bash
# 1. Configure
cp .env.example .env
# Edit .env — set LOCUST_HOST if Django is not on localhost:8000

# 2. Seed 200 test users (run once)
pip install requests
python loadtest/scripts/seed_users.py --host http://localhost:8000

# 3. Start Locust (UI mode — recommended first run)
docker compose -f docker-compose.locust.yml up --scale locust-worker=4

# Open Locust UI → http://localhost:8089
# Open Grafana   → http://localhost:3000  (dashboard: "Hackonomics Load Test Dashboard")
```

## Test Profiles

| Profile | Users | Spawn Rate | Duration | Purpose |
|---------|-------|-----------|----------|---------|
| **Smoke** | 10 | 2/s | 2m | Validate all endpoints respond |
| **Load** | 200 | 10/s | 10m | P95/P99 under expected production load |
| **Stress** | 1,000 | 50/s | 15m | Find breaking points |
| **Soak** | 100 | 5/s | 60m | Detect goroutine/connection leaks |

```bash
# Headless smoke test
LOCUST_USERS=10 LOCUST_SPAWN_RATE=2 LOCUST_RUN_TIME=2m \
  docker compose -f docker-compose.locust.yml up --scale locust-worker=1

# Full stress test
LOCUST_USERS=1000 LOCUST_SPAWN_RATE=50 LOCUST_RUN_TIME=15m \
  docker compose -f docker-compose.locust.yml up --scale locust-worker=4
```

## User Behavior (task weights)

| Task | Weight | Notes |
|------|--------|-------|
| GET /news/business-news | 5 | Qdrant vector search |
| GET /exchange/usd-to/{currency} | 4 | External Frankfurter API |
| GET /meta/countries | 3 | External REST Countries API |
| GET /account/me | 3 | Profile read |
| GET /calendar/me | 2 | Calendar read |
| GET /calendar/events | 2 | Events list |
| GET /exchange/history | 2 | Exchange history |
| GET /account/me/exchange-rate | 2 | Personal rate |
| GET /auth/me | 1 | Session verify |
| PUT /account/me | 1 | Profile update (Kafka event) |
| POST /simulation/compare | 1 | DCA comparison (compute) |
| POST /calendar/events/create | 1 | Create event (DB write) |

## Monitoring Integration

### Add Locust scrape job to Prometheus

```bash
cat monitoring/prometheus-locust.yml >> ../Hackonomics-2026/monitoring/prometheus.yml
# Then restart the Prometheus container
docker compose -f ../Hackonomics-2026/docker-compose.yml restart prometheus
```

### Install Grafana dashboard

Copy `monitoring/grafana/dashboards/locust-load-test.json` into the
Hackonomics-2026 Grafana provisioning directory:

```bash
cp monitoring/grafana/dashboards/locust-load-test.json \
   ../Hackonomics-2026/monitoring/grafana/provisioning/dashboards/
docker compose -f ../Hackonomics-2026/docker-compose.yml restart grafana
```

### Key Prometheus Queries

```promql
# Django P95 latency by view
histogram_quantile(0.95,
  sum(rate(django_http_requests_latency_seconds_by_view_method_bucket[1m])) by (le, view)
)

# Go central-auth P99 handler latency
histogram_quantile(0.99,
  sum(rate(http_request_duration_seconds_bucket{job="central-auth"}[1m])) by (le, handler)
)

# Locust error rate
100 * rate(locust_requests_fail_total[1m]) / clamp_min(rate(locust_requests_total[1m]), 1)

# Go goroutine leak check (should return to baseline after ramp-down)
go_goroutines{job="central-auth"}
```

## Bottleneck Reference

| Bottleneck | Severity | Mitigation |
|-----------|----------|-----------|
| Sync JWT verify to central-auth on every request | **HIGH** | Move to local RS256 signature verify in Django |
| PostgreSQL: CONN_MAX_AGE=0 → new connection per request | **HIGH** | Deploy pgbouncer; set CONN_MAX_AGE=None |
| Gunicorn sync workers (1 req/worker at a time) | **HIGH** | Switch to `gevent` or `uvicorn` workers |
| Go DB pool: unlimited connections by default | MEDIUM | SetMaxOpenConns(25), SetMaxIdleConns(10) |
| Prometheus cardinality (URL path labels) | MEDIUM | Confirm django_prometheus uses view names |
| Frankfurter / REST Countries not cached | MEDIUM | Add Redis cache TTL=300s / 86400s |
| Redis dual-purpose (Celery + cache) | MEDIUM | Configure max_connections per client |

## Go Goroutine Evaluation Procedure

1. **Baseline** — record `go_goroutines{job="central-auth"}` at 0 load for 2 min
2. **Ramp** — increase to 100 → 500 → 1,000 users, hold each level for 5 min
3. **Record** at each level: goroutine count, P99 latency, GC pause P99, heap size
4. **Ramp-down** — reduce to 0 and verify goroutine count returns to baseline within 30s

**Alert thresholds:**
- `go_goroutines > 5,000` for 2 min → WARNING
- `go_goroutines > 10,000` for 1 min → CRITICAL
- `rate(go_gc_duration_seconds_sum[1m]) > 0.1` → GC spending >10% CPU

## Success Criteria

| Metric | Target |
|--------|--------|
| Smoke test error rate | 0% |
| Read endpoint P95 (news, exchange, countries) | < 1,000ms |
| Auth endpoint P95 (login, refresh) | < 500ms |
| Write endpoint P95 (account update, create event) | < 2,000ms |
| Stress test error rate (1,000 users) | < 5% |
| Go goroutines post ramp-down | ≤ baseline within 30s |
| Go GC pause P99 at 1,000 users | < 10ms |

## File Structure

```
Hackonomics-Infra/
├── README.md
├── .env.example
├── docker-compose.locust.yml
├── monitoring/
│   ├── prometheus-locust.yml
│   └── grafana/dashboards/locust-load-test.json
└── loadtest/
    ├── Dockerfile
    ├── requirements.txt
    ├── locustfile.py          ← entry point
    ├── conftest.py            ← shared constants
    ├── data/test_users.json   ← 200 pre-seeded credentials
    ├── scripts/seed_users.py  ← register users via API
    ├── helpers/
    │   ├── user_pool.py       ← thread-safe credential pool
    │   └── token_refresh.py   ← proactive JWT refresh mixin
    ├── users/
    │   ├── authenticated_user.py
    │   └── anonymous_user.py
    └── tasks/
        ├── auth_tasks.py
        ├── news_tasks.py
        ├── exchange_tasks.py
        ├── meta_tasks.py
        ├── account_tasks.py
        ├── simulation_tasks.py
        └── calendar_tasks.py
```
