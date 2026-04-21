#!/usr/bin/env bash
# =============================================================================
# setup-secrets.sh — Create / update all Kubernetes Secrets for hackonomics
# =============================================================================
# Called by setup-infra.sh (and test-app.sh) BEFORE any Helm commands.
#
# Secret mapping (3 secrets, each = .env.shared merged with a stack env)
# ─────────────────────────────────────────────────────────────────────────────
#   hackonomics-auth-env    ← .env.shared + Central-auth/env/.env.prod
#   hackonomics-django-env  ← .env.shared + Hackonomics-2026/env/.env.prod
#   hackonomics-infra-env   ← .env.shared + Hackonomics-Infra/env/.env.prod
#
# Merge strategy: shared keys form the base; stack-specific keys override
# (same precedence order as docker-compose env_file stacking).
#
# Upsert strategy: delete-then-create ensures removed keys are fully purged.
# The `--dry-run | apply` approach keeps stale keys; delete+create does not.
#
# Security
# ─────────────────────────────────────────────────────────────────────────────
#   • Only secret *names* are printed; values are NEVER written to stdout.
#   • Temp files holding parsed env content are registered with a trap and
#     deleted on EXIT (success, error, or signal).
#   • Script exits immediately if any required value is missing or too short.
#
# Usage
# ─────────────────────────────────────────────────────────────────────────────
#   Called automatically by setup-infra.sh, or manually:
#     bash Hackonomics-Infra/scripts/setup-secrets.sh
#
# Env overrides
# ─────────────────────────────────────────────────────────────────────────────
#   NAMESPACE      K8s namespace for secrets   (default: hackonomics)
#   RELEASE_NAME   Helm release name           (default: hackonomics)
# =============================================================================
set -euo pipefail

# ── Tmpfile cleanup trap ──────────────────────────────────────────────────────
_SS_TMPFILES=()
_ss_cleanup() { rm -f "${_SS_TMPFILES[@]:-}" 2>/dev/null; }
trap _ss_cleanup EXIT

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAMESPACE="${NAMESPACE:-hackonomics}"

SHARED_ENV="${REPO_ROOT}/.env.shared"
CENTRAL_AUTH_ENV="${REPO_ROOT}/Central-auth/env/.env.prod"
DJANGO_ENV="${REPO_ROOT}/Hackonomics-2026/env/.env.prod"
INFRA_ENV="${REPO_ROOT}/Hackonomics-Infra/env/.env.prod"

# ── Validate all source env files are present ─────────────────────────────────
echo "==> [secrets] Validating env sources"
_MISSING=0
for _f in "$SHARED_ENV" "$CENTRAL_AUTH_ENV" "$DJANGO_ENV" "$INFRA_ENV"; do
  if [[ ! -f "$_f" ]]; then
    echo "    ERROR: env file not found: ${_f}" >&2
    _MISSING=1
  fi
done
if [[ "$_MISSING" -ne 0 ]]; then
  echo "" >&2
  echo "    One or more required .env files are missing." >&2
  echo "    Run Hackonomics-Infra/scripts/generate-env.sh to scaffold them." >&2
  exit 1
fi

# ── parse_env ─────────────────────────────────────────────────────────────────
# Strips comments, blank lines, and shell quoting; prints clean KEY=VALUE pairs.
# Output is never shown to the user — it flows only into tmpfiles and kubectl.
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
# Extract a single key from a parsed env file. Returns empty string if absent.
get_val() {
  parse_env "$1" | grep "^${2}=" | head -1 | cut -d= -f2-
}

# ── require_secret ────────────────────────────────────────────────────────────
# Validate a secret value is non-empty and meets the minimum length.
# Exits immediately with a clear message on failure.
require_secret() {
  local name="$1"
  local value="$2"
  local min_len="${3:-1}"
  if [[ -z "$value" ]]; then
    echo "    ERROR: ${name} is empty or missing from the env file." >&2
    echo "           Add '${name}=<value>' to the relevant .env file." >&2
    exit 1
  fi
  if [[ "${#value}" -lt "$min_len" ]]; then
    echo "    ERROR: ${name} must be at least ${min_len} characters (got ${#value})." >&2
    exit 1
  fi
}

# ── merge_env_files ───────────────────────────────────────────────────────────
# Merges two parsed env streams into a destination file. Last key wins on
# conflict (source B overrides source A where keys collide).
# Args: file_a file_b dest_file
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

# ── apply_secret ──────────────────────────────────────────────────────────────
# Upsert a K8s Secret from a clean env file:
#   1. Delete the existing secret if present (silently).
#   2. Create from the env file.
#
# Delete-then-create (vs. dry-run|apply) ensures stale keys are fully removed
# when a key is removed from the source .env file.
#
# Security: only the secret name is echoed; the file content is never printed.
apply_secret() {
  local name="$1"
  local envfile="$2"
  local ns="${3:-$NAMESPACE}"

  echo "    secret/${name} (ns: ${ns})"

  # Silently remove the old secret so deleted keys don't linger.
  kubectl delete secret "$name" \
    --namespace="$ns" \
    --ignore-not-found=true \
    >/dev/null 2>&1

  kubectl create secret generic "$name" \
    --namespace="$ns" \
    --from-env-file="$envfile"
}

# ── mktemp helper — registers file for cleanup ────────────────────────────────
_ss_mktemp() {
  local tmp
  tmp=$(mktemp)
  _SS_TMPFILES+=("$tmp")
  echo "$tmp"
}

# ── Validate critical values before creating any secrets ──────────────────────
echo "==> [secrets] Parsing env files (values are not logged)"

SHARED_GOOGLE_CLIENT_ID="$(get_val    "$SHARED_ENV"       GOOGLE_CLIENT_ID)"
SHARED_GOOGLE_CLIENT_SECRET="$(get_val "$SHARED_ENV"      GOOGLE_CLIENT_SECRET)"
CA_KRATOS_COOKIE_SECRET="$(get_val    "$CENTRAL_AUTH_ENV" KRATOS_COOKIE_SECRET)"
CA_KRATOS_CIPHER_SECRET="$(get_val    "$CENTRAL_AUTH_ENV" KRATOS_CIPHER_SECRET)"
DJ_SECRET_KEY="$(get_val              "$DJANGO_ENV"        DJANGO_SECRET_KEY)"
INFRA_GRAFANA_PASS="$(get_val         "$INFRA_ENV"         GRAFANA_ADMIN_PASSWORD)"

require_secret "GOOGLE_CLIENT_ID"                "$SHARED_GOOGLE_CLIENT_ID"
require_secret "GOOGLE_CLIENT_SECRET"            "$SHARED_GOOGLE_CLIENT_SECRET"
require_secret "KRATOS_COOKIE_SECRET"            "$CA_KRATOS_COOKIE_SECRET"   32
require_secret "KRATOS_CIPHER_SECRET"            "$CA_KRATOS_CIPHER_SECRET"   32
require_secret "DJANGO_SECRET_KEY"               "$DJ_SECRET_KEY"             32
require_secret "GRAFANA_ADMIN_PASSWORD (infra)"  "$INFRA_GRAFANA_PASS"

# ── Ensure namespace exists before creating secrets ───────────────────────────
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ── Create secrets ────────────────────────────────────────────────────────────
echo "==> [secrets] Upserting K8s Secrets in namespace '${NAMESPACE}'"

# ── 1. hackonomics-auth-env (.env.shared + Central-auth/.env.prod) ────────────
# Stack-specific keys override shared keys on conflict (matches docker-compose
# env_file stacking order). The Go BFF consumes this via Pod envFrom.
TMP_SHARED="$(_ss_mktemp)"
TMP_CA="$(_ss_mktemp)"
TMP_AUTH="$(_ss_mktemp)"
parse_env "$SHARED_ENV"       > "$TMP_SHARED"
parse_env "$CENTRAL_AUTH_ENV" > "$TMP_CA"
merge_env_files "$TMP_SHARED" "$TMP_CA" "$TMP_AUTH"

# Construct and append POSTGRES_DSN from individual POSTGRES_* vars.
# Format: postgres://USER:PASSWORD@HOST:PORT/DB?sslmode=disable
_CA_PG_USER="$(get_val "$CENTRAL_AUTH_ENV" POSTGRES_USER)"
_CA_PG_PASS="$(get_val "$CENTRAL_AUTH_ENV" POSTGRES_PASSWORD)"
_CA_PG_HOST="$(get_val "$CENTRAL_AUTH_ENV" POSTGRES_HOST)"
_CA_PG_PORT="$(get_val "$CENTRAL_AUTH_ENV" POSTGRES_PORT)"
_CA_PG_DB="$(get_val   "$CENTRAL_AUTH_ENV" POSTGRES_DB)"
printf 'POSTGRES_DSN=postgres://%s:%s@%s:%s/%s?sslmode=disable\n' \
  "$_CA_PG_USER" "$_CA_PG_PASS" "$_CA_PG_HOST" "$_CA_PG_PORT" "$_CA_PG_DB" \
  >> "$TMP_AUTH"

apply_secret hackonomics-auth-env "$TMP_AUTH"

# ── 2. hackonomics-django-env (.env.shared + Hackonomics-2026/.env.prod) ──────
# Stack-specific keys override shared keys on conflict. The Django app
# (web, worker, beat) consumes this via Pod envFrom.
TMP_SHARED2="$(_ss_mktemp)"
TMP_DJ="$(_ss_mktemp)"
TMP_DJANGO="$(_ss_mktemp)"
parse_env "$SHARED_ENV"  > "$TMP_SHARED2"
parse_env "$DJANGO_ENV"  > "$TMP_DJ"
merge_env_files "$TMP_SHARED2" "$TMP_DJ" "$TMP_DJANGO"
apply_secret hackonomics-django-env "$TMP_DJANGO"

# ── 3. hackonomics-infra-env (.env.shared + Hackonomics-Infra/.env.prod) ──────
# Stack-specific keys override shared keys on conflict. Consumed by infra
# components (Postgres, Redis, Kratos, Grafana, Locust) via Pod envFrom.
TMP_SHARED3="$(_ss_mktemp)"
TMP_INFRA="$(_ss_mktemp)"
TMP_INFRA_MERGED="$(_ss_mktemp)"
parse_env "$SHARED_ENV" > "$TMP_SHARED3"
parse_env "$INFRA_ENV"  > "$TMP_INFRA"
merge_env_files "$TMP_SHARED3" "$TMP_INFRA" "$TMP_INFRA_MERGED"
apply_secret hackonomics-infra-env "$TMP_INFRA_MERGED"

echo "==> [secrets] All secrets created/updated successfully"
echo "    Secrets in namespace '${NAMESPACE}':"
echo "      hackonomics-auth-env"
echo "      hackonomics-django-env"
echo "      hackonomics-infra-env"
