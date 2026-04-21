#!/usr/bin/env bash
# =============================================================================
# vault-init.sh — Write hackonomics secrets into Vault KV
# =============================================================================
# Replaces setup-secrets.sh. Writes secrets to Vault KV v2 via kubectl exec
# (no local `vault` CLI required). ESO ExternalSecret CRDs then sync these
# into K8s Secrets automatically.
#
# KV paths written
# ─────────────────────────────────────────────────────────────────────────────
#   secret/hackonomics/auth         → hackonomics-auth-env K8s Secret
#   secret/hackonomics/django       → hackonomics-django-env K8s Secret
#   secret/hackonomics/infra        → hackonomics-infra-env K8s Secret
#   secret/hackonomics/central-auth → central-auth-env K8s Secret (K8s-aware)
#   secret/hackonomics/app          → hackonomics-app-env K8s Secret (K8s-aware)
#   secret/hackonomics/kratos       → hackonomics-kratos-env K8s Secret
#
# Usage
# ─────────────────────────────────────────────────────────────────────────────
#   Called by setup-infra.sh and k3s-setup.sh after Vault is Running.
#   VAULT_ROOT_TOKEN  NAMESPACE  RELEASE_NAME must be set in the environment.
#
# Security
# ─────────────────────────────────────────────────────────────────────────────
#   • Secret values are never written to stdout; only KV paths are logged.
#   • JSON tmpfiles holding secret content are registered with a trap and
#     deleted on EXIT (success, error, or signal).
#   • VAULT_ROOT_TOKEN is passed via env var into kubectl exec; it does not
#     appear on the remote process command line.
# =============================================================================
set -euo pipefail

# ── Tmpfile cleanup trap ──────────────────────────────────────────────────────
_VI_TMPFILES=()
_vi_cleanup() { rm -f "${_VI_TMPFILES[@]:-}" 2>/dev/null; }
trap _vi_cleanup EXIT

# ── Paths ────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAMESPACE="${NAMESPACE:-hackonomics}"
RELEASE_NAME="${RELEASE_NAME:-hackonomics}"

SHARED_ENV="${REPO_ROOT}/.env.shared"
CENTRAL_AUTH_ENV="${REPO_ROOT}/Central-auth/env/.env.prod"
DJANGO_ENV="${REPO_ROOT}/Hackonomics-2026/env/.env.prod"
INFRA_ENV="${REPO_ROOT}/Hackonomics-Infra/env/.env.prod"

# ── Validate prerequisites ────────────────────────────────────────────────────
if [[ -z "${VAULT_ROOT_TOKEN:-}" ]]; then
  echo "ERROR: VAULT_ROOT_TOKEN is not set." >&2
  echo "       Source it from Hackonomics-Infra/.k3s-dev-state before calling this script." >&2
  exit 1
fi

echo "==> [vault-init] Validating env sources"
_MISSING=0
for _f in "$SHARED_ENV" "$CENTRAL_AUTH_ENV" "$DJANGO_ENV" "$INFRA_ENV"; do
  if [[ ! -f "$_f" ]]; then
    echo "    ERROR: env file not found: ${_f}" >&2
    _MISSING=1
  fi
done
if [[ "$_MISSING" -ne 0 ]]; then
  echo "    Run Hackonomics-Infra/scripts/generate-env.sh to scaffold them." >&2
  exit 1
fi

# ── parse_env ─────────────────────────────────────────────────────────────────
# Strips comments, blank lines, and shell quotes; prints clean KEY=VALUE pairs.
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
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
            val = val[1:-1]
        else:
            val = re.sub(r'\s+#.*$', '', val).strip()
        if key:
            result[key] = val

for k, v in result.items():
    print(f'{k}={v}')
PYEOF
}

# ── get_val ───────────────────────────────────────────────────────────────────
get_val() {
  parse_env "$1" | grep "^${2}=" | head -1 | cut -d= -f2-
}

# ── require_secret ────────────────────────────────────────────────────────────
require_secret() {
  local name="$1" value="$2" min_len="${3:-1}"
  if [[ -z "$value" ]]; then
    echo "    ERROR: ${name} is empty or missing." >&2; exit 1
  fi
  if [[ "${#value}" -lt "$min_len" ]]; then
    echo "    ERROR: ${name} must be at least ${min_len} characters." >&2; exit 1
  fi
}

# ── merge_env_files ───────────────────────────────────────────────────────────
# Merges two parsed KEY=VALUE files; last key wins on conflict.
merge_env_files() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys

result = {}
for src in (sys.argv[1], sys.argv[2]):
    with open(src) as f:
        for line in f:
            line = line.rstrip('\n')
            if not line or '=' not in line:
                continue
            k, _, v = line.partition('=')
            k = k.strip()
            if k:
                result[k] = v

with open(sys.argv[3], 'w') as f:
    for k, v in result.items():
        f.write(f'{k}={v}\n')
PYEOF
}

# ── dedup_env ─────────────────────────────────────────────────────────────────
# Deduplicates KEY=VALUE lines; last occurrence wins.
dedup_env() {
  python3 - "$1" "$2" <<'PYEOF'
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

# ── env_to_json ───────────────────────────────────────────────────────────────
# Converts clean KEY=VALUE lines to JSON {"KEY": "VALUE", ...}
# Vault kv put accepts @filepath with this format.
env_to_json() {
  python3 - "$1" <<'PYEOF'
import sys, json

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

print(json.dumps(result))
PYEOF
}

# ── _vi_mktemp ────────────────────────────────────────────────────────────────
_vi_mktemp() { local t; t=$(mktemp); _VI_TMPFILES+=("$t"); echo "$t"; }

# ── _get_vault_pod ────────────────────────────────────────────────────────────
_get_vault_pod() {
  kubectl get pod -n "$NAMESPACE" -l app.kubernetes.io/name=vault \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# ── vault_put ─────────────────────────────────────────────────────────────────
# Writes a merged KEY=VALUE env file to a Vault KV path via kubectl exec.
# Args: kv_path env_file
vault_put() {
  local kv_path="$1"
  local envfile="$2"

  local json_tmp
  json_tmp="$(_vi_mktemp)"
  env_to_json "$envfile" > "$json_tmp"

  local pod_name
  pod_name="$(_get_vault_pod)"
  if [[ -z "$pod_name" ]]; then
    echo "    ERROR: No running Vault pod in namespace '${NAMESPACE}'" >&2
    exit 1
  fi

  local remote_tmp="/tmp/vi-$(basename "$json_tmp").json"
  kubectl cp "$json_tmp" "${NAMESPACE}/${pod_name}:${remote_tmp}" >/dev/null

  kubectl exec -n "$NAMESPACE" "$pod_name" -- \
    env VAULT_TOKEN="$VAULT_ROOT_TOKEN" VAULT_ADDR="http://127.0.0.1:8200" \
    vault kv put "secret/${kv_path}" "@${remote_tmp}" >/dev/null

  kubectl exec -n "$NAMESPACE" "$pod_name" -- \
    rm -f "$remote_tmp" >/dev/null 2>&1 || true

  echo "    secret/${kv_path}"
}

# ── Wait for Vault pod ────────────────────────────────────────────────────────
echo "==> [vault-init] Waiting for Vault pod to be Ready..."
kubectl wait pod -n "$NAMESPACE" -l app.kubernetes.io/name=vault \
  --for=condition=Ready --timeout=120s >/dev/null

# ── Parse and validate critical values ───────────────────────────────────────
echo "==> [vault-init] Parsing env files (values are not logged)"

CA_KRATOS_COOKIE_SECRET="$(get_val "$CENTRAL_AUTH_ENV" KRATOS_COOKIE_SECRET)"
CA_KRATOS_CIPHER_SECRET="$(get_val "$CENTRAL_AUTH_ENV" KRATOS_CIPHER_SECRET)"
DJ_SECRET_KEY="$(get_val "$DJANGO_ENV" DJANGO_SECRET_KEY)"
SHARED_GOOGLE_CLIENT_ID="$(get_val "$SHARED_ENV" GOOGLE_CLIENT_ID)"
SHARED_GOOGLE_CLIENT_SECRET="$(get_val "$SHARED_ENV" GOOGLE_CLIENT_SECRET)"
INFRA_GRAFANA_PASS="$(get_val "$INFRA_ENV" GRAFANA_ADMIN_PASSWORD)"

require_secret "KRATOS_COOKIE_SECRET"           "$CA_KRATOS_COOKIE_SECRET"   32
require_secret "KRATOS_CIPHER_SECRET"           "$CA_KRATOS_CIPHER_SECRET"   32
require_secret "DJANGO_SECRET_KEY"              "$DJ_SECRET_KEY"             32
require_secret "GOOGLE_CLIENT_ID"               "$SHARED_GOOGLE_CLIENT_ID"
require_secret "GOOGLE_CLIENT_SECRET"           "$SHARED_GOOGLE_CLIENT_SECRET"
require_secret "GRAFANA_ADMIN_PASSWORD"         "$INFRA_GRAFANA_PASS"

# ── K8s service names (derived from RELEASE_NAME) ─────────────────────────────
K8S_PG_GO="${RELEASE_NAME}-postgres-go"
K8S_PG_DJANGO="${RELEASE_NAME}-postgres-django"
K8S_REDIS_GO="${RELEASE_NAME}-redis-go"
K8S_REDIS_DJANGO="${RELEASE_NAME}-redis-django"
K8S_KAFKA="${RELEASE_NAME}-kafka"
K8S_KRATOS="${RELEASE_NAME}-kratos"
K8S_CENTRAL_AUTH="${RELEASE_NAME}-central-auth"
K8S_APP="${RELEASE_NAME}-hackonomics-app"
PGBOUNCER_PORT="6432"

CA_POSTGRES_USER="$(get_val "$CENTRAL_AUTH_ENV" POSTGRES_USER)"
CA_POSTGRES_PASS="$(get_val "$CENTRAL_AUTH_ENV" POSTGRES_PASSWORD)"
CA_POSTGRES_HOST="$(get_val "$CENTRAL_AUTH_ENV" POSTGRES_HOST)"
CA_POSTGRES_PORT="$(get_val "$CENTRAL_AUTH_ENV" POSTGRES_PORT)"
CA_POSTGRES_DB="$(get_val   "$CENTRAL_AUTH_ENV" POSTGRES_DB)"
DJ_DB_USER="$(get_val       "$DJANGO_ENV"       DB_USER)"
DJ_DB_PASS="$(get_val       "$DJANGO_ENV"       DB_PASSWORD)"
DJ_DB_NAME="$(get_val       "$DJANGO_ENV"       DB_NAME)"
SHARED_SENTRY_DSN="$(get_val "$SHARED_ENV"      SENTRY_DSN)"
SHARED_SERVICE_KEY="$(get_val "$SHARED_ENV"     CENTRAL_AUTH_SERVICE_KEY)"
CA_RATE_LIMIT="$(get_val    "$CENTRAL_AUTH_ENV" RATE_LIMIT_REQUESTS_PER_MIN)"
CA_HYDRA_CLIENT_ID="$(get_val     "$CENTRAL_AUTH_ENV" HYDRA_CLIENT_ID)"
CA_HYDRA_CLIENT_SECRET="$(get_val "$CENTRAL_AUTH_ENV" HYDRA_CLIENT_SECRET)"

# ── Write secrets to Vault ────────────────────────────────────────────────────
echo "==> [vault-init] Writing secrets to Vault"

# ── 1. hackonomics/auth — simple merge for setup-infra.sh (envFrom: secretRef) ─
TMP_SHARED="$(_vi_mktemp)"
TMP_CA="$(_vi_mktemp)"
TMP_AUTH="$(_vi_mktemp)"
parse_env "$SHARED_ENV"       > "$TMP_SHARED"
parse_env "$CENTRAL_AUTH_ENV" > "$TMP_CA"
merge_env_files "$TMP_SHARED" "$TMP_CA" "$TMP_AUTH"
printf 'POSTGRES_DSN=postgres://%s:%s@%s:%s/%s?sslmode=disable\n' \
  "$CA_POSTGRES_USER" "$CA_POSTGRES_PASS" \
  "$CA_POSTGRES_HOST" "$CA_POSTGRES_PORT" "$CA_POSTGRES_DB" \
  >> "$TMP_AUTH"
vault_put "hackonomics/auth" "$TMP_AUTH"

# ── 2. hackonomics/django — simple merge for setup-infra.sh ───────────────────
TMP_SHARED2="$(_vi_mktemp)"
TMP_DJ="$(_vi_mktemp)"
TMP_DJANGO="$(_vi_mktemp)"
parse_env "$SHARED_ENV"  > "$TMP_SHARED2"
parse_env "$DJANGO_ENV"  > "$TMP_DJ"
merge_env_files "$TMP_SHARED2" "$TMP_DJ" "$TMP_DJANGO"
vault_put "hackonomics/django" "$TMP_DJANGO"

# ── 3. hackonomics/infra — shared + infra env ─────────────────────────────────
TMP_SHARED3="$(_vi_mktemp)"
TMP_INFRA="$(_vi_mktemp)"
TMP_INFRA_MERGED="$(_vi_mktemp)"
parse_env "$SHARED_ENV" > "$TMP_SHARED3"
parse_env "$INFRA_ENV"  > "$TMP_INFRA"
merge_env_files "$TMP_SHARED3" "$TMP_INFRA" "$TMP_INFRA_MERGED"
vault_put "hackonomics/infra" "$TMP_INFRA_MERGED"

# ── 4. hackonomics/central-auth — K8s-aware content for central-auth-env ──────
TMP_CA_RAW="$(_vi_mktemp)"
TMP_CA_CLEAN="$(_vi_mktemp)"
{
  parse_env "$CENTRAL_AUTH_ENV"
  parse_env "$SHARED_ENV"
  echo "POSTGRES_DSN=postgres://${CA_POSTGRES_USER}:${CA_POSTGRES_PASS}@localhost:${PGBOUNCER_PORT}/${CA_POSTGRES_DB}?sslmode=disable"
  echo "REDIS_ADDR=${K8S_REDIS_GO}:6379"
  echo "KAFKA_BROKERS=${K8S_KAFKA}:9092"
  echo "HTTP_PORT=8081"
  echo "GRPC_PORT=50051"
  echo "METRICS_PORT=9091"
  echo "CENTRAL_AUTH_SERVICE_KEY=${SHARED_SERVICE_KEY}"
  echo "KRATOS_PUBLIC_URL=http://${K8S_KRATOS}:4433"
  echo "KRATOS_ADMIN_URL=http://${K8S_KRATOS}:4434"
  echo "HYDRA_PUBLIC_URL=http://${RELEASE_NAME}-hydra:4444"
  echo "HYDRA_ADMIN_URL=http://${RELEASE_NAME}-hydra:4445"
  echo "HYDRA_REDIRECT_URI=http://${K8S_CENTRAL_AUTH}:8081/internal/oauth/callback"
  echo "DJANGO_URL=http://${K8S_APP}:8000"
  echo "SENTRY_DSN=${SHARED_SENTRY_DSN}"
  echo "RATE_LIMIT_REQUESTS_PER_MIN=${CA_RATE_LIMIT}"
} > "$TMP_CA_RAW"
dedup_env "$TMP_CA_RAW" "$TMP_CA_CLEAN"
vault_put "hackonomics/central-auth" "$TMP_CA_CLEAN"

# ── 5. hackonomics/app — K8s-aware content for hackonomics-app-env ────────────
TMP_APP_RAW="$(_vi_mktemp)"
TMP_APP_CLEAN="$(_vi_mktemp)"
{
  parse_env "$DJANGO_ENV"
  parse_env "$SHARED_ENV"
  echo "DATABASE_URL=postgresql://${DJ_DB_USER}:${DJ_DB_PASS}@localhost:${PGBOUNCER_PORT}/${DJ_DB_NAME}"
  echo "DATABASE_URL_DIRECT=postgresql://${DJ_DB_USER}:${DJ_DB_PASS}@${K8S_PG_DJANGO}:5432/${DJ_DB_NAME}"
  echo "DJANGO_ALLOWED_HOSTS=hackonomics.dev.local"
  echo "DEBUG=false"
  echo "REDIS_URL=redis://${K8S_REDIS_DJANGO}:6379/0"
  echo "KAFKA_BOOTSTRAP_SERVERS=${K8S_KAFKA}:9092"
  echo "CENTRAL_AUTH_URL=http://${K8S_CENTRAL_AUTH}:8081"
  echo "SENTRY_DSN=${SHARED_SENTRY_DSN}"
} > "$TMP_APP_RAW"
dedup_env "$TMP_APP_RAW" "$TMP_APP_CLEAN"
vault_put "hackonomics/app" "$TMP_APP_CLEAN"

# ── 6. hackonomics/kratos — Kratos-specific secrets ───────────────────────────
TMP_KRATOS="$(_vi_mktemp)"
cat > "$TMP_KRATOS" <<EOF
KRATOS_COOKIE_SECRET=${CA_KRATOS_COOKIE_SECRET}
KRATOS_CIPHER_SECRET=${CA_KRATOS_CIPHER_SECRET}
SELFSERVICE_METHODS_OIDC_CONFIG_PROVIDERS_0_CLIENT_ID=${SHARED_GOOGLE_CLIENT_ID}
SELFSERVICE_METHODS_OIDC_CONFIG_PROVIDERS_0_CLIENT_SECRET=${SHARED_GOOGLE_CLIENT_SECRET}
EOF
vault_put "hackonomics/kratos" "$TMP_KRATOS"

echo "==> [vault-init] All secrets written to Vault successfully"
echo "    Paths in secret/hackonomics/:"
echo "      auth  django  infra  central-auth  app  kratos"
