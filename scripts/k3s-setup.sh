#!/usr/bin/env bash
# =============================================================================
# k3s-setup.sh — Bootstrap hackonomics-dev k3d cluster with real secrets
# =============================================================================
# Usage:
#   cd /path/to/hackerton2026
#   bash Hackonomics-Infra/scripts/k3s-setup.sh
#
# Requires: k3d, kubectl, helm, python3
#
# CI Strategy: The deploy.yml workflow uses dummy env values for testing.
# CD Strategy (this script): Real keys are sourced from:
#   - .env.shared              (cross-stack shared secrets)
#   - Central-auth/env/.env.prod
#   - Hackonomics-2026/env/.env.prod
#   - Hackonomics-Infra/env/.env.prod
#
# Secrets are created as K8s Secrets *before* Helm runs. Helm charts reference
# them via envFrom → secretRef. No sensitive data is ever in Helm values or
# committed manifests.
# =============================================================================
set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="hackonomics-dev"
NAMESPACE="hackonomics"
RELEASE_NAME="hackonomics"
CHART_PATH="${REPO_ROOT}/Hackonomics-Infra/helm/hackonomics-infra"
VALUES_FILE="${REPO_ROOT}/Hackonomics-Infra/helm/values-k3s-dev.yaml"

SHARED_ENV="${REPO_ROOT}/.env.shared"
CENTRAL_AUTH_ENV="${REPO_ROOT}/Central-auth/env/.env.prod"
DJANGO_ENV="${REPO_ROOT}/Hackonomics-2026/env/.env.prod"
INFRA_ENV="${REPO_ROOT}/Hackonomics-Infra/env/.env.prod"

# Stable dev-cluster state (Kratos DB password, generated once)
STATE_FILE="${REPO_ROOT}/Hackonomics-Infra/.k3s-dev-state"

# ── Prerequisite checks ──────────────────────────────────────────────────────
for cmd in k3d kubectl helm python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: required tool not found: $cmd"
    exit 1
  fi
done

for f in "$SHARED_ENV" "$CENTRAL_AUTH_ENV" "$DJANGO_ENV" "$INFRA_ENV"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: env file not found: $f"
    exit 1
  fi
done

# ── parse_env: strips comments, blank lines, and shell quotes from env file ──
# Prints clean KEY=VALUE pairs (one per line) to stdout.
parse_env() {
  python3 - "$1" <<'PYEOF'
import sys, re

result = {}
with open(sys.argv[1]) as f:
    for line in f:
        line = line.rstrip('\n')
        stripped = line.lstrip()
        if not stripped or stripped.startswith('#'):
            continue
        if '=' not in line:
            continue
        key, _, val = line.partition('=')
        key = key.strip()
        val = val.strip()
        # Strip surrounding single or double quotes (full wrapping only)
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
            val = val[1:-1]
        else:
            # Strip trailing inline comment
            val = re.sub(r'\s+#.*$', '', val).strip()
        if key:
            result[key] = val

for k, v in result.items():
    print(f'{k}={v}')
PYEOF
}

# ── get_val: extract a single key from an env file ──────────────────────────
get_val() {
  parse_env "$1" | grep "^${2}=" | head -1 | cut -d= -f2-
}

# ── dedup_env: merge lines from a file, last occurrence of each key wins ────
# Writes deduplicated KEY=VALUE lines to a second temp file.
dedup_env() {
  local src="$1"
  local dst="$2"
  python3 - "$src" "$dst" <<'PYEOF'
import sys

result = {}
with open(sys.argv[1]) as f:
    for line in f:
        line = line.rstrip('\n')
        if not line or '=' not in line:
            continue
        k, _, v = line.partition('=')
        k = k.strip()
        if k:
            result[k] = v

with open(sys.argv[2], 'w') as f:
    for k, v in result.items():
        f.write(f'{k}={v}\n')
PYEOF
}

# ── apply_secret: create-or-update a K8s Secret from a clean env file ───────
apply_secret() {
  local name="$1"
  local envfile="$2"
  echo "    secret/$name"
  kubectl create secret generic "$name" \
    --namespace="$NAMESPACE" \
    --from-env-file="$envfile" \
    --dry-run=client -o yaml \
  | kubectl apply -f -
}

# ── 1. Create k3d cluster ────────────────────────────────────────────────────
echo "==> Cluster: $CLUSTER_NAME"
if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME}[[:space:]]"; then
  echo "    Already exists — skipping creation"
else
  k3d cluster create "$CLUSTER_NAME" \
    --servers 1 \
    --agents 2 \
    --port "80:80@loadbalancer" \
    --port "443:443@loadbalancer" \
    --k3s-arg "--disable=traefik@server:0"
  echo "    Created"
fi

# ── 2. Namespace ─────────────────────────────────────────────────────────────
echo "==> Namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ── 3. Extract values needed to build K8s-specific vars ─────────────────────
echo "==> Parsing env files"

# .env.shared
SHARED_SERVICE_KEY="$(get_val "$SHARED_ENV" CENTRAL_AUTH_SERVICE_KEY)"
SHARED_JWT_ISSUER="$(get_val "$SHARED_ENV" EXPECTED_JWT_ISSUER)"
SHARED_JWT_AUDIENCE="$(get_val "$SHARED_ENV" EXPECTED_JWT_AUDIENCE)"
SHARED_URLS_SELF_ISSUER="$(get_val "$SHARED_ENV" URLS_SELF_ISSUER)"
SHARED_SENTRY_DSN="$(get_val "$SHARED_ENV" SENTRY_DSN)"
SHARED_GOOGLE_CLIENT_ID="$(get_val "$SHARED_ENV" GOOGLE_CLIENT_ID)"
SHARED_GOOGLE_CLIENT_SECRET="$(get_val "$SHARED_ENV" GOOGLE_CLIENT_SECRET)"
SHARED_METRICS_USER="$(get_val "$SHARED_ENV" METRICS_BASIC_AUTH_USER)"
SHARED_METRICS_PASS="$(get_val "$SHARED_ENV" METRICS_BASIC_AUTH_PASSWORD)"

# Central-auth/.env.prod
CA_POSTGRES_USER="$(get_val "$CENTRAL_AUTH_ENV" POSTGRES_USER)"
CA_POSTGRES_PASS="$(get_val "$CENTRAL_AUTH_ENV" POSTGRES_PASSWORD)"
CA_POSTGRES_DB="$(get_val "$CENTRAL_AUTH_ENV" POSTGRES_DB)"
CA_KRATOS_COOKIE_SECRET="$(get_val "$CENTRAL_AUTH_ENV" KRATOS_COOKIE_SECRET)"
CA_KRATOS_CIPHER_SECRET="$(get_val "$CENTRAL_AUTH_ENV" KRATOS_CIPHER_SECRET)"
CA_HYDRA_CLIENT_ID="$(get_val "$CENTRAL_AUTH_ENV" HYDRA_CLIENT_ID)"
CA_HYDRA_CLIENT_SECRET="$(get_val "$CENTRAL_AUTH_ENV" HYDRA_CLIENT_SECRET)"
CA_HYDRA_SYSTEM_SECRET="$(get_val "$CENTRAL_AUTH_ENV" HYDRA_SYSTEM_SECRET)"
CA_BFF_CSRF_SECRET="$(get_val "$CENTRAL_AUTH_ENV" BFF_CSRF_SECRET)"
CA_RATE_LIMIT="$(get_val "$CENTRAL_AUTH_ENV" RATE_LIMIT_REQUESTS_PER_MIN)"

# Hackonomics-2026/.env.prod
DJ_SECRET_KEY="$(get_val "$DJANGO_ENV" DJANGO_SECRETKEY)"
DJ_DB_USER="$(get_val "$DJANGO_ENV" DB_USER)"
DJ_DB_PASS="$(get_val "$DJANGO_ENV" DB_PASSWORD)"
DJ_DB_NAME="$(get_val "$DJANGO_ENV" DB_NAME)"

# ── 4. K8s service names (derived from Helm release name) ───────────────────
# With `helm install hackonomics ...`, sub-chart services are named:
#   hackonomics-<subchart-name>
K8S_PG_GO="hackonomics-postgres-go"
K8S_PG_DJANGO="hackonomics-postgres-django"
K8S_REDIS_GO="hackonomics-redis-go"
K8S_REDIS_DJANGO="hackonomics-redis-django"
K8S_KAFKA="hackonomics-kafka"
K8S_KRATOS="hackonomics-kratos"
K8S_CENTRAL_AUTH="hackonomics-central-auth"
K8S_APP="hackonomics-hackonomics-app"
PGBOUNCER_PORT="6432"

# ── 5. Kratos DB password — stable across re-runs ───────────────────────────
if [[ -f "$STATE_FILE" ]] && grep -q "^KRATOS_DB_PASS=" "$STATE_FILE"; then
  KRATOS_DB_PASS="$(grep "^KRATOS_DB_PASS=" "$STATE_FILE" | cut -d= -f2)"
  echo "==> Loaded Kratos DB password from $STATE_FILE"
else
  KRATOS_DB_PASS="$(openssl rand -hex 16)"
  echo "KRATOS_DB_PASS=${KRATOS_DB_PASS}" >> "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  echo "==> Generated Kratos DB password → $STATE_FILE"
fi

# ── 6. Build and apply K8s Secrets ──────────────────────────────────────────
echo "==> Creating K8s Secrets"

# ── 6a. central-auth-env ─────────────────────────────────────────────────────
TMP_RAW=$(mktemp)
TMP_CLEAN=$(mktemp)

{
  # Base: service .env.prod vars (docker-compose hostnames will be overridden below)
  parse_env "$CENTRAL_AUTH_ENV"
  # Shared cross-stack secrets
  parse_env "$SHARED_ENV"
  # K8s-specific: override hostnames + add derived vars
  echo "POSTGRES_DSN=postgres://${CA_POSTGRES_USER}:${CA_POSTGRES_PASS}@localhost:${PGBOUNCER_PORT}/${CA_POSTGRES_DB}?sslmode=disable"
  echo "REDIS_ADDR=${K8S_REDIS_GO}:6379"
  echo "KAFKA_BROKERS=${K8S_KAFKA}:9092"
  echo "HTTP_PORT=8081"
  echo "GRPC_PORT=50051"
  echo "METRICS_PORT=9091"
  echo "SERVICE_API_KEY=${SHARED_SERVICE_KEY}"
  echo "KRATOS_PUBLIC_URL=http://${K8S_KRATOS}:4433"
  echo "KRATOS_ADMIN_URL=http://${K8S_KRATOS}:4434"
  echo "HYDRA_PUBLIC_URL=http://hackonomics-hydra:4444"
  echo "HYDRA_ADMIN_URL=http://hackonomics-hydra:4445"
  echo "HYDRA_REDIRECT_URI=http://${K8S_CENTRAL_AUTH}:8081/internal/oauth/callback"
  echo "DJANGO_URL=http://${K8S_APP}:8000"
  echo "SENTRY_DSN=${SHARED_SENTRY_DSN}"
  echo "RATE_LIMIT_REQUESTS_PER_MIN=${CA_RATE_LIMIT}"
} > "$TMP_RAW"

dedup_env "$TMP_RAW" "$TMP_CLEAN"
apply_secret central-auth-env "$TMP_CLEAN"
rm -f "$TMP_RAW" "$TMP_CLEAN"

# ── 6b. hackonomics-app-env ───────────────────────────────────────────────────
TMP_RAW=$(mktemp)
TMP_CLEAN=$(mktemp)

{
  parse_env "$DJANGO_ENV"
  parse_env "$SHARED_ENV"
  # K8s-specific overrides
  echo "DATABASE_URL=postgresql://${DJ_DB_USER}:${DJ_DB_PASS}@localhost:${PGBOUNCER_PORT}/${DJ_DB_NAME}"
  echo "DATABASE_URL_DIRECT=postgresql://${DJ_DB_USER}:${DJ_DB_PASS}@${K8S_PG_DJANGO}:5432/${DJ_DB_NAME}"
  echo "DJANGO_SECRET_KEY=${DJ_SECRET_KEY}"
  echo "ALLOWED_HOSTS=hackonomics.dev.local"
  echo "DEBUG=false"
  echo "REDIS_URL=redis://${K8S_REDIS_DJANGO}:6379/0"
  echo "KAFKA_BOOTSTRAP_SERVERS=${K8S_KAFKA}:9092"
  echo "CENTRAL_AUTH_URL=http://${K8S_CENTRAL_AUTH}:8081"
  echo "SENTRY_DSN=${SHARED_SENTRY_DSN}"
} > "$TMP_RAW"

dedup_env "$TMP_RAW" "$TMP_CLEAN"
apply_secret hackonomics-app-env "$TMP_CLEAN"
rm -f "$TMP_RAW" "$TMP_CLEAN"

# ── 6c. hackonomics-kratos-env ────────────────────────────────────────────────
TMP_CLEAN=$(mktemp)
cat > "$TMP_CLEAN" <<EOF
KRATOS_COOKIE_SECRET=${CA_KRATOS_COOKIE_SECRET}
KRATOS_CIPHER_SECRET=${CA_KRATOS_CIPHER_SECRET}
SELFSERVICE_METHODS_OIDC_CONFIG_PROVIDERS_0_CLIENT_ID=${SHARED_GOOGLE_CLIENT_ID}
SELFSERVICE_METHODS_OIDC_CONFIG_PROVIDERS_0_CLIENT_SECRET=${SHARED_GOOGLE_CLIENT_SECRET}
EOF
apply_secret hackonomics-kratos-env "$TMP_CLEAN"
rm -f "$TMP_CLEAN"

# ── 6d. hackonomics-infra-env (Grafana, Prometheus, Locust) ───────────────────
TMP_CLEAN=$(mktemp)
parse_env "$INFRA_ENV" > "$TMP_CLEAN"
apply_secret hackonomics-infra-env "$TMP_CLEAN"
rm -f "$TMP_CLEAN"

# ── 7. Deploy Helm chart ─────────────────────────────────────────────────────
echo "==> Helm deploy: $RELEASE_NAME"
helm dependency update "$CHART_PATH"

helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_FILE" \
  \
  `# Postgres passwords — passed directly; no secrets in committed values` \
  --set "postgres-go.postgres.password=${CA_POSTGRES_PASS}" \
  --set "postgres-django.postgres.password=${DJ_DB_PASS}" \
  \
  `# Kratos DSN (postgres-go instance, separate kratos user/db)` \
  --set "kratos.dsn=postgres://kratos:${KRATOS_DB_PASS}@${K8S_PG_GO}:5432/kratos?sslmode=disable" \
  \
  `# Tell each chart to skip generating its own Secret — use pre-created ones` \
  --set "central-auth.app.existingSecret=central-auth-env" \
  --set "hackonomics-app.app.existingSecret=hackonomics-app-env" \
  --set "kratos.existingSecret=hackonomics-kratos-env" \
  \
  --wait \
  --timeout 10m

echo ""
echo "==> Done!"
echo "    Cluster:   $CLUSTER_NAME"
echo "    Namespace: $NAMESPACE"
echo "    Release:   $RELEASE_NAME"
echo ""
echo "    kubectl get pods -n $NAMESPACE"
echo "    helm status $RELEASE_NAME -n $NAMESPACE"
