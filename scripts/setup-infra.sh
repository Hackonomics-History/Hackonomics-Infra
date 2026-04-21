#!/usr/bin/env bash
# =============================================================================
# setup-infra.sh — Bootstrap hackonomics-dev k3d cluster (shared infra only)
# =============================================================================
# Layer 1 scope — installs everything EXCEPT application workloads:
#   • Cluster:      k3d single-server, 2 agents, Traefik ingress on 80/443
#   • Shared data:  Postgres (go + django), Redis (go + django), Kafka (KRaft)
#   • Identity:     Kratos, Hydra (via Kratos sub-chart)
#   • Log shipping: Promtail (pushes to Loki in monitoring namespace)
#   • Monitoring:   kube-prometheus-stack (Prometheus + Grafana), Loki
#
# Application workloads (central-auth, hackonomics-app) remain disabled by
# the Chart.yaml `condition:` field — enabled per-run by test-app.sh.
#
# Usage:
#   cd /path/to/hackerton2026
#   bash Hackonomics-Infra/scripts/setup-infra.sh
#
# Requires: k3d, kubectl, helm (≥3.8), python3
#
# Env overrides:
#   CLUSTER_NAME          k3d cluster name      (default: hackonomics-dev)
#   NAMESPACE             app namespace          (default: hackonomics)
#   MONITORING_NAMESPACE  monitoring namespace   (default: monitoring)
#   RELEASE_NAME          Helm release name      (default: hackonomics)
#
# Secrets strategy:
#   Real credentials are sourced from (never committed):
#     .env.shared                      — cross-stack shared secrets
#     Central-auth/env/.env.prod       — Kratos/Hydra creds + PG password
#     Hackonomics-2026/env/.env.prod   — Django PG password
#     Hackonomics-Infra/env/.env.prod  — Grafana / Prometheus credentials
#
#   Secrets are written to Vault KV (installed in-cluster). ESO ExternalSecret
#   CRDs sync them into K8s Secrets consumed via envFrom → secretRef.
#   No sensitive data lives in committed values files.
# =============================================================================
set -euo pipefail

# ── Tmpfile cleanup trap ──────────────────────────────────────────────────────
# Registered once here so any tmpfile written to _TMPFILES is removed on exit,
# regardless of whether the script succeeds, errors out, or is interrupted.
_TMPFILES=()
_cleanup_tmpfiles() { rm -f "${_TMPFILES[@]:-}" 2>/dev/null; }
trap _cleanup_tmpfiles EXIT

# ── Paths ────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-hackonomics-dev}"
NAMESPACE="${NAMESPACE:-hackonomics}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
RELEASE_NAME="${RELEASE_NAME:-hackonomics}"
CHART_PATH="${REPO_ROOT}/Hackonomics-Infra/helm/hackonomics-infra"
VALUES_FILE="${REPO_ROOT}/Hackonomics-Infra/helm/hackonomics-infra/values-k3s-dev.yaml"

SHARED_ENV="${REPO_ROOT}/.env.shared"
CENTRAL_AUTH_ENV="${REPO_ROOT}/Central-auth/env/.env.prod"
DJANGO_ENV="${REPO_ROOT}/Hackonomics-2026/env/.env.prod"
INFRA_ENV="${REPO_ROOT}/Hackonomics-Infra/env/.env.prod"

# Stable dev-cluster state — Kratos DB password persisted across re-runs
STATE_FILE="${REPO_ROOT}/Hackonomics-Infra/.k3s-dev-state"
VAULT_VALUES="${REPO_ROOT}/Hackonomics-Infra/helm/vault/values-k3s-dev.yaml"
ESO_VALUES="${REPO_ROOT}/Hackonomics-Infra/helm/eso/values-k3s-dev.yaml"
VAULT_ESO_CONFIG_CHART="${REPO_ROOT}/Hackonomics-Infra/helm/vault-eso-config"

# ── Prerequisite checks ──────────────────────────────────────────────────────
for cmd in k3d kubectl helm python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: required tool not found: $cmd" >&2
    exit 1
  fi
done

# Helm ≥ 3.8 required for OCI and condition dependency support
HELM_MAJOR=$(helm version --short | grep -oE 'v[0-9]+' | head -1 | tr -d v)
HELM_MINOR=$(helm version --short | grep -oE 'v[0-9]+\.[0-9]+' | head -1 | cut -d. -f2)
if [[ "$HELM_MAJOR" -lt 3 ]] || { [[ "$HELM_MAJOR" -eq 3 ]] && [[ "$HELM_MINOR" -lt 8 ]]; }; then
  echo "ERROR: helm ≥ 3.8 required (found $(helm version --short))" >&2
  exit 1
fi

for f in "$SHARED_ENV" "$CENTRAL_AUTH_ENV" "$DJANGO_ENV" "$INFRA_ENV"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: env file not found: $f" >&2
    exit 1
  fi
done

# ── parse_env: strips comments/blanks/shell-quotes, prints KEY=VALUE pairs ──
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

# ── get_val: extract a single key from a parsed env file ────────────────────
get_val() {
  parse_env "$1" | grep "^${2}=" | head -1 | cut -d= -f2-
}

# ── require_secret: validate a secret value is non-empty and meets min length ─
# Usage: require_secret VAR_NAME VALUE [MIN_LEN]
# Exits non-zero with an actionable error message if the value is empty or short.
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
echo "==> [1/7] Cluster: ${CLUSTER_NAME}"
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

# ── 2. Namespaces ────────────────────────────────────────────────────────────
echo "==> [2/7] Namespaces: ${NAMESPACE}, ${MONITORING_NAMESPACE}"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$MONITORING_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ── 3. Helm repos ────────────────────────────────────────────────────────────
echo "==> [3/9] Helm repos"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
# Traefik Install
helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true
helm repo update

echo "==> [3.5/9] Installing Traefik"

helm upgrade --install traefik traefik/traefik \
  --namespace kube-system \
  --set "ports.web.port=80" \
  --set "ports.websecure.port=443" \
  --set "service.type=LoadBalancer" \
  --wait \
  --timeout 5m

# Wait (Race Condition)
echo "    Waiting for Traefik CRDs to be established..."
kubectl wait --for=condition=established --timeout=60s crd/ingressroutes.traefik.io
kubectl wait --for=condition=established --timeout=60s crd/middlewares.traefik.io

# ── 4. Vault — in-cluster secret store (dev mode) ────────────────────────────
echo "==> [4/9] Vault: generating root token"
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

echo "==> [4/9] Vault: installing (dev mode)"
helm upgrade --install vault hashicorp/vault \
  --namespace "$NAMESPACE" \
  -f "$VAULT_VALUES" \
  --set "server.dev.devRootToken=${VAULT_ROOT_TOKEN}" \
  --wait \
  --timeout 3m

# ── 4.5. External Secrets Operator ───────────────────────────────────────────
echo "==> [4.5/9] External Secrets Operator: installing"
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace "$NAMESPACE" \
  -f "$ESO_VALUES" \
  --wait \
  --timeout 3m

# ── 5. Monitoring stack: kube-prometheus-stack + Loki ───────────────────────
# Deployed into the monitoring namespace so app-namespace RBAC stays clean.
# ServiceMonitor selector matches `release: hackonomics` labels on all
# ServiceMonitor CRDs defined in the hackonomics-infra chart and app subcharts.
#
# Resource sizes are tuned for a 3-agent Mac k3d cluster (≈12 GiB RAM total).
# prometheus-community/kube-prometheus-stack  →  Prometheus + Grafana + Alertmanager
# grafana/loki                                →  Loki (single-binary, no S3)
# ─────────────────────────────────────────────────────────────────────────────
echo "==> [5/9] Monitoring: kube-prometheus-stack"

# Extract Grafana credentials from infra env file (never committed)
GRAFANA_ADMIN_USER="$(get_val "$INFRA_ENV" GRAFANA_ADMIN_USER)"
GRAFANA_ADMIN_PASS="$(get_val "$INFRA_ENV" GRAFANA_ADMIN_PASSWORD)"

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "$MONITORING_NAMESPACE" \
  --version ">=58.0.0" \
  --set "prometheus.prometheusSpec.scrapeInterval=15s" \
  --set "prometheus.prometheusSpec.evaluationInterval=15s" \
  \
  `# ServiceMonitor discovery: pick up any SM with release=hackonomics label` \
  --set "prometheus.prometheusSpec.serviceMonitorSelector.matchLabels.release=hackonomics" \
  --set "prometheus.prometheusSpec.podMonitorSelector.matchLabels.release=hackonomics" \
  \
  `# Local-path storage — single replica for dev` \
  --set "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=local-path" \
  --set "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi" \
  --set "prometheus.prometheusSpec.replicas=1" \
  --set "alertmanager.alertmanagerSpec.replicas=1" \
  \
  `# Grafana: inject credentials, expose on NodePort for local browser access` \
  --set "grafana.adminUser=${GRAFANA_ADMIN_USER}" \
  --set "grafana.adminPassword=${GRAFANA_ADMIN_PASS}" \
  --set "grafana.service.type=NodePort" \
  --set "grafana.service.nodePort=30300" \
  \
  `# Reduced resource limits for a Mac laptop k3d cluster` \
  --set "prometheus.prometheusSpec.resources.requests.cpu=100m" \
  --set "prometheus.prometheusSpec.resources.requests.memory=512Mi" \
  --set "prometheus.prometheusSpec.resources.limits.cpu=500m" \
  --set "prometheus.prometheusSpec.resources.limits.memory=1Gi" \
  --set "grafana.resources.requests.cpu=50m" \
  --set "grafana.resources.requests.memory=128Mi" \
  --set "grafana.resources.limits.cpu=200m" \
  --set "grafana.resources.limits.memory=256Mi" \
  --wait \
  --timeout 10m

echo "==> [5/9] Monitoring: Loki"

helm upgrade --install loki grafana/loki \
  --namespace "$MONITORING_NAMESPACE" \
  --version ">=6.0.0" \
  \
  `# Single-binary mode — no object storage required for dev` \
  --set "deploymentMode=SingleBinary" \
  --set "loki.auth_enabled=false" \
  \
  `# File Storage in Local` \
  --set "loki.commonConfig.replication_factor=1" \
  --set "loki.storage.type=filesystem" \
  \
  `# Schema` \
  --set "loki.schemaConfig.configs[0].from=2026-04-10" \
  --set "loki.schemaConfig.configs[0].store=tsdb" \
  --set "loki.schemaConfig.configs[0].object_store=filesystem" \
  --set "loki.schemaConfig.configs[0].schema=v13" \
  --set "loki.schemaConfig.configs[0].index.prefix=index_" \
  --set "loki.schemaConfig.configs[0].index.period=24h" \
  \
  `# Settings Bucket name` \
  --set "loki.storage.bucketNames.chunks=chunks" \
  --set "loki.storage.bucketNames.ruler=ruler" \
  --set "loki.storage.bucketNames.admin=admin" \
  \
  `# Use local-path PVC; 20 Gi is enough for a dev cluster` \
  --set "singleBinary.persistence.storageClass=local-path" \
  --set "singleBinary.persistence.size=20Gi" \
  --set "singleBinary.replicas=1" \
  \
  `# SimpleScalable (read / write separation)` \
  --set backend.replicas=0 \
  --set read.replicas=0 \
  --set write.replicas=0 \
  \
  `# Expose gateway for Promtail pushes from the hackonomics namespace` \
  --set "gateway.enabled=true" \
  --set "gateway.service.type=ClusterIP" \
  \
  `# Reduced resources for local dev` \
  --set "singleBinary.resources.requests.cpu=100m" \
  --set "singleBinary.resources.requests.memory=256Mi" \
  --set "singleBinary.resources.limits.cpu=500m" \
  --set "singleBinary.resources.limits.memory=512Mi" \
  --wait \
  --timeout 10m

# Wire Loki as a data source in the kube-prometheus-stack Grafana.
# We use a ConfigMap-based datasource provisioning so it survives pod restarts.
echo "    Provisioning Loki datasource in Grafana"
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-loki-datasource
  namespace: ${MONITORING_NAMESPACE}
  labels:
    grafana_datasource: "1"
data:
  loki.yaml: |
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        access: proxy
        url: http://loki-gateway.${MONITORING_NAMESPACE}.svc.cluster.local
        isDefault: false
        jsonData:
          httpHeaderName1: X-Scope-OrgID
        secureJsonData:
          httpHeaderValue1: hackonomics
EOF

# ── 6. Write secrets to Vault ────────────────────────────────────────────────
# vault-init.sh writes all KV paths to Vault via kubectl exec.
# Never prints secret values — only KV paths are logged.
echo "==> [6/9] Writing secrets to Vault"
NAMESPACE="$NAMESPACE" RELEASE_NAME="$RELEASE_NAME" VAULT_ROOT_TOKEN="$VAULT_ROOT_TOKEN" \
  bash "${REPO_ROOT}/Hackonomics-Infra/scripts/vault-init.sh"

# ── 7. ESO SecretStore + ExternalSecret resources ────────────────────────────
echo "==> [7/9] ESO: deploying SecretStore + ExternalSecrets"
helm upgrade --install vault-eso-config "$VAULT_ESO_CONFIG_CHART" \
  --namespace "$NAMESPACE" \
  --set "vaultToken=${VAULT_ROOT_TOKEN}" \
  --set "namespace=${NAMESPACE}" \
  --set "releaseName=${RELEASE_NAME}" \
  --wait \
  --timeout 2m

echo "    Waiting for ExternalSecrets to sync..."
for _es in hackonomics-auth-env hackonomics-django-env hackonomics-infra-env \
           central-auth-env hackonomics-app-env hackonomics-kratos-env; do
  kubectl wait externalsecret/"$_es" \
    --for=condition=Ready --timeout=90s -n "$NAMESPACE" 2>/dev/null || \
  echo "    WARNING: externalsecret/${_es} not Ready yet (may sync on next poll)"
done

# ── 8. Kratos DB password — stable across re-runs ───────────────────────────
# This password is generated here (not from an env file) because it belongs
# to a Kratos-internal Postgres user created at cluster init time. It is
# passed directly to the Helm chart as a --set flag for the kratos.dsn value.
# The state file keeps it stable across `helm upgrade` re-runs.
echo "==> [8/9] Resolving Kratos DB password"
if [[ -f "$STATE_FILE" ]] && grep -q "^KRATOS_DB_PASS=" "$STATE_FILE"; then
  KRATOS_DB_PASS="$(grep "^KRATOS_DB_PASS=" "$STATE_FILE" | cut -d= -f2)"
  echo "    Loaded Kratos DB password from ${STATE_FILE}"
else
  KRATOS_DB_PASS="$(openssl rand -hex 16)"
  # Overwrite (not append) to prevent duplicate keys on re-runs.
  { grep -v "^KRATOS_DB_PASS=" "$STATE_FILE" 2>/dev/null || true
    echo "KRATOS_DB_PASS=${KRATOS_DB_PASS}"; } > "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  echo "    Generated Kratos DB password → ${STATE_FILE}"
fi

CA_KRATOS_COOKIE_SECRET="$(get_val "$CENTRAL_AUTH_ENV" KRATOS_COOKIE_SECRET)"
CA_KRATOS_CIPHER_SECRET="$(get_val "$CENTRAL_AUTH_ENV" KRATOS_CIPHER_SECRET)"
# ── 7. Deploy shared infra via Helm ──────────────────────────────────────────
# central-auth and hackonomics-app are disabled by Chart.yaml `condition:` fields
# (defaults: central-auth.enabled=false, hackonomics-app.enabled=false in values.yaml).
# test-app.sh uses --reuse-values + --set "<app>.enabled=true" to overlay them.
echo "==> [9/9] Helm deploy: ${RELEASE_NAME} (shared infra only)"
helm dependency update "$CHART_PATH"

helm upgrade --install "$RELEASE_NAME" "$CHART_PATH" \
  --namespace "$NAMESPACE" \
  -f "$VALUES_FILE" \
  --timeout 15m \
  \
  `# Secrets follow the consolidated domain-scoped strategy` \
  --set "postgres-go.existingSecret=hackonomics-auth-env" \
  --set "postgres-django.existingSecret=hackonomics-django-env" \
  --set "kratos.existingSecret=hackonomics-auth-env" \
  --set "kratos.dbSecretName=hackonomics-auth-env" \
  \
  `# Kratos uses a separate DB on postgres-go with a generated password` \
  --set "kratos.dsn=postgres://kratos:${KRATOS_DB_PASS}@${RELEASE_NAME}-postgres-go:5432/kratos?sslmode=disable&max_conns=20&max_idle_conns=4" \
  \
  `# Kafka internal listener uses the K8s Service DNS name for in-cluster routing` \
  --set "kafka.advertisedHost=${RELEASE_NAME}-kafka" \
  --set "kafka.service.internalPort=9092" \
  \
  `# App workloads are gated by Chart.yaml condition; secrets pre-registered here` \
  `# so test-app.sh can enable them without a separate secret creation step.`  \
  --set "central-auth.app.existingSecret=hackonomics-auth-env" \
  --set "hackonomics-app.app.existingSecret=hackonomics-django-env" \

echo ""
echo "==> Done — Layer 1 (shared infra + monitoring + Vault + ESO) is up."
echo ""
echo "    Cluster:             ${CLUSTER_NAME}"
echo "    App namespace:       ${NAMESPACE}"
echo "    Monitoring namespace:${MONITORING_NAMESPACE}"
echo "    Helm release:        ${RELEASE_NAME}"
echo ""
echo "    Grafana (local):     http://localhost:30300  (NodePort)"
echo "    Prometheus:          kubectl port-forward -n ${MONITORING_NAMESPACE} svc/kube-prometheus-stack-prometheus 9090:9090"
echo "    Loki:                kubectl port-forward -n ${MONITORING_NAMESPACE} svc/loki-gateway 3100:80"
echo ""
echo "    Next: run test-app.sh <central-auth|hackonomics-app> to deploy Layer 2"

# ── Post-deploy health-check loop ────────────────────────────────────────────
# Monitors pods in the app namespace for 60 seconds post-Helm install.
# Any pod entering CrashLoopBackOff triggers an automatic log dump (last 5 lines)
# so the root cause is visible without a separate kubectl logs invocation.
# ─────────────────────────────────────────────────────────────────────────────
_monitor_pods() {
  local ns="$1"
  local duration=60
  local interval=5
  local elapsed=0
  local -A _seen_crash   # tracks pods we already dumped logs for

  echo ""
  echo "==> Health check: watching pods in '${ns}' for ${duration}s …"
  while [[ $elapsed -lt $duration ]]; do
    while IFS= read -r podline; do
      local pod_name pod_ready pod_status
      pod_name="$(awk '{print $1}' <<< "$podline")"
      pod_ready="$(awk '{print $2}' <<< "$podline")"
      pod_status="$(awk '{print $3}' <<< "$podline")"

      # Detect CrashLoopBackOff in either the STATUS column or READY column
      if [[ "$pod_status" == "CrashLoopBackOff" ]] || \
         [[ "$pod_ready"  == "CrashLoopBackOff" ]] || \
         grep -qE 'CrashLoopBackOff|Error|OOMKilled' <<< "$podline"; then
        if [[ -z "${_seen_crash[$pod_name]+_}" ]]; then
          _seen_crash[$pod_name]=1
          echo "    [!] ${pod_name} → ${pod_status} — last 5 log lines:"
          echo "    ┌──────────────────────────────────────────────────────"
          kubectl logs --namespace="$ns" "$pod_name" --tail=5 2>/dev/null \
            | sed 's/^/    │ /' || true
          echo "    └──────────────────────────────────────────────────────"
          echo "    Tip: kubectl describe pod ${pod_name} -n ${ns}"
        fi
      fi
    done < <(kubectl get pods --namespace="$ns" --no-headers 2>/dev/null)

    sleep "$interval"
    elapsed=$((elapsed + interval))
    printf "    [%2ds/%ds] " "$elapsed" "$duration"
    kubectl get pods --namespace="$ns" --no-headers 2>/dev/null \
      | awk '{printf "%s(%s) ", $1, $3}' || true
    printf "\n"
  done

  echo ""
  echo "==> Final pod status (${ns}):"
  kubectl get pods --namespace="$ns" 2>/dev/null || true
}

_monitor_pods "$NAMESPACE"
