#!/bin/bash

# 1. Load Environment Variables
# Check if the .env file exists in the specified path
if [ -f "../env/.env" ]; then
    export $(grep -v '^#' ../env/.env | xargs)
else
    echo "Error: ../env/.env file not found."
    exit 1
fi

echo "Starting ARC Controller installation..."

# 2. Install ARC Controller (Control Plane)
# This component manages the lifecycle of the runners
helm install arc \
    --namespace "$ARC_NAMESPACE" \
    --create-namespace \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

echo "Waiting for Controller installation (10 seconds)..."
sleep 10

echo "Starting Runner Scale Set installation..."

# 3. Install Runner Scale Set (Execution Plane)
# This component creates the actual runner pods for your jobs
helm install "$INSTALLATION_NAME" \
    --namespace "$ARC_NAMESPACE" \
    --set githubConfigUrl="${GITHUB_CONFIG_URL}" \
    --set githubConfigSecret.github_token="${GITHUB_PAT}" \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

echo "All ARC components have been initiated."
echo "Check the status using: 'kubectl get pods -n $ARC_NAMESPACE'"