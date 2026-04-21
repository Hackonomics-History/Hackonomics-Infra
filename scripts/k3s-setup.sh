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
# Secrets flow: vault-init.sh writes all secrets into Vault KV. ESO
# ExternalSecret CRDs sync them into K8s Secrets. Helm charts reference
# K8s Secrets via envFrom → secretRef. No sensitive data in committed files.
# =============================================================================
set -euo pipefail

# ── Tmpfile cleanup trap ──────────────────────────────────────────────────────
_TMPFILES=()
_cleanup_tmpfiles() { rm -f "${_TMPFILES[@]:-}" 2>/dev/null; }
trap _cleanup_tmpfiles EXIT

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

# Stable dev-cluster state (Kratos DB password + Vault root token, generated once)
STATE_FILE="${REPO_ROOT}/Hackonomics-Infra/.k3s-dev-state"

VAULT_VALUES="${REPO_ROOT}/Hackonomics-Infra/helm/vault/values-k3s-dev.yaml"
ESO_VALUES="${REPO_ROOT}/Hackonomics-Infra/helm/eso/values-k3s-dev.yaml"
VAULT_ESO_CONFIG_CHART="${REPO_ROOT}/Hackonomics-Infra/helm/vault-eso-config"

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

# ── require_secret: validate a secret value is non-empty and meets min length ─
require_secret() {
  local name="$1"
  local value="$2"
  local min_len="${3:-1}"
  if [[ -z "$value" ]]; then
    echo "ERROR: ${name} is empty or missing from the env file." >&2
    echo "       Add '${name}=<value>' to the relevant .env file." >&2
    exit 1
  fi
  if [[ "${#value}" -lt "$min_len" ]]; then
    echo "ERROR: ${name} must be at least ${min_len} characters (got ${#value})." >&2
    exit 1
  fi
}

# ── 1. Create k3d cluster ────────────────────────────────────────────────────
echo "==> [1] Cluster: $CLUSTER_NAME"
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
echo "==> [2] Namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ── 3. Helm repos ────────────────────────────────────────────────────────────
echo "==> [3] Helm repos"
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
helm repo update

echo "==> [3.5] Traefik"
helm upgrade --install traefik traefik/traefik \
  --namespace kube-system \
  --set "ports.web.port=80" \
  --set "ports.websecure.port=443" \
  --set "service.type=LoadBalancer" \
  --wait \
  --timeout 5m
kubectl wait --for=condition=established --timeout=60s crd/ingressroutes.traefik.io
kubectl wait --for=condition=established --timeout=60s crd/middlewares.traefik.io

# ── 4. Vault root token ───────────────────────────────────────────────────────
echo "==> [4] Vault: generating root token"
if [[ -f "$STATE_FILE" ]] && grep -q "^VAULT_ROOT_TOKEN=" "$STATE_FILE"; then
  VAULT_ROOT_TOKEN="$(grep "^VAULT_ROOT_TOKEN=" "$STATE_FILE" | cut -d= -f2)"
  echo "    Loaded Vault root token from ${STATE_FILE}"
else
  VAULT_ROOT_TOKEN="$(openssl rand -hex 16)"
  { grep -v "^VAULT_ROOT_TOKEN=" "$STATE_FILE" 2>/dev/null || true
    echo "VAULT_ROOT_TOKEN=${VAULT_ROOT_TOKEN}"; } > "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  echo "    Generated Vault root token → ${STATE_FILE}"
fi

echo "==> [4] Vault: installing (dev mode)"
helm upgrade --install vault hashicorp/vault \
  --namespace "$NAMESPACE" \
  -f "$VAULT_VALUES" \
  --set "server.dev.devRootToken=${VAULT_ROOT_TOKEN}" \
  --wait \
  --timeout 3m

# ── 4.5. External Secrets Operator ───────────────────────────────────────────
echo "==> [4.5] External Secrets Operator: installing"
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace "$NAMESPACE" \
  -f "$ESO_VALUES" \
  --wait \
  --timeout 3m

# ── 5. Kratos DB password + Postgres passwords for Helm flags ────────────────
CA_POSTGRES_PASS="$(get_val "$CENTRAL_AUTH_ENV" POSTGRES_PASSWORD)"
DJ_DB_PASS="$(get_val "$DJANGO_ENV" DB_PASSWORD)"
K8S_PG_GO="${RELEASE_NAME}-postgres-go"

echo "==> [5] Resolving Kratos DB password"
if [[ -f "$STATE_FILE" ]] && grep -q "^KRATOS_DB_PASS=" "$STATE_FILE"; then
  KRATOS_DB_PASS="$(grep "^KRATOS_DB_PASS=" "$STATE_FILE" | cut -d= -f2)"
  echo "    Loaded from ${STATE_FILE}"
else
  KRATOS_DB_PASS="$(openssl rand -hex 16)"
  { grep -v "^KRATOS_DB_PASS=" "$STATE_FILE" 2>/dev/null || true
    echo "KRATOS_DB_PASS=${KRATOS_DB_PASS}"; } > "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  echo "    Generated → ${STATE_FILE}"
fi

# ── 6. Write secrets to Vault ────────────────────────────────────────────────
echo "==> [6] Writing secrets to Vault"
NAMESPACE="$NAMESPACE" RELEASE_NAME="$RELEASE_NAME" VAULT_ROOT_TOKEN="$VAULT_ROOT_TOKEN" \
  bash "${REPO_ROOT}/Hackonomics-Infra/scripts/vault-init.sh"

# ── 6.5. ESO SecretStore + ExternalSecret resources ──────────────────────────
echo "==> [6.5] ESO: deploying SecretStore + ExternalSecrets"
helm upgrade --install vault-eso-config "$VAULT_ESO_CONFIG_CHART" \
  --namespace "$NAMESPACE" \
  --set "vaultToken=${VAULT_ROOT_TOKEN}" \
  --set "namespace=${NAMESPACE}" \
  --set "releaseName=${RELEASE_NAME}" \
  --wait \
  --timeout 2m

echo "    Waiting for ExternalSecrets to sync..."
for _es in central-auth-env hackonomics-app-env hackonomics-kratos-env hackonomics-infra-env; do
  kubectl wait externalsecret/"$_es" \
    --for=condition=Ready --timeout=90s -n "$NAMESPACE" 2>/dev/null || \
  echo "    WARNING: externalsecret/${_es} not Ready yet (may sync on next poll)"
done

# ── 7. Deploy Helm chart ─────────────────────────────────────────────────────
echo "==> [7] Helm deploy: $RELEASE_NAME"
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
