#!/bin/bash
# =============================================================================
# argo-install.sh — Clean install script for ARGO stack
#
# Usage:
#   chmod +x argo-install.sh
#   ./argo-install.sh
#
# What it does:
#   1. Removes existing ARGO and CNPG installations
#   2. Installs CNPG Operator
#   3. Installs ARGO stack (PG + Ollama + Langflow)
#   4. Waits for all pods to be ready
#   5. Prints access instructions
# =============================================================================

set -euo pipefail

ARGO_NAMESPACE="argo"
CNPG_NAMESPACE="cnpg-system"
ARGO_RELEASE="argo"
CNPG_RELEASE="cnpg"
ARGO_REPO="https://rayjun-kim.github.io/argo-pg"
CNPG_REPO="https://cloudnative-pg.github.io/charts"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# =============================================================================
# 1. Prerequisites check
# =============================================================================
info "Checking prerequisites..."
command -v helm   > /dev/null 2>&1 || error "helm not found. Please install helm first."
command -v kubectl > /dev/null 2>&1 || error "kubectl not found."
kubectl cluster-info > /dev/null 2>&1 || error "Cannot connect to Kubernetes cluster."
info "Prerequisites OK."

# =============================================================================
# 2. Cleanup existing installations
# =============================================================================
info "Cleaning up existing installations..."

helm uninstall "$ARGO_RELEASE" -n "$ARGO_NAMESPACE" --no-hooks 2>/dev/null && \
  info "Removed ARGO release." || true

helm uninstall "$CNPG_RELEASE" -n "$CNPG_NAMESPACE" --no-hooks 2>/dev/null && \
  info "Removed CNPG release." || true

kubectl delete namespace "$ARGO_NAMESPACE" --force --grace-period=0 2>/dev/null && \
  info "Deleted namespace: $ARGO_NAMESPACE" || true

kubectl delete namespace "$CNPG_NAMESPACE" --force --grace-period=0 2>/dev/null && \
  info "Deleted namespace: $CNPG_NAMESPACE" || true

info "Removing CNPG CRDs..."
for crd in \
  clusters.postgresql.cnpg.io \
  backups.postgresql.cnpg.io \
  poolers.postgresql.cnpg.io \
  scheduledbackups.postgresql.cnpg.io \
  databases.postgresql.cnpg.io \
  imagecatalogs.postgresql.cnpg.io \
  clusterimagecatalogs.postgresql.cnpg.io \
  publications.postgresql.cnpg.io \
  subscriptions.postgresql.cnpg.io \
  failoverquorums.postgresql.cnpg.io; do
  kubectl delete crd "$crd" 2>/dev/null && info "  Deleted CRD: $crd" || true
done

# Wait for namespaces to be fully terminated
info "Waiting for namespaces to terminate..."
for ns in "$ARGO_NAMESPACE" "$CNPG_NAMESPACE"; do
  for i in $(seq 1 30); do
    if ! kubectl get namespace "$ns" > /dev/null 2>&1; then
      break
    fi
    echo -n "."
    sleep 2
  done
  echo ""
done

info "Cleanup complete."

# =============================================================================
# 3. Add / update Helm repos
# =============================================================================
info "Adding Helm repositories..."
helm repo add argo  "$ARGO_REPO"  2>/dev/null || helm repo add argo  "$ARGO_REPO"
helm repo add cnpg  "$CNPG_REPO" 2>/dev/null || helm repo add cnpg  "$CNPG_REPO"
helm repo update
info "Helm repos updated."

# =============================================================================
# 4. Install CNPG Operator
# =============================================================================
info "Installing CloudNativePG Operator..."
helm install "$CNPG_RELEASE" cnpg/cloudnative-pg \
  --namespace "$CNPG_NAMESPACE" \
  --create-namespace \
  --wait \
  --timeout 5m

info "Waiting for CNPG CRDs to be established..."
kubectl wait --for=condition=established \
  crd/clusters.postgresql.cnpg.io \
  --timeout=60s

info "CNPG Operator ready."

# =============================================================================
# 5. Install ARGO stack
# =============================================================================
info "Installing ARGO stack..."
helm install "$ARGO_RELEASE" argo/argo-stack \
  --namespace "$ARGO_NAMESPACE" \
  --create-namespace \
  --set cloudnative-pg.enabled=false

# =============================================================================
# 6. Wait for core components (excluding async model pull)
# =============================================================================
info "Waiting for PostgreSQL..."
kubectl wait pod \
  -l "cnpg.io/cluster=${ARGO_RELEASE}-argo-stack-argo-pg" \
  -n "$ARGO_NAMESPACE" \
  --for=condition=ready --timeout=5m

info "Waiting for Langflow..."
kubectl rollout status deployment/${ARGO_RELEASE}-argo-stack-langflow \
  -n "$ARGO_NAMESPACE" --timeout=5m

info "Waiting for Ollama..."
kubectl rollout status deployment/${ARGO_RELEASE}-argo-stack-ollama \
  -n "$ARGO_NAMESPACE" --timeout=5m

info "Core components ready. Triggering post-install hooks..."
# Run upgrade to trigger hooks (roles, seed, langflow-import)
helm upgrade "$ARGO_RELEASE" argo/argo-stack \
  --namespace "$ARGO_NAMESPACE" \
  --set cloudnative-pg.enabled=false \
  --reuse-values \
  --wait \
  --timeout 5m

# =============================================================================
# 7. Status check
# =============================================================================
echo ""
info "=== Pod Status ==="
kubectl get pods -n "$ARGO_NAMESPACE"

echo ""
info "=== Job Status ==="
kubectl get jobs -n "$ARGO_NAMESPACE" 2>/dev/null || true

# =============================================================================
# 8. Access instructions
# =============================================================================
echo ""
echo -e "${GREEN}=========================================="
echo "ARGO Stack installed successfully!"
echo -e "==========================================${NC}"
echo ""
echo "Access Langflow:"
echo "  kubectl -n $ARGO_NAMESPACE port-forward svc/${ARGO_RELEASE}-argo-stack-langflow 7860:7860"
echo "  open http://localhost:7860"
echo ""
echo "Check model download progress:"
echo "  kubectl logs -n $ARGO_NAMESPACE -l app.kubernetes.io/component=ollama-model-pull -f"
echo ""
echo "Check PostgreSQL:"
echo "  kubectl exec -n $ARGO_NAMESPACE ${ARGO_RELEASE}-argo-stack-argo-pg-1 -- \\"
echo "    psql -U postgres -d argo -c 'SELECT * FROM argo_public.v_session_progress;'"
echo ""
echo "Operator password:"
echo "  kubectl -n $ARGO_NAMESPACE get secret ${ARGO_RELEASE}-argo-stack-argo-passwords \\"
echo "    -o jsonpath='{.data.ARGO_OPERATOR_PASSWORD}' | base64 -d"
echo ""