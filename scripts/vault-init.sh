#!/usr/bin/env bash
# =============================================================================
# vault-init.sh — Write hackonomics secrets into Vault KV
# =============================================================================
# KV paths written (one per env source, variable names match the source file)
# ─────────────────────────────────────────────────────────────────────────────
#   secret/hackonomics/auth    ← Central-auth/env/.env.prod  (+ POSTGRES_DSN)
#                              → hackonomics-auth-env  K8s Secret
#
#   secret/hackonomics/django  ← Hackonomics-2026/env/.env.prod
#                              → hackonomics-django-env K8s Secret
#
#   secret/hackonomics/infra   ← Hackonomics-Infra/env/.env.prod
#                              → hackonomics-infra-env  K8s Secret
#
#   secret/hackonomics/shared  ← .env.shared
#                              → hackonomics-shared-env K8s Secret
#
# Usage
# ─────────────────────────────────────────────────────────────────────────────
#   Called by setup-infra.sh and k3s-setup.sh after Vault is Running.
#   VAULT_ROOT_TOKEN and NAMESPACE must be set in the environment.
#
# Security
# ─────────────────────────────────────────────────────────────────────────────
#   • Secret values are never written to stdout; only KV paths are logged.
#   • JSON tmpfiles holding secret content are registered with a trap and
#     deleted on EXIT (success, error, or signal).
#   • VAULT_ROOT_TOKEN is passed via env var into kubectl exec; it never
#     appears on the remote process command line.
# =============================================================================
set -euo pipefail

# ── Tmpfile cleanup trap ──────────────────────────────────────────────────────
_VI_TMPFILES=()
_vi_cleanup() { rm -f "${_VI_TMPFILES[@]:-}" 2>/dev/null; }
trap _vi_cleanup EXIT

# ── Paths ────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NAMESPACE="${NAMESPACE:-hackonomics}"

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
[[ "$_MISSING" -ne 0 ]] && exit 1

# ── parse_env ─────────────────────────────────────────────────────────────────
# Strips comments, blank lines, and shell quotes. Prints clean KEY=VALUE pairs.
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
    echo "    ERROR: ${name} is empty or missing in the env file." >&2; exit 1
  fi
  if [[ "${#value}" -lt "$min_len" ]]; then
    echo "    ERROR: ${name} must be at least ${min_len} characters (got ${#value})." >&2; exit 1
  fi
}

# ── env_to_json ───────────────────────────────────────────────────────────────
# Converts KEY=VALUE lines to {"KEY": "VALUE", ...} JSON.
# Accepts a file of already-parsed (quote-stripped) KEY=VALUE pairs.
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
# Writes a KEY=VALUE env file to a Vault KV path via kubectl exec.
# Args: kv_path env_tmpfile
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

# ── Validate critical secrets (values never logged) ───────────────────────────
echo "==> [vault-init] Validating critical secrets"

_KRATOS_COOKIE_SECRET="$(get_val "$CENTRAL_AUTH_ENV" KRATOS_COOKIE_SECRET)"
_KRATOS_CIPHER_SECRET="$(get_val "$CENTRAL_AUTH_ENV" KRATOS_CIPHER_SECRET)"
_DJANGO_SECRET_KEY="$(get_val    "$DJANGO_ENV"        DJANGO_SECRET_KEY)"

require_secret "KRATOS_COOKIE_SECRET" "$_KRATOS_COOKIE_SECRET" 32
require_secret "KRATOS_CIPHER_SECRET" "$_KRATOS_CIPHER_SECRET" 32
require_secret "DJANGO_SECRET_KEY"    "$_DJANGO_SECRET_KEY"    32

# ── Read POSTGRES_* from Central-auth for DSN synthesis ───────────────────────
_PG_USER="$(get_val "$CENTRAL_AUTH_ENV" POSTGRES_USER)"
_PG_PASS="$(get_val "$CENTRAL_AUTH_ENV" POSTGRES_PASSWORD)"
_PG_HOST="$(get_val "$CENTRAL_AUTH_ENV" POSTGRES_HOST)"
_PG_PORT="$(get_val "$CENTRAL_AUTH_ENV" POSTGRES_PORT)"
_PG_DB="$(get_val   "$CENTRAL_AUTH_ENV" POSTGRES_DB)"

require_secret "POSTGRES_USER"     "$_PG_USER"
require_secret "POSTGRES_PASSWORD" "$_PG_PASS"
require_secret "POSTGRES_HOST"     "$_PG_HOST"
require_secret "POSTGRES_DB"       "$_PG_DB"

# ── Write secrets to Vault ────────────────────────────────────────────────────
echo "==> [vault-init] Writing secrets to Vault"

# ── 1. hackonomics/auth — Central-auth/.env.prod (+ synthesized POSTGRES_DSN) ─
TMP_AUTH="$(_vi_mktemp)"
parse_env "$CENTRAL_AUTH_ENV" > "$TMP_AUTH"
printf 'POSTGRES_DSN=postgres://%s:%s@%s:%s/%s?sslmode=disable\n' \
  "$_PG_USER" "$_PG_PASS" "$_PG_HOST" "${_PG_PORT:-5432}" "$_PG_DB" \
  >> "$TMP_AUTH"
vault_put "hackonomics/auth" "$TMP_AUTH"

# ── 2. hackonomics/django — Hackonomics-2026/.env.prod ───────────────────────
TMP_DJANGO="$(_vi_mktemp)"
parse_env "$DJANGO_ENV" > "$TMP_DJANGO"
vault_put "hackonomics/django" "$TMP_DJANGO"

# ── 3. hackonomics/infra — Hackonomics-Infra/.env.prod ───────────────────────
TMP_INFRA="$(_vi_mktemp)"
parse_env "$INFRA_ENV" > "$TMP_INFRA"
vault_put "hackonomics/infra" "$TMP_INFRA"

# ── 4. hackonomics/shared — .env.shared ───────────────────────────────────────
TMP_SHARED="$(_vi_mktemp)"
parse_env "$SHARED_ENV" > "$TMP_SHARED"
vault_put "hackonomics/shared" "$TMP_SHARED"

echo "==> [vault-init] All secrets written to Vault successfully"
echo "    Paths in secret/hackonomics/:"
echo "      auth  django  infra  shared"
