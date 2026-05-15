#!/usr/bin/env bash
# =============================================================================
# k3d-bootstrap.sh — 클러스터당 1회 실행
# k3d 클러스터 + HashiCorp Vault (dev mode) + ESO 설정 후
# Vault에 시크릿을 쓰고 ExternalSecrets를 통해 K8s Secret을 생성한다.
#
# 사전 조건:
#   - k3d registry k3d-hackonomics-registry 가 실행 중 (port 5000)
#     → k3d registry create hackonomics-registry --port 5000
#   - Central-auth/env/.env.local 존재
#   - Hackonomics-Infra/env/.env.local 존재
#   - .env.shared 존재 (루트)
#
# 실행:
#   cd /path/to/hackerton2026
#   chmod +x Hackonomics-Infra/k3d-bootstrap.sh
#   ./Hackonomics-Infra/k3d-bootstrap.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE=hackonomics
VAULT_DEV_TOKEN="hackonomics-dev-root-token"

# ── Prerequisite checks ───────────────────────────────────────────────────────
echo "==> [bootstrap] Checking prerequisites"
for cmd in k3d kubectl helm; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is not installed" >&2; exit 1
  fi
done

for f in \
  "$REPO_ROOT/.env.shared" \
  "$REPO_ROOT/Central-auth/env/.env.local" \
  "$REPO_ROOT/Hackonomics-Infra/env/.env.local"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: required env file not found: $f" >&2; exit 1
  fi
done

if ! k3d registry list 2>/dev/null | grep -q "hackonomics-registry"; then
  echo "ERROR: k3d registry 'hackonomics-registry' not found." >&2
  echo "       Run: k3d registry create hackonomics-registry --port 5000" >&2
  exit 1
fi

# ── Step 1: k3d cluster ───────────────────────────────────────────────────────
echo ""
echo "==> [Step 1] Create k3d cluster 'hackonomics'"
if k3d cluster list 2>/dev/null | grep -q "^hackonomics "; then
  echo "    Cluster already exists — skipping create"
else
  k3d cluster create hackonomics \
    --registry-use k3d-hackonomics-registry:5001 \
    --agents 2
fi
kubectl config use-context k3d-hackonomics

# ── Step 2: Helm repos ────────────────────────────────────────────────────────
echo ""
echo "==> [Step 2] Add/update Helm repos"
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm repo update

# ── Step 3: Namespace ─────────────────────────────────────────────────────────
echo ""
echo "==> [Step 3] Create namespace '$NAMESPACE'"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ── Step 4: ESO ───────────────────────────────────────────────────────────────
echo ""
echo "==> [Step 4] Deploy External Secrets Operator (Includes CRD)"
helm upgrade --install eso external-secrets/external-secrets \
  --namespace "$NAMESPACE" \
  --wait

# ── Step 5: Vault (dev mode) ──────────────────────────────────────────────────
echo ""
echo "==> [Step 5] Deploy HashiCorp Vault (dev mode, in-memory)"
helm upgrade --install vault hashicorp/vault \
  --namespace "$NAMESPACE" \
  --values "$REPO_ROOT/Hackonomics-Infra/helm/vault/values-k3s-dev.yaml" \
  --set "server.dev.devRootToken=${VAULT_DEV_TOKEN}" \
  --wait

# ── Step 6: Write secrets to Vault ───────────────────────────────────────────
echo ""
echo "==> [Step 6] Write secrets to Vault KV"
VAULT_ROOT_TOKEN="$VAULT_DEV_TOKEN" \
NAMESPACE="$NAMESPACE" \
  "$REPO_ROOT/Hackonomics-Infra/scripts/vault-init.sh"

# ── Step 7: vault-eso-config ──────────────────────────────────────────────────
echo ""
echo "==> [Step 7] Deploy vault-eso-config (SecretStore + ExternalSecrets)"

echo "    Waiting for ESO CRDs to be ready in API server..."
kubectl wait --for condition=established --timeout=60s crd/externalsecrets.external-secrets.io
kubectl wait --for condition=established --timeout=60s crd/secretstores.external-secrets.io
kubectl api-resources > /dev/null

helm upgrade --install vault-eso-config \
  "$REPO_ROOT/Hackonomics-Infra/helm/vault-eso-config" \
  --namespace "$NAMESPACE" \
  --values "$REPO_ROOT/Hackonomics-Infra/helm/vault-eso-config/values.yaml" \
  --set "vaultToken=${VAULT_DEV_TOKEN}" \
  --wait

# ── Step 8: Wait for ExternalSecrets sync ────────────────────────────────────
echo ""
echo "==> [Step 8] Waiting for ExternalSecrets to sync K8s Secrets (~30s)..."
sleep 10
kubectl wait externalsecret -n "$NAMESPACE" --all \
  --for=condition=Ready --timeout=120s

echo ""
echo "======================================================================"
echo "  Bootstrap 완료!"
echo ""
echo "  생성된 K8s Secrets:"
kubectl get secret -n "$NAMESPACE" -o name | grep "hackonomics-" | sed 's/^/    /'
echo ""
echo "  다음 명령으로 앱 스택 빌드 + 배포:"
echo "    cd $REPO_ROOT && skaffold dev --profile k3s-dev"
echo "======================================================================"
