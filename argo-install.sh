#!/bin/bash
# =============================================================================
# argo-install.sh — ARGO Stack installer / uninstaller
#
# Usage:
#   ./argo-install.sh [COMMAND] [OPTIONS]
#
# Commands:
#   install     Install ARGO stack (default)
#   uninstall   Remove ARGO stack and CNPG operator
#   status      Show current installation status
#   help        Show this help message
# =============================================================================

set -euo pipefail

ARGO_NAMESPACE="argo"
CNPG_NAMESPACE="cnpg-system"
ARGO_RELEASE="argo"
CNPG_RELEASE="cnpg"
ARGO_REPO_URL="https://rayjun-kim.github.io/argo-pg"
CNPG_REPO_URL="https://cloudnative-pg.github.io/charts"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BOLD}${BLUE}==> $*${NC}"; }

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat << EOF

${BOLD}ARGO Stack Installer${NC}
DBaaCP Agent Framework on Kubernetes

${BOLD}Usage:${NC}
  $(basename "$0") [COMMAND]

${BOLD}Commands:${NC}
  install     Install CNPG Operator + ARGO stack (default)
  uninstall   Remove ARGO stack, CNPG operator, and all related resources
  status      Show current installation status
  help        Show this help message

${BOLD}Examples:${NC}
  $(basename "$0")                  # Install (default)
  $(basename "$0") install          # Install
  $(basename "$0") uninstall        # Remove everything
  $(basename "$0") status           # Check current status

${BOLD}What gets installed:${NC}
  - CloudNativePG Operator      (cnpg-system namespace)
  - PostgreSQL + ARGO schema    (argo namespace)
  - Ollama (gemma4:e2b + nomic-embed-text)
  - Langflow with ARGO components and starter flows

${BOLD}Requirements:${NC}
  - Kubernetes cluster (kubectl configured)
  - Helm 3.x
  - Cluster-admin permissions

${BOLD}After install:${NC}
  kubectl -n argo port-forward svc/argo-argo-stack-langflow 7860:7860
  open http://localhost:7860

EOF
}

# =============================================================================
# Prerequisites check
# =============================================================================
check_prerequisites() {
    step "Checking prerequisites"

    # kubectl
    if ! command -v kubectl > /dev/null 2>&1; then
        error "kubectl not found. Install: https://kubernetes.io/docs/tasks/tools/"
    fi
    info "kubectl: $(kubectl version --client --short 2>/dev/null | head -1)"

    # helm
    if ! command -v helm > /dev/null 2>&1; then
        error "helm not found. Install: https://helm.sh/docs/intro/install/"
    fi
    info "helm: $(helm version --short 2>/dev/null)"

    # Kubernetes cluster connectivity
    if ! kubectl cluster-info > /dev/null 2>&1; then
        error "Cannot connect to Kubernetes cluster.
  Check: kubectl config current-context
  Is the cluster running and kubeconfig configured?"
    fi

    local context
    context=$(kubectl config current-context 2>/dev/null || echo "unknown")
    info "Cluster context: ${context}"

    # Node availability
    local node_count
    node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$node_count" -eq 0 ]; then
        error "No nodes found in the cluster. Is the cluster healthy?"
    fi
    info "Cluster nodes: ${node_count}"

    # Permissions (soft check)
    if ! kubectl auth can-i '*' '*' --all-namespaces > /dev/null 2>&1; then
        warn "Could not verify cluster-admin permissions. Install may fail if permissions are insufficient."
    else
        info "Cluster permissions: OK"
    fi

    info "Prerequisites OK."
}

# =============================================================================
# Shared cleanup logic
# =============================================================================
do_cleanup() {
    # Remove kept secret first
    kubectl delete secret ${ARGO_RELEASE}-argo-stack-argo-passwords \
        -n "$ARGO_NAMESPACE" 2>/dev/null && \
        info "Removed Secret: argo-passwords." || true

    helm uninstall "$ARGO_RELEASE" -n "$ARGO_NAMESPACE" --no-hooks 2>/dev/null && \
        info "Removed ARGO release." || true

    helm uninstall "$CNPG_RELEASE" -n "$CNPG_NAMESPACE" --no-hooks 2>/dev/null && \
        info "Removed CNPG release." || true

    kubectl delete namespace "$ARGO_NAMESPACE" --force --grace-period=0 2>/dev/null && \
        info "Deleted namespace: ${ARGO_NAMESPACE}" || true

    kubectl delete namespace "$CNPG_NAMESPACE" --force --grace-period=0 2>/dev/null && \
        info "Deleted namespace: ${CNPG_NAMESPACE}" || true

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
        kubectl delete crd "$crd" 2>/dev/null && \
            info "  Deleted CRD: ${crd}" || true
    done

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
}

# =============================================================================
# Uninstall
# =============================================================================
do_uninstall() {
    step "Uninstalling ARGO stack"

    echo ""
    warn "This will remove ALL ARGO resources including:"
    echo "  - Helm releases: ${ARGO_RELEASE} (${ARGO_NAMESPACE}), ${CNPG_RELEASE} (${CNPG_NAMESPACE})"
    echo "  - Namespaces and all resources within them"
    echo "  - All CNPG CRDs"
    echo "  - All PVCs (PostgreSQL data, Ollama models, Langflow data)"
    echo ""
    read -r -p "Are you sure? [y/N] " confirm
    case "$confirm" in
        [yY][eE][sS]|[yY]) ;;
        *) info "Aborted."; exit 0 ;;
    esac

    do_cleanup
    info "Uninstall complete."
}

# =============================================================================
# Status
# =============================================================================
do_status() {
    step "ARGO Stack Status"

    echo ""
    echo -e "${BOLD}Helm releases:${NC}"
    helm list -n "$ARGO_NAMESPACE" 2>/dev/null || echo "  (none in ${ARGO_NAMESPACE})"
    helm list -n "$CNPG_NAMESPACE" 2>/dev/null || echo "  (none in ${CNPG_NAMESPACE})"

    echo ""
    echo -e "${BOLD}Pods:${NC}"
    kubectl get pods -n "$ARGO_NAMESPACE" 2>/dev/null || echo "  (namespace not found)"

    echo ""
    echo -e "${BOLD}Jobs:${NC}"
    kubectl get jobs -n "$ARGO_NAMESPACE" 2>/dev/null || echo "  (none)"

    echo ""
    echo -e "${BOLD}CNPG Cluster:${NC}"
    kubectl get cluster -n "$ARGO_NAMESPACE" 2>/dev/null || echo "  (none)"

    echo ""
    echo -e "${BOLD}Model pull progress:${NC}"
    kubectl logs -n "$ARGO_NAMESPACE" \
        -l app.kubernetes.io/component=ollama-model-pull \
        --tail=5 2>/dev/null || echo "  (model pull job not running)"
}

# =============================================================================
# Install
# =============================================================================
do_install() {
    step "Starting ARGO stack installation"

    # Cleanup
    step "Cleaning up existing installations"
    do_cleanup
    info "Cleanup complete."

    # Helm repos
    step "Setting up Helm repositories"
    helm repo add argo  "$ARGO_REPO_URL"  2>/dev/null || true
    helm repo add cnpg  "$CNPG_REPO_URL" 2>/dev/null || true
    helm repo update
    info "Helm repos updated."

    # CNPG Operator
    step "Installing CloudNativePG Operator"
    helm install "$CNPG_RELEASE" cnpg/cloudnative-pg \
        --namespace "$CNPG_NAMESPACE" \
        --create-namespace \
        --wait \
        --timeout 5m

    info "Waiting for CNPG CRDs..."
    kubectl wait --for=condition=established \
        crd/clusters.postgresql.cnpg.io \
        --timeout=60s
    info "CNPG Operator ready."

    # ARGO stack
    step "Installing ARGO stack"
    helm install "$ARGO_RELEASE" argo/argo-stack \
        --namespace "$ARGO_NAMESPACE" \
        --create-namespace \
        --set cloudnative-pg.enabled=false

    # Wait for core components
    step "Waiting for core components"

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

    info "Core components ready."

    # Post-install hooks
    step "Running post-install setup (roles, seed data, flow import)"
    helm upgrade "$ARGO_RELEASE" argo/argo-stack \
        --namespace "$ARGO_NAMESPACE" \
        --set cloudnative-pg.enabled=false \
        --reuse-values \
        --wait \
        --timeout 5m
    info "Post-install setup complete."

    # Summary
    echo ""
    step "Pod Status"
    kubectl get pods -n "$ARGO_NAMESPACE"

    echo ""
    step "Job Status"
    kubectl get jobs -n "$ARGO_NAMESPACE" 2>/dev/null || true

    echo ""
    echo -e "${GREEN}${BOLD}=========================================="
    echo "ARGO Stack installed successfully!"
    echo -e "==========================================${NC}"
    echo ""
    echo "Access Langflow:"
    echo "  kubectl -n ${ARGO_NAMESPACE} port-forward svc/${ARGO_RELEASE}-argo-stack-langflow 7860:7860"
    echo "  open http://localhost:7860"
    echo ""
    echo "Check model download progress (runs in background):"
    echo "  kubectl logs -n ${ARGO_NAMESPACE} -l app.kubernetes.io/component=ollama-model-pull -f"
    echo ""
    echo "Check PostgreSQL:"
    echo "  kubectl exec -n ${ARGO_NAMESPACE} ${ARGO_RELEASE}-argo-stack-argo-pg-1 -- \\"
    echo "    psql -U postgres -d argo -c 'SELECT * FROM argo_public.v_session_progress;'"
    echo ""
}

# =============================================================================
# Main
# =============================================================================
COMMAND="${1:-install}"

case "$COMMAND" in
    install)
        check_prerequisites
        do_install
        ;;
    uninstall)
        check_prerequisites
        do_uninstall
        ;;
    status)
        check_prerequisites
        do_status
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        error "Unknown command: '${COMMAND}'\nRun '$(basename "$0") help' for usage."
        ;;
esac