#!/usr/bin/env bash
# ============================================================================
# generate-env.sh — envsubst-based secret injection for Hackonomics-Infra
# ============================================================================
# Generates env/.env.prod and monitoring/prometheus.yml from their templates.
#
# Usage:
#   1. Export all required variables (or source a .secrets file):
#        export METRICS_BASIC_AUTH_USER=admin
#        export METRICS_BASIC_AUTH_PASSWORD="$(openssl rand -base64 32)"
#        export GF_ADMIN_USER=admin
#        export GF_ADMIN_PASSWORD="$(openssl rand -base64 32)"
#
#   2. Run from any directory:
#        bash /path/to/scripts/generate-env.sh
#
# Output files (gitignored):
#   - env/.env.prod
#   - monitoring/prometheus.yml
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Required variables ───────────────────────────────────────────────────────
REQUIRED_VARS=(
  METRICS_BASIC_AUTH_USER
  METRICS_BASIC_AUTH_PASSWORD
  GF_ADMIN_USER
  GF_ADMIN_PASSWORD
)

for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: Required variable '$var' is not set or empty." >&2
    echo "       Export it or source a .secrets file before running this script." >&2
    exit 1
  fi
done

# ── Generate env/.env.prod ───────────────────────────────────────────────────
ENV_TEMPLATE="$PROJECT_ROOT/env/.env.prod.template"
ENV_OUTPUT="$PROJECT_ROOT/env/.env.prod"

if [[ ! -f "$ENV_TEMPLATE" ]]; then
  echo "ERROR: Template not found: $ENV_TEMPLATE" >&2
  exit 1
fi

envsubst < "$ENV_TEMPLATE" > "$ENV_OUTPUT"
chmod 600 "$ENV_OUTPUT"
echo "[OK] Generated: $ENV_OUTPUT"

# ── Generate monitoring/prometheus.yml ───────────────────────────────────────
PROM_TEMPLATE="$PROJECT_ROOT/monitoring/prometheus.yml.tmpl"
PROM_OUTPUT="$PROJECT_ROOT/monitoring/prometheus.yml"

if [[ ! -f "$PROM_TEMPLATE" ]]; then
  echo "ERROR: Template not found: $PROM_TEMPLATE" >&2
  exit 1
fi

envsubst < "$PROM_TEMPLATE" > "$PROM_OUTPUT"
chmod 600 "$PROM_OUTPUT"
echo "[OK] Generated: $PROM_OUTPUT"

echo ""
echo "Done. Run 'docker-compose up -d --force-recreate' to apply changes."
